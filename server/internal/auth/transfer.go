package auth

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/sha256"
	"database/sql"
	"encoding/base32"
	"encoding/json"
	"errors"
	"io"
	"strings"
	"time"

	"me.zqydev/gamebox/server/internal/users"
)

var ErrSessionTransferred = errors.New("session_transferred")
var ErrTransferInvalid = errors.New("transfer_invalid")
var ErrTransferLimited = errors.New("transfer_limited")

// TransferCode is a short-lived bearer credential; never log its fields.
type TransferCode struct {
	Code      string `json:"code"`
	ExpiresAt int64  `json:"expiresAt"`
}

func (TransferCode) String() string     { return "TransferCode{<redacted>}" }
func (v TransferCode) GoString() string { return v.String() }

type TransferResult struct {
	Session  Session
	Snapshot string
}

func (TransferResult) String() string     { return "TransferResult{<redacted>}" }
func (v TransferResult) GoString() string { return v.String() }

// CreateTransfer snapshots local progress without changing the current login.
// The access credential is checked again inside the write transaction.
func (s *Service) CreateTransfer(ctx context.Context, access, snapshot string) (TransferCode, error) {
	identity, err := s.ParseAccess(access)
	if err != nil {
		return TransferCode{}, err
	}
	return s.createTransfer(ctx, identity.UserID, identity.Epoch, snapshot, false)
}

// CreateRecovery is only exposed by the local administrative CLI. Recovery can
// restore published counts, but cannot invent progress never sent to the server.
func (s *Service) CreateRecovery(ctx context.Context, userID string) (TransferCode, error) {
	return s.createTransfer(ctx, userID, "", "", true)
}

func (s *Service) createTransfer(ctx context.Context, userID, epoch, snapshot string, recovery bool) (TransferCode, error) {
	if !recovery && !validTransferSnapshot(snapshot) {
		return TransferCode{}, ErrInvalidRequest
	}
	tx, err := s.beginWriteTransaction(ctx)
	if err != nil {
		return TransferCode{}, err
	}
	defer tx.release()
	defer tx.Rollback()
	var storedEpoch string
	if err = tx.QueryRowContext(ctx, `SELECT auth_epoch FROM users WHERE id=? AND enabled=1`, userID).Scan(&storedEpoch); err != nil {
		return TransferCode{}, ErrUnauthorized
	}
	if !recovery && storedEpoch != epoch {
		return TransferCode{}, ErrUnauthorized
	}
	if recovery {
		snapshot, err = recoverySnapshot(ctx, tx.Tx, userID)
		if err != nil {
			return TransferCode{}, databaseError(ctx, err)
		}
	}
	var entropy [5]byte
	if _, err = io.ReadFull(s.entropy, entropy[:]); err != nil {
		return TransferCode{}, ErrInternal
	}
	code := base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(entropy[:])
	hash, _ := HashToken(s.pepper, "transfer:"+code)
	now := s.clock.Now().UTC().Unix()
	// One outstanding code per account. A completed receipt remains retryable.
	if _, err = tx.ExecContext(ctx, `DELETE FROM device_transfers WHERE (user_id=? AND redeemed_at IS NULL) OR expires_at < ?`, userID, now-86400); err != nil {
		return TransferCode{}, databaseError(ctx, err)
	}
	expires := now + 600
	if _, err = tx.ExecContext(ctx, `INSERT INTO device_transfers(code_hash,user_id,snapshot,expires_at) VALUES(?,?,?,?)`, hash, userID, snapshot, expires); err != nil {
		return TransferCode{}, databaseError(ctx, err)
	}
	if err = s.commit(tx); err != nil {
		return TransferCode{}, databaseError(ctx, err)
	}
	return TransferCode{Code: code, ExpiresAt: expires * 1000}, nil
}

// RedeemTransfer is single-use across devices and retryable by the same durable
// receiver secret for 24 hours. Receipts are encrypted, never plaintext tokens.
func (s *Service) RedeemTransfer(ctx context.Context, code, receiver, peer string) (TransferResult, error) {
	if err := s.transferAttempt(ctx, peer); err != nil {
		return TransferResult{}, err
	}
	code = strings.ToUpper(strings.Join(strings.Fields(code), ""))
	if len(code) != 8 || !validRefreshTokenText(receiver) {
		return TransferResult{}, ErrTransferInvalid
	}
	hash, _ := HashToken(s.pepper, "transfer:"+code)
	receiverHash, _ := HashToken(s.pepper, "receiver:"+receiver)
	tx, err := s.beginWriteTransaction(ctx)
	if err != nil {
		return TransferResult{}, err
	}
	defer tx.release()
	defer tx.Rollback()
	var user users.User
	var snapshot string
	var expires int64
	var bound sql.NullString
	var redeemed sql.NullInt64
	var receipt []byte
	var epoch string
	err = tx.QueryRowContext(ctx, `SELECT t.user_id,u.nickname,t.snapshot,t.expires_at,t.receiver_hash,t.redeemed_at,t.response,u.auth_epoch FROM device_transfers t JOIN users u ON u.id=t.user_id WHERE t.code_hash=? AND u.enabled=1`, hash).Scan(&user.ID, &user.Nickname, &snapshot, &expires, &bound, &redeemed, &receipt, &epoch)
	if errors.Is(err, sql.ErrNoRows) {
		return TransferResult{}, ErrTransferInvalid
	}
	if err != nil {
		return TransferResult{}, databaseError(ctx, err)
	}
	now := s.clock.Now().UTC().Unix()
	if redeemed.Valid {
		if bound.String != receiverHash || now >= redeemed.Int64+86400 {
			return TransferResult{}, ErrTransferInvalid
		}
		result, err := s.openTransferReceipt(receipt, hash)
		if err != nil {
			return TransferResult{}, ErrInternal
		}
		if epoch != receiverHash {
			return TransferResult{}, ErrTransferInvalid
		}
		// Mint a fresh access token while preserving the unconsumed refresh token.
		var revoked sql.NullInt64
		refreshHash, _ := HashRefreshToken(s.pepper, result.Session.RefreshToken)
		if err := tx.QueryRowContext(ctx, `SELECT revoked_at FROM refresh_tokens WHERE token_hash=?`, refreshHash).Scan(&revoked); err != nil || revoked.Valid {
			return TransferResult{}, ErrTransferInvalid
		}
		fresh, err := s.newSessionAt(result.Session.User, now, epoch)
		if err != nil {
			return TransferResult{}, err
		}
		fresh.RefreshToken = result.Session.RefreshToken
		fresh.RefreshExpiresAt = result.Session.RefreshExpiresAt
		result.Session = fresh
		return result, nil
	}
	if now >= expires {
		return TransferResult{}, ErrTransferInvalid
	}
	session, err := s.newSessionAt(user, now, receiverHash)
	if err != nil {
		return TransferResult{}, err
	}
	result := TransferResult{Session: session, Snapshot: snapshot}
	receipt, err = s.sealTransferReceipt(result, hash)
	if err != nil {
		return TransferResult{}, ErrInternal
	}
	refreshHash, _ := HashRefreshToken(s.pepper, session.RefreshToken)
	statements := []struct {
		sql  string
		args []any
	}{
		{`UPDATE users SET auth_epoch=? WHERE id=?`, []any{receiverHash, user.ID}},
		{`UPDATE refresh_tokens SET revoked_at=COALESCE(revoked_at,?),revoked_reason='transfer' WHERE user_id=?`, []any{now, user.ID}},
		{`UPDATE resume_tokens SET revoked_at=? WHERE user_id=? AND revoked_at IS NULL`, []any{now * 1000, user.ID}},
		{`DELETE FROM launch_tickets WHERE user_id=?`, []any{user.ID}},
		{`INSERT INTO refresh_tokens(token_hash,user_id,expires_at,created_at) VALUES(?,?,?,?)`, []any{refreshHash, user.ID, session.RefreshExpiresAt.Unix(), now}},
		{`UPDATE device_transfers SET receiver_hash=?,redeemed_at=?,response=? WHERE code_hash=?`, []any{receiverHash, now, receipt, hash}},
		{`DELETE FROM device_transfers WHERE user_id=? AND code_hash<>?`, []any{user.ID, hash}},
	}
	for _, q := range statements {
		if _, err = tx.ExecContext(ctx, q.sql, q.args...); err != nil {
			return TransferResult{}, databaseError(ctx, err)
		}
	}
	if err = s.commit(tx); err != nil {
		return TransferResult{}, databaseError(ctx, err)
	}
	return result, nil
}

func (s *Service) transferAttempt(ctx context.Context, peer string) error {
	hash, _ := HashToken(s.pepper, "transfer-peer:"+peer)
	tx, err := s.beginWriteTransaction(ctx)
	if err != nil {
		return err
	}
	defer tx.release()
	defer tx.Rollback()
	window := s.clock.Now().Unix() / 60
	if _, err = tx.ExecContext(ctx, `DELETE FROM transfer_attempts WHERE window<>?`, window); err != nil {
		return ErrInternal
	}
	limited := false
	for _, bucket := range []string{"global", hash} {
		if _, err = tx.ExecContext(ctx, `INSERT INTO transfer_attempts(bucket,window,attempts) VALUES(?,?,1) ON CONFLICT(bucket) DO UPDATE SET attempts=attempts+1`, bucket, window); err != nil {
			return ErrInternal
		}
		var count int
		if err = tx.QueryRowContext(ctx, `SELECT attempts FROM transfer_attempts WHERE bucket=?`, bucket).Scan(&count); err != nil {
			return ErrInternal
		}
		limit := 30
		if bucket == "global" {
			limit = 300
		}
		if count > limit {
			limited = true
		}
	}
	if err = s.commit(tx); err != nil {
		return ErrInternal
	}
	if limited {
		return ErrTransferLimited
	}
	return nil
}

func (s *Service) transferCipher() (cipher.AEAD, error) {
	key := sha256.Sum256(append([]byte("gamebox-transfer-receipt:"), s.jwtSecret...))
	block, err := aes.NewCipher(key[:])
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}
func (s *Service) sealTransferReceipt(result TransferResult, aad string) ([]byte, error) {
	a, err := s.transferCipher()
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, a.NonceSize())
	if _, err = io.ReadFull(s.entropy, nonce); err != nil {
		return nil, err
	}
	data, err := json.Marshal(result)
	if err != nil {
		return nil, err
	}
	return a.Seal(nonce, nonce, data, []byte(aad)), nil
}
func (s *Service) openTransferReceipt(data []byte, aad string) (TransferResult, error) {
	var r TransferResult
	a, err := s.transferCipher()
	if err != nil {
		return r, err
	}
	if len(data) < a.NonceSize() {
		return r, ErrInternal
	}
	plain, err := a.Open(nil, data[:a.NonceSize()], data[a.NonceSize():], []byte(aad))
	if err != nil {
		return r, err
	}
	err = json.Unmarshal(plain, &r)
	return r, err
}

func validTransferSnapshot(raw string) bool {
	if len(raw) > 16384 {
		return false
	}
	var data map[string]json.RawMessage
	if json.Unmarshal([]byte(raw), &data) != nil {
		return false
	}
	var version int
	var counts []int
	var serial int
	var cat int
	var claimed, winning bool
	if json.Unmarshal(data["version"], &version) != nil || version != 3 || json.Unmarshal(data["counts"], &counts) != nil || (len(counts) != 24 && len(counts) != 48) || json.Unmarshal(data["serial"], &serial) != nil || serial < 1 || json.Unmarshal(data["cat"], &cat) != nil || cat < 0 || cat >= len(counts) || json.Unmarshal(data["claimed"], &claimed) != nil || json.Unmarshal(data["winning"], &winning) != nil {
		return false
	}
	var recovered bool
	if raw, ok := data["recoveredDates"]; ok {
		if json.Unmarshal(raw, &recovered) != nil || !recovered {
			return false
		}
	}
	if len(data) != 9 && !(len(data) == 10 && recovered) {
		return false
	}
	for _, key := range []string{"version", "counts", "firstFound", "favorites", "cat", "claimed", "winning", "isNew", "serial"} {
		if value, ok := data[key]; !ok || string(value) == "null" {
			return false
		}
	}
	var first []*string
	var favorites []int
	var isNew bool
	if json.Unmarshal(data["firstFound"], &first) != nil || len(first) != len(counts) || json.Unmarshal(data["favorites"], &favorites) != nil || len(favorites) > 6 || json.Unmarshal(data["isNew"], &isNew) != nil {
		return false
	}
	seen := map[int]bool{}
	for _, i := range favorites {
		if i < 0 || i >= len(counts) || counts[i] == 0 || seen[i] {
			return false
		}
		seen[i] = true
	}
	for i, value := range first {
		if counts[i] == 0 {
			if value != nil {
				return false
			}
			continue
		}
		if value == nil && recovered {
			continue
		}
		if value == nil || len(*value) < 10 || len(*value) > 40 {
			return false
		}
		if _, err := time.Parse(time.RFC3339Nano, *value); err != nil {
			if _, err = time.Parse("2006-01-02T15:04:05.999999999", *value); err != nil {
				if _, err = time.Parse("2006-01-02", *value); err != nil {
					return false
				}
			}
		}
	}
	for _, n := range counts {
		if n < 0 || n > 1000000000 {
			return false
		}
	}
	return !claimed || !winning || counts[cat] > 0
}
func recoverySnapshot(ctx context.Context, tx *sql.Tx, userID string) (string, error) {
	counts := make([]int, 48)
	var raw string
	var updated int64
	err := tx.QueryRowContext(ctx, `SELECT counts_json,updated_at FROM scratch_collections WHERE user_id=?`, userID).Scan(&raw, &updated)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return "", err
	}
	if err == nil {
		if err = json.Unmarshal([]byte(raw), &counts); err != nil {
			return "", err
		}
	}
	first := make([]*string, len(counts))
	data, err := json.Marshal(map[string]any{"version": 3, "recoveredDates": true, "counts": counts, "firstFound": first, "favorites": []int{}, "cat": 0, "claimed": false, "winning": false, "isNew": false, "serial": 1})
	return string(data), err
}

// CancelTransfer only cancels unused codes. Completed receipt recovery survives.
func (s *Service) CancelTransfer(ctx context.Context, access string) error {
	identity, err := s.ParseAccess(access)
	if err != nil {
		return err
	}
	_, err = s.db.ExecContext(ctx, `DELETE FROM device_transfers WHERE user_id=? AND redeemed_at IS NULL AND EXISTS(SELECT 1 FROM users WHERE id=? AND auth_epoch=?)`, identity.UserID, identity.UserID, identity.Epoch)
	return err
}
