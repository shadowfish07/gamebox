package matches

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"database/sql/driver"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"reflect"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
	sqlite "modernc.org/sqlite"
	sqlite3 "modernc.org/sqlite/lib"

	"me.zqydev/gamebox/server/internal/clock"
	"me.zqydev/gamebox/server/internal/diagnostics"
	"me.zqydev/gamebox/server/internal/games"
	"me.zqydev/gamebox/server/internal/games/chinesecheckers"
	"me.zqydev/gamebox/server/internal/games/flightchess"
	"me.zqydev/gamebox/server/internal/games/gomoku"
	"me.zqydev/gamebox/server/internal/games/rps"
	"me.zqydev/gamebox/server/internal/protocol"
	"me.zqydev/gamebox/server/internal/users"
)

var (
	ErrInvalidConfiguration = errors.New("invalid match configuration")
	ErrInvalidRequest       = errors.New("invalid_request")
	ErrActiveMatchExists    = errors.New("active_match_exists")
	ErrOpponentBusy         = errors.New("opponent_busy")
	ErrMatchNotFound        = errors.New("match_not_found")
	ErrMatchNotCancellable  = errors.New("match_not_cancellable")
	ErrStaleRevision        = errors.New("stale_revision")
	ErrActionConflict       = errors.New("action_conflict")
	ErrTicketInvalid        = errors.New("ticket_invalid")
	ErrResumeExpired        = errors.New("resume_expired")
	ErrInternal             = errors.New("internal_error")
)

const (
	matchSQLiteBusySlice      = 25 * time.Millisecond
	matchWriteLimit           = 5 * time.Second
	matchConnectionCleanLimit = time.Second
	matchSQLiteBusyCode       = 5
	maximumIdentifierBytes    = 128
	maximumActionPayloadBytes = 1024
	maximumMatchEvents        = 226
	maximumFlightChessEvents  = 512
	cancelledPayloadJSON      = `{}`
	fullyOfflineAbandonAfter  = 24 * time.Hour
	launchTicketLifetime      = 60 * time.Second
	launchTicketEntropyBytes  = 32
	launchTicketCollisionMax  = 8
	minimumTokenPepperBytes   = 32
	launchTicketHashDomain    = "gamebox/launch-ticket-hash/v1"
	resumeTokenLifetime       = 30 * time.Minute
	resumeTokenHashDomain     = "gamebox/resume-token-hash/v1"
)

// ServiceConfig supplies the independent randomness and secret used by the
// HTTP launch-ticket boundary. String formatting always redacts the secret.
type ServiceConfig struct {
	ColorRandom        io.Reader
	LaunchTicketRandom io.Reader
	TokenPepper        string
}

func (config ServiceConfig) String() string {
	return "ServiceConfig{ColorRandom:<reader> LaunchTicketRandom:<reader> TokenPepper:<redacted>}"
}

func (config ServiceConfig) GoString() string { return config.String() }

// ActiveMatch is the lobby projection for one user's single active game slot.
type ActiveMatch struct {
	ID               string
	GameID           string
	OpponentID       string
	OpponentNickname string
	Color            Color
	Revision         int64
	GameConfig       json.RawMessage
}

// Opponent is a non-secret lobby projection. Availability is derived from the
// durable game slot; Presence is advisory and never gates match creation.
type Opponent struct {
	ID           string
	Nickname     string
	Availability string
	Presence     string
}

// LaunchTicket is returned exactly once after its independent hash commits.
type LaunchTicket struct {
	MatchID   string
	GameID    string
	Token     string
	ExpiresAt time.Time
}

// CredentialRequest carries exactly one secret from the first WebSocket
// message. It is intentionally never formatted into errors or logs.
type CredentialRequest struct {
	LaunchTicket string
	ResumeToken  string
}

func (request CredentialRequest) String() string {
	return fmt.Sprintf("CredentialRequest{LaunchTicket:<redacted:%t> ResumeToken:<redacted:%t>}", request.LaunchTicket != "", request.ResumeToken != "")
}

func (request CredentialRequest) GoString() string { return request.String() }

// ConnectionCredential is returned only after ticket consumption/token
// issuance or resume sliding-expiry has committed.
type ConnectionCredential struct {
	UserID          string
	MatchID         string
	GameID          string
	ResumeToken     string
	ResumeExpiresAt time.Time
}

func (credential ConnectionCredential) String() string {
	return fmt.Sprintf("ConnectionCredential{UserID:%q MatchID:%q GameID:%q ResumeToken:<redacted> ResumeExpiresAt:%s}",
		credential.UserID, credential.MatchID, credential.GameID, credential.ResumeExpiresAt.UTC().Format(time.RFC3339))
}

func (credential ConnectionCredential) GoString() string { return credential.String() }

func (ticket LaunchTicket) String() string {
	return fmt.Sprintf("LaunchTicket{MatchID:%q GameID:%q ExpiresAt:%s Token:<redacted>}", ticket.MatchID, ticket.GameID, ticket.ExpiresAt.UTC().Format(time.RFC3339))
}

func (ticket LaunchTicket) GoString() string { return ticket.String() }

// Service atomically owns match creation and lifecycle transitions. The
// database must be opened by store.Open so BeginTx acquires an immediate
// SQLite write transaction.
type Service struct {
	db             *sql.DB
	games          *games.Registry
	clock          clock.Clock
	random         io.Reader
	randomMu       sync.Mutex
	ticketRandom   io.Reader
	ticketRandomMu sync.Mutex
	tokenPepper    string
}

func (service *Service) String() string {
	return "Service{database:<configured> games:<configured> clock:<configured> random:<reader> ticketRandom:<reader> tokenPepper:<redacted>}"
}

func (service *Service) GoString() string { return service.String() }

// NewService validates the complete dependency set. Production callers omit
// randomSource and receive crypto/rand.Reader; tests may supply exactly one
// deterministic reader.
func NewService(db *sql.DB, registry *games.Registry, serviceClock clock.Clock, randomSource ...io.Reader) (*Service, error) {
	if db == nil || registry == nil || nilDependency(serviceClock) || len(randomSource) > 1 {
		return nil, ErrInvalidConfiguration
	}
	colorRandom := io.Reader(rand.Reader)
	if len(randomSource) == 1 {
		if nilDependency(randomSource[0]) {
			return nil, ErrInvalidConfiguration
		}
		colorRandom = randomSource[0]
	}
	return &Service{db: db, games: registry, clock: serviceClock, random: colorRandom, ticketRandom: rand.Reader}, nil
}

// NewServiceWithConfig constructs the complete service used by the HTTP and
// WebSocket composition root. NewService remains available to rules/lifecycle
// tests that do not issue launch credentials.
func NewServiceWithConfig(db *sql.DB, registry *games.Registry, serviceClock clock.Clock, config ServiceConfig) (*Service, error) {
	if db == nil || registry == nil || nilDependency(serviceClock) || nilDependency(config.ColorRandom) ||
		nilDependency(config.LaunchTicketRandom) || len([]byte(config.TokenPepper)) < minimumTokenPepperBytes {
		return nil, ErrInvalidConfiguration
	}
	return &Service{
		db: db, games: registry, clock: serviceClock,
		random: config.ColorRandom, ticketRandom: config.LaunchTicketRandom, tokenPepper: config.TokenPepper,
	}, nil
}

// CurrentMatch returns nil when the user's durable game slot is idle. A slot
// that disagrees with match lifecycle or seating is treated as corruption
// instead of being hidden as idle/active lobby state.
func (service *Service) CurrentMatch(ctx context.Context, gameID, userID string) (_ *ActiveMatch, err error) {
	if !service.configured() {
		return nil, ErrInvalidConfiguration
	}
	if ctx == nil || !canonicalUUID(userID) {
		return nil, ErrInvalidRequest
	}
	rules, ok := service.games.Lookup(gameID)
	if !ok || rules.PlayerLimit() != 2 || !singleActiveMatch(rules) {
		return nil, ErrInvalidRequest
	}
	transaction, beginErr := service.db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if beginErr != nil {
		return nil, matchDatabaseError(ctx, beginErr)
	}
	defer func() {
		if rollbackErr := transaction.Rollback(); rollbackErr != nil && !errors.Is(rollbackErr, sql.ErrTxDone) && err == nil {
			err = matchDatabaseError(ctx, rollbackErr)
		}
	}()

	var matchID string
	queryErr := transaction.QueryRowContext(ctx, `
SELECT match_id
FROM active_game_slots
WHERE game_id=? AND user_id=?`, gameID, userID).Scan(&matchID)
	if errors.Is(queryErr, sql.ErrNoRows) {
		var orphanedActiveMembership int
		if checkErr := transaction.QueryRowContext(ctx, `
SELECT EXISTS(
  SELECT 1
  FROM match_players
  JOIN matches ON matches.id=match_players.match_id
  WHERE match_players.user_id=? AND matches.game_id=? AND matches.status=?
)`, userID, gameID, StatusActive).Scan(&orphanedActiveMembership); checkErr != nil {
			return nil, matchDatabaseError(ctx, checkErr)
		}
		if orphanedActiveMembership != 0 {
			return nil, ErrInternal
		}
		if commitErr := transaction.Commit(); commitErr != nil {
			return nil, matchDatabaseError(ctx, commitErr)
		}
		return nil, nil
	}
	if queryErr != nil {
		return nil, matchDatabaseError(ctx, queryErr)
	}
	if !canonicalUUID(matchID) {
		return nil, ErrInternal
	}
	match, players, loadErr := loadMatchAndPlayers(ctx, transaction, matchID)
	if loadErr != nil {
		return nil, loadErr
	}
	if match.GameID != gameID || match.Status != StatusActive {
		return nil, ErrInternal
	}
	if _, snapshotErr := service.rebuildSnapshot(ctx, transaction, match, players); snapshotErr != nil {
		return nil, snapshotErr
	}
	player, opponent, member := actionPlayers(players, userID)
	if !member {
		return nil, ErrInternal
	}
	playerIDs := [2]string{players[0].UserID, players[1].UserID}
	if slotErr := validateCompleteActiveSlotSet(ctx, transaction, gameID, matchID, playerIDs, true); slotErr != nil {
		return nil, slotErr
	}
	var nickname, normalizedNickname string
	var enabled int
	if opponentErr := transaction.QueryRowContext(ctx, `
SELECT nickname,normalized_nickname,enabled
FROM users
WHERE id=?`, opponent.UserID).Scan(&nickname, &normalizedNickname, &enabled); opponentErr != nil {
		return nil, matchDatabaseError(ctx, opponentErr)
	}
	if !validStoredUser(opponent.UserID, nickname, normalizedNickname) || (enabled != 0 && enabled != 1) {
		return nil, ErrInternal
	}
	if commitErr := transaction.Commit(); commitErr != nil {
		return nil, matchDatabaseError(ctx, commitErr)
	}
	return &ActiveMatch{
		ID: match.ID, GameID: match.GameID, OpponentID: opponent.UserID,
		OpponentNickname: nickname, Color: player.Color, Revision: match.Revision,
		GameConfig: append(json.RawMessage(nil), match.GameConfig...),
	}, nil
}

// ListOpponents returns all enabled users except the caller in stable
// nickname/id order. Availability comes only from the durable game slot;
// offline idle users intentionally remain selectable.
func (service *Service) ListOpponents(ctx context.Context, gameID, userID string) (_ []Opponent, err error) {
	if !service.configured() {
		return nil, ErrInvalidConfiguration
	}
	if ctx == nil || !canonicalUUID(userID) {
		return nil, ErrInvalidRequest
	}
	rules, ok := service.games.Lookup(gameID)
	if !ok || !singleActiveMatch(rules) {
		return nil, ErrInvalidRequest
	}
	nowMillis := service.clock.Now().UTC().UnixMilli()
	onlineCutoff, cutoffOK := safeSubtractMilliseconds(nowMillis, (90 * time.Second).Milliseconds())
	if !cutoffOK {
		return nil, ErrInternal
	}
	transaction, beginErr := service.db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if beginErr != nil {
		return nil, matchDatabaseError(ctx, beginErr)
	}
	defer func() {
		if rollbackErr := transaction.Rollback(); rollbackErr != nil && !errors.Is(rollbackErr, sql.ErrTxDone) && err == nil {
			err = matchDatabaseError(ctx, rollbackErr)
		}
	}()
	var callerEnabled int
	if callerErr := transaction.QueryRowContext(ctx, `SELECT enabled FROM users WHERE id=?`, userID).Scan(&callerEnabled); callerErr != nil {
		if errors.Is(callerErr, sql.ErrNoRows) {
			return nil, ErrInvalidRequest
		}
		return nil, matchDatabaseError(ctx, callerErr)
	}
	if callerEnabled != 1 {
		return nil, ErrInvalidRequest
	}
	rows, queryErr := transaction.QueryContext(ctx, `
SELECT users.id,users.nickname,users.normalized_nickname,users.enabled,users.last_seen_at,
       CASE WHEN active_game_slots.user_id IS NULL THEN 0 ELSE 1 END
FROM users
LEFT JOIN active_game_slots
  ON active_game_slots.game_id=? AND active_game_slots.user_id=users.id
WHERE users.enabled=1 AND users.id<>?`, gameID, userID)
	if queryErr != nil {
		return nil, matchDatabaseError(ctx, queryErr)
	}
	defer rows.Close()
	opponents := make([]Opponent, 0, 16)
	for rows.Next() {
		var id, nickname, normalizedNickname string
		var enabled, busy int
		var lastSeen sql.NullInt64
		if scanErr := rows.Scan(&id, &nickname, &normalizedNickname, &enabled, &lastSeen, &busy); scanErr != nil {
			return nil, matchDatabaseError(ctx, scanErr)
		}
		if !validStoredUser(id, nickname, normalizedNickname) || enabled != 1 || (busy != 0 && busy != 1) {
			return nil, ErrInternal
		}
		availability := "idle"
		if busy == 1 {
			availability = "busy"
		}
		presence := "offline"
		if lastSeen.Valid && lastSeen.Int64 >= onlineCutoff {
			presence = "online"
		}
		opponents = append(opponents, Opponent{ID: id, Nickname: nickname, Availability: availability, Presence: presence})
	}
	if rowsErr := rows.Err(); rowsErr != nil {
		return nil, matchDatabaseError(ctx, rowsErr)
	}
	if closeErr := rows.Close(); closeErr != nil {
		return nil, matchDatabaseError(ctx, closeErr)
	}
	sort.Slice(opponents, func(left, right int) bool {
		leftFolded, rightFolded := strings.ToLower(opponents[left].Nickname), strings.ToLower(opponents[right].Nickname)
		if leftFolded != rightFolded {
			return leftFolded < rightFolded
		}
		if opponents[left].Nickname != opponents[right].Nickname {
			return opponents[left].Nickname < opponents[right].Nickname
		}
		return opponents[left].ID < opponents[right].ID
	})
	if commitErr := transaction.Commit(); commitErr != nil {
		return nil, matchDatabaseError(ctx, commitErr)
	}
	return opponents, nil
}

// CreateLaunchTicket validates active membership and stores only an
// independently domain-separated credential hash. Hash collisions are retried
// inside the same transaction; no plaintext is returned until commit succeeds.
func (service *Service) CreateLaunchTicket(ctx context.Context, matchID, userID string) (_ LaunchTicket, err error) {
	if !service.configured() || nilDependency(service.ticketRandom) || len([]byte(service.tokenPepper)) < minimumTokenPepperBytes {
		return LaunchTicket{}, ErrInvalidConfiguration
	}
	if ctx == nil || !canonicalUUID(matchID) || !canonicalUUID(userID) {
		return LaunchTicket{}, ErrInvalidRequest
	}
	transaction, beginErr := service.beginWriteTransaction(ctx)
	if beginErr != nil {
		return LaunchTicket{}, beginErr
	}
	defer func() {
		if rollbackErr := transaction.Rollback(); rollbackErr != nil && !errors.Is(rollbackErr, sql.ErrTxDone) && err == nil {
			err = matchDatabaseError(ctx, rollbackErr)
		}
		_ = transaction.release()
	}()

	match, players, loadErr := loadMatchAndPlayers(ctx, transaction.Tx, matchID)
	if loadErr != nil {
		return LaunchTicket{}, loadErr
	}
	if match.Status != StatusActive || !playerMember(players, userID) {
		return LaunchTicket{}, ErrMatchNotFound
	}
	if _, snapshotErr := service.rebuildSnapshot(ctx, transaction.Tx, match, players); snapshotErr != nil {
		return LaunchTicket{}, snapshotErr
	}
	rules, ok := service.games.Lookup(match.GameID)
	if !ok || rules.PlayerLimit() != 2 {
		return LaunchTicket{}, ErrInternal
	}
	playerIDs := [2]string{players[0].UserID, players[1].UserID}
	if slotsErr := validateCompleteActiveSlotSet(ctx, transaction.Tx, match.GameID, match.ID, playerIDs, singleActiveMatch(rules)); slotsErr != nil {
		return LaunchTicket{}, slotsErr
	}
	nowMillis := service.clock.Now().UTC().UnixMilli()
	expiresMillis, expiryOK := safeAddMilliseconds(nowMillis, launchTicketLifetime.Milliseconds())
	if !expiryOK {
		return LaunchTicket{}, ErrInternal
	}
	var plaintext string
	var insertedHash string
	inserted := false
	for attempt := 0; attempt < launchTicketCollisionMax; attempt++ {
		if contextErr := ctx.Err(); contextErr != nil {
			return LaunchTicket{}, contextErr
		}
		var tokenErr error
		plaintext, tokenErr = service.randomLaunchTicket()
		if tokenErr != nil {
			return LaunchTicket{}, ErrInternal
		}
		hash, hashErr := hashLaunchTicket(service.tokenPepper, plaintext)
		if hashErr != nil {
			return LaunchTicket{}, ErrInternal
		}
		result, insertErr := transaction.ExecContext(ctx, `
INSERT INTO launch_tickets(token_hash,match_id,user_id,game_id,expires_at,created_at)
VALUES (?,?,?,?,?,?)`, hash, match.ID, userID, match.GameID, expiresMillis, nowMillis)
		if insertErr != nil {
			if isLaunchTicketHashConflict(insertErr) {
				continue
			}
			return LaunchTicket{}, matchDatabaseError(ctx, insertErr)
		}
		if affectedExactlyOne(result) != nil {
			return LaunchTicket{}, ErrInternal
		}
		inserted = true
		insertedHash = hash
		break
	}
	if !inserted {
		return LaunchTicket{}, ErrInternal
	}
	if _, deleteErr := transaction.ExecContext(ctx, `
DELETE FROM launch_tickets
WHERE match_id=? AND user_id=? AND game_id=? AND token_hash<>?`, match.ID, userID, match.GameID, insertedHash); deleteErr != nil {
		return LaunchTicket{}, matchDatabaseError(ctx, deleteErr)
	}
	if commitErr := transaction.Commit(); commitErr != nil {
		return LaunchTicket{}, matchDatabaseError(ctx, commitErr)
	}
	return LaunchTicket{
		MatchID: match.ID, GameID: match.GameID, Token: plaintext,
		ExpiresAt: time.UnixMilli(expiresMillis).UTC(),
	}, nil
}

func safeAddMilliseconds(value, delta int64) (int64, bool) {
	if delta < 0 || value > math.MaxInt64-delta {
		return 0, false
	}
	return value + delta, true
}

func safeSubtractMilliseconds(value, delta int64) (int64, bool) {
	if delta < 0 || value < math.MinInt64+delta {
		return 0, false
	}
	return value - delta, true
}

func validStoredUser(id, nickname, normalizedNickname string) bool {
	if !canonicalUUID(id) {
		return false
	}
	display, normalized, normalizeErr := users.NormalizeNickname(nickname)
	return normalizeErr == nil && display == nickname && normalized == normalizedNickname
}

func (service *Service) randomLaunchTicket() (string, error) {
	service.ticketRandomMu.Lock()
	defer service.ticketRandomMu.Unlock()
	bytes := make([]byte, launchTicketEntropyBytes)
	if _, err := io.ReadFull(service.ticketRandom, bytes); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(bytes), nil
}

func hashLaunchTicket(pepper, plaintext string) (string, error) {
	if pepper == "" || plaintext == "" {
		return "", ErrInvalidRequest
	}
	hasher := sha256.New()
	_, _ = hasher.Write([]byte(launchTicketHashDomain))
	writeCredentialHashField(hasher, []byte(pepper))
	writeCredentialHashField(hasher, []byte(plaintext))
	return hex.EncodeToString(hasher.Sum(nil)), nil
}

func writeCredentialHashField(destination io.Writer, field []byte) {
	var length [8]byte
	binary.BigEndian.PutUint64(length[:], uint64(len(field)))
	_, _ = destination.Write(length[:])
	_, _ = destination.Write(field)
}

func isLaunchTicketHashConflict(err error) bool {
	var sqliteErr *sqlite.Error
	if !errors.As(err, &sqliteErr) {
		return false
	}
	code := sqliteErr.Code()
	return (code == sqlite3.SQLITE_CONSTRAINT_PRIMARYKEY || code == sqlite3.SQLITE_CONSTRAINT_UNIQUE) &&
		strings.Contains(sqliteErr.Error(), "UNIQUE constraint failed: launch_tickets.token_hash")
}

// ConnectCredential authenticates a WebSocket's first message. Launch ticket
// consumption and resume-token issuance share one IMMEDIATE transaction;
// successful resume re-use slides expiry from the service clock.
func (service *Service) ConnectCredential(ctx context.Context, request CredentialRequest) (_ ConnectionCredential, err error) {
	if !service.configured() || nilDependency(service.ticketRandom) || len([]byte(service.tokenPepper)) < minimumTokenPepperBytes {
		return ConnectionCredential{}, ErrInvalidConfiguration
	}
	if ctx == nil {
		return ConnectionCredential{}, ErrInvalidRequest
	}
	launch := request.LaunchTicket != ""
	resume := request.ResumeToken != ""
	if launch == resume {
		return ConnectionCredential{}, ErrInvalidRequest
	}
	plaintext := request.LaunchTicket
	domain := launchTicketHashDomain
	credentialFailure := ErrTicketInvalid
	if resume {
		plaintext = request.ResumeToken
		domain = resumeTokenHashDomain
		credentialFailure = ErrResumeExpired
	}
	if !validOpaqueCredential(plaintext) {
		return ConnectionCredential{}, credentialFailure
	}
	tokenHash, hashErr := hashCredential(service.tokenPepper, plaintext, domain)
	if hashErr != nil {
		return ConnectionCredential{}, credentialFailure
	}
	transaction, beginErr := service.beginWriteTransaction(ctx)
	if beginErr != nil {
		return ConnectionCredential{}, beginErr
	}
	defer func() {
		if rollbackErr := transaction.Rollback(); rollbackErr != nil && !errors.Is(rollbackErr, sql.ErrTxDone) && err == nil {
			err = matchDatabaseError(ctx, rollbackErr)
		}
		_ = transaction.release()
	}()
	// Sliding expiry starts only after the IMMEDIATE write lock has been
	// acquired; time spent waiting for SQLite never shortens the session.
	nowMillis := service.clock.Now().UTC().UnixMilli()
	expiresMillis, expiryOK := safeAddMilliseconds(nowMillis, resumeTokenLifetime.Milliseconds())
	if !expiryOK {
		return ConnectionCredential{}, ErrInternal
	}

	var matchID, userID, storedGameID string
	if launch {
		var storedExpires int64
		var consumed sql.NullInt64
		queryErr := transaction.QueryRowContext(ctx, `
SELECT match_id,user_id,game_id,expires_at,consumed_at
FROM launch_tickets
WHERE token_hash=?`, tokenHash).Scan(&matchID, &userID, &storedGameID, &storedExpires, &consumed)
		if errors.Is(queryErr, sql.ErrNoRows) || queryErr == nil && (consumed.Valid || storedExpires <= nowMillis) {
			return ConnectionCredential{}, ErrTicketInvalid
		}
		if queryErr != nil {
			return ConnectionCredential{}, matchDatabaseError(ctx, queryErr)
		}
	} else {
		var storedExpires, lastUsed int64
		var revoked sql.NullInt64
		queryErr := transaction.QueryRowContext(ctx, `
SELECT match_id,user_id,expires_at,last_used_at,revoked_at
FROM resume_tokens
WHERE token_hash=?`, tokenHash).Scan(&matchID, &userID, &storedExpires, &lastUsed, &revoked)
		if errors.Is(queryErr, sql.ErrNoRows) || queryErr == nil && (revoked.Valid || storedExpires <= nowMillis || lastUsed > storedExpires) {
			return ConnectionCredential{}, ErrResumeExpired
		}
		if queryErr != nil {
			return ConnectionCredential{}, matchDatabaseError(ctx, queryErr)
		}
	}
	if !canonicalUUID(matchID) || !canonicalUUID(userID) {
		return ConnectionCredential{}, credentialFailure
	}
	match, players, loadErr := loadMatchAndPlayers(ctx, transaction.Tx, matchID)
	if loadErr != nil {
		if errors.Is(loadErr, ErrMatchNotFound) {
			return ConnectionCredential{}, credentialFailure
		}
		return ConnectionCredential{}, loadErr
	}
	if match.Status != StatusActive || !playerMember(players, userID) || launch && storedGameID != match.GameID {
		return ConnectionCredential{}, credentialFailure
	}
	var userEnabled int
	queryErr := transaction.QueryRowContext(ctx, `SELECT enabled FROM users WHERE id=?`, userID).Scan(&userEnabled)
	if errors.Is(queryErr, sql.ErrNoRows) || queryErr == nil && userEnabled != 1 {
		return ConnectionCredential{}, credentialFailure
	}
	if queryErr != nil {
		return ConnectionCredential{}, matchDatabaseError(ctx, queryErr)
	}
	if _, snapshotErr := service.rebuildSnapshot(ctx, transaction.Tx, match, players); snapshotErr != nil {
		return ConnectionCredential{}, snapshotErr
	}

	resumePlaintext := plaintext
	if launch {
		result, updateErr := transaction.ExecContext(ctx, `
UPDATE launch_tickets
SET consumed_at=?
WHERE token_hash=? AND consumed_at IS NULL AND expires_at>?`, nowMillis, tokenHash, nowMillis)
		if updateErr != nil {
			return ConnectionCredential{}, matchDatabaseError(ctx, updateErr)
		}
		if affectedExactlyOne(result) != nil {
			return ConnectionCredential{}, ErrTicketInvalid
		}
		var insertedHash string
		inserted := false
		for attempt := 0; attempt < launchTicketCollisionMax; attempt++ {
			resumePlaintext, err = service.randomLaunchTicket()
			if err != nil {
				return ConnectionCredential{}, ErrInternal
			}
			resumeHash, resumeHashErr := hashCredential(service.tokenPepper, resumePlaintext, resumeTokenHashDomain)
			if resumeHashErr != nil {
				return ConnectionCredential{}, ErrInternal
			}
			result, insertErr := transaction.ExecContext(ctx, `
INSERT INTO resume_tokens(token_hash,match_id,user_id,expires_at,last_used_at,created_at)
VALUES (?,?,?,?,?,?)`, resumeHash, matchID, userID, expiresMillis, nowMillis, nowMillis)
			if insertErr != nil {
				if isResumeTokenHashConflict(insertErr) {
					continue
				}
				return ConnectionCredential{}, matchDatabaseError(ctx, insertErr)
			}
			if affectedExactlyOne(result) != nil {
				return ConnectionCredential{}, ErrInternal
			}
			inserted = true
			insertedHash = resumeHash
			break
		}
		if !inserted {
			return ConnectionCredential{}, ErrInternal
		}
		if _, deleteErr := transaction.ExecContext(ctx, `
DELETE FROM resume_tokens
WHERE match_id=? AND user_id=? AND token_hash<>?`, matchID, userID, insertedHash); deleteErr != nil {
			return ConnectionCredential{}, matchDatabaseError(ctx, deleteErr)
		}
	} else {
		result, updateErr := transaction.ExecContext(ctx, `
UPDATE resume_tokens
SET last_used_at=?,expires_at=?
WHERE token_hash=? AND revoked_at IS NULL AND expires_at>?`, nowMillis, expiresMillis, tokenHash, nowMillis)
		if updateErr != nil {
			return ConnectionCredential{}, matchDatabaseError(ctx, updateErr)
		}
		if affectedExactlyOne(result) != nil {
			return ConnectionCredential{}, ErrResumeExpired
		}
	}
	if commitErr := transaction.Commit(); commitErr != nil {
		return ConnectionCredential{}, matchDatabaseError(ctx, commitErr)
	}
	return ConnectionCredential{
		UserID: userID, MatchID: matchID, GameID: match.GameID,
		ResumeToken: resumePlaintext, ResumeExpiresAt: time.UnixMilli(expiresMillis).UTC(),
	}, nil
}

func validOpaqueCredential(value string) bool {
	if value == "" || len(value) > 256 || strings.ContainsAny(value, " \t\r\n") {
		return false
	}
	decoded, err := base64.RawURLEncoding.DecodeString(value)
	return err == nil && len(decoded) == launchTicketEntropyBytes && base64.RawURLEncoding.EncodeToString(decoded) == value
}

func hashCredential(pepper, plaintext, domain string) (string, error) {
	if pepper == "" || plaintext == "" || domain == "" {
		return "", ErrInvalidRequest
	}
	hasher := sha256.New()
	_, _ = hasher.Write([]byte(domain))
	writeCredentialHashField(hasher, []byte(pepper))
	writeCredentialHashField(hasher, []byte(plaintext))
	return hex.EncodeToString(hasher.Sum(nil)), nil
}

func isResumeTokenHashConflict(err error) bool {
	var sqliteErr *sqlite.Error
	if !errors.As(err, &sqliteErr) {
		return false
	}
	code := sqliteErr.Code()
	return (code == sqlite3.SQLITE_CONSTRAINT_PRIMARYKEY || code == sqlite3.SQLITE_CONSTRAINT_UNIQUE) &&
		strings.Contains(sqliteErr.Error(), "UNIQUE constraint failed: resume_tokens.token_hash")
}

// Create atomically creates a two-player match without game-specific options.
func (service *Service) Create(ctx context.Context, gameID, initiatorID, opponentID string) (_ Match, err error) {
	return service.CreateWithConfig(ctx, gameID, initiatorID, opponentID, nil)
}

// CreateWithConfig atomically creates a two-player match and persists the
// configured game's immutable initial options.
func (service *Service) CreateWithConfig(ctx context.Context, gameID, initiatorID, opponentID string, config json.RawMessage) (_ Match, err error) {
	if !service.configured() {
		return Match{}, ErrInvalidConfiguration
	}
	if ctx == nil || !validIdentifier(initiatorID) || !validIdentifier(opponentID) || initiatorID == opponentID {
		return Match{}, ErrInvalidRequest
	}
	template, ok := service.games.Lookup(gameID)
	if !ok || template.PlayerLimit() != 2 {
		return Match{}, ErrInvalidRequest
	}
	rules, normalizedConfig, configErr := configureRules(template, config)
	if configErr != nil {
		return Match{}, ErrInvalidRequest
	}

	transaction, beginErr := service.beginWriteTransaction(ctx)
	if beginErr != nil {
		return Match{}, beginErr
	}
	defer func() {
		if rollbackErr := transaction.Rollback(); rollbackErr != nil && !errors.Is(rollbackErr, sql.ErrTxDone) && err == nil {
			err = matchDatabaseError(ctx, rollbackErr)
		}
		_ = transaction.release()
	}()

	if enabled, queryErr := enabledUser(ctx, transaction.Tx, initiatorID); queryErr != nil {
		if errors.Is(queryErr, sql.ErrNoRows) {
			return Match{}, ErrInvalidRequest
		}
		return Match{}, matchDatabaseError(ctx, queryErr)
	} else if !enabled {
		return Match{}, ErrInvalidRequest
	}
	if enabled, queryErr := enabledUser(ctx, transaction.Tx, opponentID); queryErr != nil {
		if errors.Is(queryErr, sql.ErrNoRows) {
			return Match{}, ErrInvalidRequest
		}
		return Match{}, matchDatabaseError(ctx, queryErr)
	} else if !enabled {
		return Match{}, ErrInvalidRequest
	}

	initiatorColor, opponentColor, colorErr := service.randomColors()
	if colorErr != nil {
		return Match{}, ErrInternal
	}
	matchID, idErr := uuid.NewRandom()
	if idErr != nil {
		return Match{}, ErrInternal
	}
	nowMillis := service.clock.Now().UTC().UnixMilli()
	matchIDText := matchID.String()
	result, insertErr := transaction.ExecContext(ctx, `
INSERT INTO matches(id,game_id,status,revision,game_config_json,created_at,updated_at)
VALUES (?,?,?,0,?,?,?)`, matchIDText, gameID, StatusActive, nullableJSON(normalizedConfig), nowMillis, nowMillis)
	if insertErr != nil {
		return Match{}, matchDatabaseError(ctx, insertErr)
	}
	if affectedExactlyOne(result) != nil {
		return Match{}, ErrInternal
	}

	players := []Player{
		{UserID: initiatorID, Seat: 0, Color: initiatorColor},
		{UserID: opponentID, Seat: 1, Color: opponentColor},
	}
	for _, player := range players {
		result, insertErr = transaction.ExecContext(ctx, `
INSERT INTO match_players(match_id,user_id,seat,color)
VALUES (?,?,?,?)`, matchIDText, player.UserID, player.Seat, player.Color)
		if insertErr != nil {
			return Match{}, matchDatabaseError(ctx, insertErr)
		}
		if affectedExactlyOne(result) != nil {
			return Match{}, ErrInternal
		}
	}

	if singleActiveMatch(rules) {
		for index, player := range players {
			result, insertErr = transaction.ExecContext(ctx, `
INSERT INTO active_game_slots(game_id,user_id,match_id)
VALUES (?,?,?)`, gameID, player.UserID, matchIDText)
			if insertErr != nil {
				if isActiveSlotConflict(insertErr) {
					if index == 0 {
						return Match{}, ErrActiveMatchExists
					}
					return Match{}, ErrOpponentBusy
				}
				return Match{}, matchDatabaseError(ctx, insertErr)
			}
			if affectedExactlyOne(result) != nil {
				return Match{}, ErrInternal
			}
		}
	}
	if commitErr := transaction.Commit(); commitErr != nil {
		return Match{}, matchDatabaseError(ctx, commitErr)
	}
	timestamp := time.UnixMilli(nowMillis).UTC()
	return Match{
		ID:         matchIDText,
		GameID:     gameID,
		Status:     StatusActive,
		Revision:   0,
		GameConfig: append(json.RawMessage(nil), normalizedConfig...),
		CreatedAt:  timestamp,
		UpdatedAt:  timestamp,
	}, nil
}

// Cancel transitions an active, zero-move match to cancelled. It returns only
// after the event, match update, and slot release have all committed.
func (service *Service) Cancel(ctx context.Context, matchID, actorUserID string) (_ Event, err error) {
	if !service.configured() {
		return Event{}, ErrInvalidConfiguration
	}
	if ctx == nil || !validIdentifier(matchID) || !validIdentifier(actorUserID) {
		return Event{}, ErrInvalidRequest
	}
	transaction, beginErr := service.beginWriteTransaction(ctx)
	if beginErr != nil {
		return Event{}, beginErr
	}
	defer func() {
		if rollbackErr := transaction.Rollback(); rollbackErr != nil && !errors.Is(rollbackErr, sql.ErrTxDone) && err == nil {
			err = matchDatabaseError(ctx, rollbackErr)
		}
		_ = transaction.release()
	}()

	var gameID, status string
	var revision int64
	queryErr := transaction.QueryRowContext(ctx, `
SELECT game_id,status,revision
FROM matches
WHERE id=?`, matchID).Scan(&gameID, &status, &revision)
	if errors.Is(queryErr, sql.ErrNoRows) {
		return Event{}, ErrMatchNotFound
	}
	if queryErr != nil {
		return Event{}, matchDatabaseError(ctx, queryErr)
	}
	playerIDs, playersErr := readTwoMatchPlayers(ctx, transaction.Tx, matchID)
	if playersErr != nil {
		return Event{}, playersErr
	}
	if actorUserID != playerIDs[0] && actorUserID != playerIDs[1] {
		return Event{}, ErrMatchNotCancellable
	}
	if status != StatusActive {
		return Event{}, ErrMatchNotCancellable
	}

	var gameplayEvents int
	if queryErr := transaction.QueryRowContext(ctx, `
SELECT EXISTS(
  SELECT 1 FROM match_events
  WHERE match_id=? AND event_type IN (?,?,?,?)
)`, matchID, chinesecheckers.MoveAccepted, gomoku.MoveAccepted, rps.ChoiceLocked, rps.RoundRevealed).Scan(&gameplayEvents); queryErr != nil {
		return Event{}, matchDatabaseError(ctx, queryErr)
	}
	if gameplayEvents != 0 {
		return Event{}, ErrMatchNotCancellable
	}

	rules, ok := service.games.Lookup(gameID)
	if !ok || rules.PlayerLimit() != 2 {
		return Event{}, ErrInternal
	}
	if slotsErr := validateCompleteActiveSlotSet(ctx, transaction.Tx, gameID, matchID, playerIDs, singleActiveMatch(rules)); slotsErr != nil {
		return Event{}, slotsErr
	}
	nextRevision := revision + 1
	if nextRevision <= 0 {
		return Event{}, ErrInternal
	}
	nowMillis := service.clock.Now().UTC().UnixMilli()
	result, insertErr := transaction.ExecContext(ctx, `
INSERT INTO match_events(match_id,revision,event_type,action_id,actor_user_id,payload_json,created_at)
VALUES (?,?,?,NULL,?,?,?)`, matchID, nextRevision, protocol.TypePlatformMatchCancelled, actorUserID, cancelledPayloadJSON, nowMillis)
	if insertErr != nil {
		return Event{}, matchDatabaseError(ctx, insertErr)
	}
	if affectedExactlyOne(result) != nil {
		return Event{}, ErrInternal
	}

	result, updateErr := transaction.ExecContext(ctx, `
UPDATE matches
SET status=?, revision=?, updated_at=?, finished_at=?, winner_user_id=NULL, result=NULL
WHERE id=? AND status=? AND revision=?`, StatusCancelled, nextRevision, nowMillis, nowMillis, matchID, StatusActive, revision)
	if updateErr != nil {
		return Event{}, matchDatabaseError(ctx, updateErr)
	}
	if affectedExactlyOne(result) != nil {
		return Event{}, ErrInternal
	}

	result, deleteErr := transaction.ExecContext(ctx, `
DELETE FROM active_game_slots
WHERE game_id=? AND match_id=? AND user_id IN (?,?)`, gameID, matchID, playerIDs[0], playerIDs[1])
	if deleteErr != nil {
		return Event{}, matchDatabaseError(ctx, deleteErr)
	}
	deleted, rowsErr := result.RowsAffected()
	if rowsErr != nil {
		return Event{}, matchDatabaseError(ctx, rowsErr)
	}
	wantDeleted := int64(0)
	if singleActiveMatch(rules) {
		wantDeleted = 2
	}
	if deleted != wantDeleted {
		return Event{}, ErrInternal
	}
	if deleteErr := deleteMatchCredentials(ctx, transaction.Tx, matchID); deleteErr != nil {
		return Event{}, deleteErr
	}
	if commitErr := transaction.Commit(); commitErr != nil {
		return Event{}, matchDatabaseError(ctx, commitErr)
	}
	actorCopy := actorUserID
	timestamp := time.UnixMilli(nowMillis).UTC()
	return Event{
		MatchID:     matchID,
		Revision:    nextRevision,
		Type:        protocol.TypePlatformMatchCancelled,
		ActorUserID: &actorCopy,
		Payload:     append([]byte(nil), cancelledPayloadJSON...),
		CreatedAt:   timestamp,
	}, nil
}

// Snapshot returns a consistent match view rebuilt from the durable event
// stream. It never treats the matches row as a second copy of game state.
func (service *Service) Snapshot(ctx context.Context, matchID string) (_ Snapshot, err error) {
	if !service.configured() {
		return Snapshot{}, ErrInvalidConfiguration
	}
	if ctx == nil || !validIdentifier(matchID) {
		return Snapshot{}, ErrInvalidRequest
	}
	transaction, beginErr := service.db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if beginErr != nil {
		return Snapshot{}, matchDatabaseError(ctx, beginErr)
	}
	defer func() {
		if rollbackErr := transaction.Rollback(); rollbackErr != nil && !errors.Is(rollbackErr, sql.ErrTxDone) && err == nil {
			err = matchDatabaseError(ctx, rollbackErr)
		}
	}()
	match, players, loadErr := loadMatchAndPlayers(ctx, transaction, matchID)
	if loadErr != nil {
		return Snapshot{}, loadErr
	}
	snapshot, snapshotErr := service.rebuildSnapshot(ctx, transaction, match, players)
	if snapshotErr != nil {
		return Snapshot{}, snapshotErr
	}
	if commitErr := transaction.Commit(); commitErr != nil {
		return Snapshot{}, matchDatabaseError(ctx, commitErr)
	}
	return cloneMatchSnapshot(snapshot), nil
}

// ApplyAction validates, persists, and commits one authoritative action. A
// non-zero Event is returned only after all event/lifecycle/slot writes commit.
func (service *Service) ApplyAction(ctx context.Context, request ActionRequest) (_ Event, _ Snapshot, err error) {
	if !service.configured() {
		return Event{}, Snapshot{}, ErrInvalidConfiguration
	}
	semantics, validationErr := validateActionRequest(ctx, request)
	if validationErr != nil {
		return Event{}, Snapshot{}, validationErr
	}
	transaction, beginErr := service.beginWriteTransaction(ctx)
	if beginErr != nil {
		return Event{}, Snapshot{}, beginErr
	}
	defer func() {
		if rollbackErr := transaction.Rollback(); rollbackErr != nil && !errors.Is(rollbackErr, sql.ErrTxDone) && err == nil {
			err = matchDatabaseError(ctx, rollbackErr)
		}
		_ = transaction.release()
	}()

	match, players, loadErr := loadMatchAndPlayers(ctx, transaction.Tx, request.MatchID)
	if loadErr != nil {
		return Event{}, Snapshot{}, loadErr
	}
	template, ok := service.games.Lookup(match.GameID)
	if !ok || template.PlayerLimit() != 2 {
		return Event{}, Snapshot{}, ErrInternal
	}
	rules, rulesErr := rulesForMatch(template, match.GameConfig)
	if rulesErr != nil {
		return Event{}, Snapshot{}, rulesErr
	}

	committed, found, lookupErr := readActionEvent(ctx, transaction.Tx, request.MatchID, request.ActorUserID, request.ActionID)
	if lookupErr != nil {
		return Event{}, Snapshot{}, lookupErr
	}
	if found {
		matches, comparisonErr := committedActionMatches(committed, request, semantics, players)
		if comparisonErr != nil {
			return Event{}, Snapshot{}, comparisonErr
		}
		if !matches {
			return Event{}, Snapshot{}, ErrActionConflict
		}
		snapshot, snapshotErr := service.rebuildSnapshot(ctx, transaction.Tx, match, players)
		if snapshotErr != nil {
			return Event{}, Snapshot{}, snapshotErr
		}
		if commitErr := transaction.Commit(); commitErr != nil {
			return Event{}, Snapshot{}, matchDatabaseError(ctx, commitErr)
		}
		return cloneEvent(committed), cloneMatchSnapshot(snapshot), nil
	}

	if match.Status != StatusActive {
		return Event{}, Snapshot{}, ErrInvalidRequest
	}
	actor, opponent, member := actionPlayers(players, request.ActorUserID)
	if !member {
		return Event{}, Snapshot{}, ErrInvalidRequest
	}
	if request.ExpectedRevision != match.Revision {
		acceptedPrevious, previousErr := acceptsPreviousRpsChoiceRevision(ctx, transaction.Tx, match, request)
		if previousErr != nil {
			return Event{}, Snapshot{}, previousErr
		}
		if !acceptedPrevious {
			return Event{}, Snapshot{}, ErrStaleRevision
		}
	}
	current, snapshotErr := service.rebuildSnapshot(ctx, transaction.Tx, match, players)
	if snapshotErr != nil {
		return Event{}, Snapshot{}, snapshotErr
	}
	if match.Revision == int64(^uint64(0)>>1) {
		return Event{}, Snapshot{}, ErrInternal
	}
	nextRevision := match.Revision + 1
	nowMillis := service.clock.Now().UTC().UnixMilli()
	now := time.UnixMilli(nowMillis).UTC()

	var gameEvent games.Event
	var nextGame games.Snapshot
	var result, winner *string
	terminal := false
	switch request.Type {
	case chinesecheckers.MoveRequested:
		// Keep one durable event available for resignation. Chinese Checkers
		// positions can cycle, so unlike Gomoku the board does not bound the
		// number of accepted moves before the shared history limit.
		if match.Revision >= maximumMatchEvents-1 {
			return Event{}, Snapshot{}, ErrInvalidRequest
		}
		acceptedMoves := current.Game.Revision
		expectedColor := ColorBlack
		if acceptedMoves%2 == 1 {
			expectedColor = ColorWhite
		}
		if actor.Color != expectedColor {
			return Event{}, Snapshot{}, chinesecheckers.ErrNotYourTurn
		}
		produced, producedSnapshot, applyErr := rules.Apply(current.Game, request.ActorUserID, games.Action{
			Type: request.Type, Payload: append(json.RawMessage(nil), request.Payload...),
		})
		if applyErr != nil {
			return Event{}, Snapshot{}, safeActionRuleError(applyErr)
		}
		if validateErr := validateProducedChineseCheckersMove(produced, producedSnapshot, request, semantics, actor.Color, nextRevision); validateErr != nil {
			return Event{}, Snapshot{}, validateErr
		}
		gameEvent, nextGame = produced, producedSnapshot
		outcome, outcomeErr := readGameStateSummary(nextGame)
		if outcomeErr != nil {
			return Event{}, Snapshot{}, ErrInternal
		}
		if outcome.Status == StatusFinished {
			if outcome.Result == nil || *outcome.Result != ResultGoal || outcome.WinnerUserID == nil || *outcome.WinnerUserID != request.ActorUserID {
				return Event{}, Snapshot{}, ErrInternal
			}
			terminal = true
			result = cloneStringPointer(outcome.Result)
			winner = cloneStringPointer(outcome.WinnerUserID)
		}
	case flightchess.RollRequested, flightchess.MoveRequested:
		if match.Revision >= int64(maximumMatchEventsFor(match.GameID)-1) {
			return Event{}, Snapshot{}, ErrInvalidRequest
		}
		currentSummary, summaryErr := readGameStateSummary(current.Game)
		if summaryErr != nil {
			return Event{}, Snapshot{}, ErrInternal
		}
		if string(actor.Color) != currentSummary.NextColor {
			return Event{}, Snapshot{}, flightchess.ErrNotYourTurn
		}
		action := games.Action{Type: request.Type, Payload: append(json.RawMessage(nil), request.Payload...)}
		var produced games.Event
		var producedSnapshot games.Snapshot
		var applyErr error
		if request.Type == flightchess.RollRequested {
			randomized, ok := rules.(games.RandomizedRules)
			if !ok {
				return Event{}, Snapshot{}, ErrInternal
			}
			service.randomMu.Lock()
			produced, producedSnapshot, applyErr = randomized.ApplyRandom(current.Game, request.ActorUserID, action, service.random)
			service.randomMu.Unlock()
		} else {
			produced, producedSnapshot, applyErr = rules.Apply(current.Game, request.ActorUserID, action)
		}
		if applyErr != nil {
			return Event{}, Snapshot{}, safeActionRuleError(applyErr)
		}
		if validateErr := validateProducedFlightChess(produced, producedSnapshot, request, semantics, actor.Color, nextRevision); validateErr != nil {
			return Event{}, Snapshot{}, validateErr
		}
		gameEvent, nextGame = produced, producedSnapshot
		outcome, outcomeErr := readGameStateSummary(nextGame)
		if outcomeErr != nil {
			return Event{}, Snapshot{}, ErrInternal
		}
		if outcome.Status == StatusFinished {
			if request.Type != flightchess.MoveRequested || outcome.Result == nil || *outcome.Result != ResultGoal || outcome.WinnerUserID == nil || *outcome.WinnerUserID != request.ActorUserID {
				return Event{}, Snapshot{}, ErrInternal
			}
			terminal = true
			result = cloneStringPointer(outcome.Result)
			winner = cloneStringPointer(outcome.WinnerUserID)
		}
	case gomoku.MoveRequested:
		acceptedMoves := current.Game.Revision
		expectedColor := ColorBlack
		if acceptedMoves%2 == 1 {
			expectedColor = ColorWhite
		}
		if actor.Color != expectedColor {
			return Event{}, Snapshot{}, gomoku.ErrNotYourTurn
		}
		produced, producedSnapshot, applyErr := rules.Apply(current.Game, request.ActorUserID, games.Action{
			Type: request.Type, Payload: append(json.RawMessage(nil), request.Payload...),
		})
		if applyErr != nil {
			return Event{}, Snapshot{}, safeActionRuleError(applyErr)
		}
		if validateErr := validateProducedMove(produced, producedSnapshot, request, semantics, actor.Color, nextRevision); validateErr != nil {
			return Event{}, Snapshot{}, validateErr
		}
		gameEvent, nextGame = produced, producedSnapshot
		outcome, outcomeErr := readGameStateSummary(nextGame)
		if outcomeErr != nil {
			return Event{}, Snapshot{}, ErrInternal
		}
		if outcome.Status == StatusFinished {
			if outcome.Result == nil || (*outcome.Result != ResultFive && *outcome.Result != ResultDraw) {
				return Event{}, Snapshot{}, ErrInternal
			}
			terminal = true
			result = cloneStringPointer(outcome.Result)
			winner = cloneStringPointer(outcome.WinnerUserID)
			if *result == ResultDraw && winner != nil || *result == ResultFive && (winner == nil || *winner != request.ActorUserID) {
				return Event{}, Snapshot{}, ErrInternal
			}
		}
	case rps.ChoiceRequested:
		if match.Revision >= maximumMatchEvents-2 {
			return Event{}, Snapshot{}, ErrInvalidRequest
		}
		produced, producedSnapshot, applyErr := rules.Apply(current.Game, request.ActorUserID, games.Action{
			Type: request.Type, Payload: append(json.RawMessage(nil), request.Payload...),
		})
		if applyErr != nil {
			return Event{}, Snapshot{}, safeActionRuleError(applyErr)
		}
		if validateErr := validateProducedChoice(produced, producedSnapshot, request, semantics, nextRevision); validateErr != nil {
			return Event{}, Snapshot{}, validateErr
		}
		gameEvent, nextGame = produced, producedSnapshot
		outcome, outcomeErr := readGameStateSummary(nextGame)
		if outcomeErr != nil {
			return Event{}, Snapshot{}, ErrInternal
		}
		if outcome.Status == StatusFinished {
			if outcome.Result == nil || *outcome.Result != ResultRounds || outcome.WinnerUserID == nil || !playerMember(players, *outcome.WinnerUserID) {
				return Event{}, Snapshot{}, ErrInternal
			}
			terminal = true
			result = cloneStringPointer(outcome.Result)
			winner = cloneStringPointer(outcome.WinnerUserID)
		}
	case protocol.TypeGomokuResignRequested:
		if current.Game.Revision == 0 {
			return Event{}, Snapshot{}, ErrInvalidRequest
		}
		winnerID := opponent.UserID
		payload, marshalErr := json.Marshal(resignedPayload{UserID: actor.UserID, WinnerUserID: winnerID})
		if marshalErr != nil {
			return Event{}, Snapshot{}, ErrInternal
		}
		gameEvent = games.Event{
			Revision: nextRevision,
			Type:     protocol.TypeGomokuResigned,
			ActorID:  actor.UserID,
			Payload:  append(json.RawMessage(nil), payload...),
		}
		nextGame = cloneGameSnapshot(current.Game)
		resultValue := ResultResignation
		result = &resultValue
		winner = &winnerID
		terminal = true
	case protocol.TypeChineseCheckersResignRequested:
		if current.Game.Revision == 0 {
			return Event{}, Snapshot{}, ErrInvalidRequest
		}
		winnerID := opponent.UserID
		payload, marshalErr := json.Marshal(resignedPayload{UserID: actor.UserID, WinnerUserID: winnerID})
		if marshalErr != nil {
			return Event{}, Snapshot{}, ErrInternal
		}
		gameEvent = games.Event{
			Revision: nextRevision,
			Type:     protocol.TypeChineseCheckersResigned,
			ActorID:  actor.UserID,
			Payload:  append(json.RawMessage(nil), payload...),
		}
		nextGame = cloneGameSnapshot(current.Game)
		resultValue := ResultResignation
		result = &resultValue
		winner = &winnerID
		terminal = true
	case protocol.TypeFlightChessResignRequested:
		if current.Game.Revision == 0 {
			return Event{}, Snapshot{}, ErrInvalidRequest
		}
		winnerID := opponent.UserID
		payload, marshalErr := json.Marshal(resignedPayload{UserID: actor.UserID, WinnerUserID: winnerID})
		if marshalErr != nil {
			return Event{}, Snapshot{}, ErrInternal
		}
		gameEvent = games.Event{
			Revision: nextRevision,
			Type:     protocol.TypeFlightChessResigned,
			ActorID:  actor.UserID,
			Payload:  append(json.RawMessage(nil), payload...),
		}
		nextGame = cloneGameSnapshot(current.Game)
		resultValue := ResultResignation
		result = &resultValue
		winner = &winnerID
		terminal = true
	case protocol.TypeRpsResignRequested:
		if current.Game.Revision == 0 {
			return Event{}, Snapshot{}, ErrInvalidRequest
		}
		winnerID := opponent.UserID
		payload, marshalErr := json.Marshal(resignedPayload{UserID: actor.UserID, WinnerUserID: winnerID})
		if marshalErr != nil {
			return Event{}, Snapshot{}, ErrInternal
		}
		gameEvent = games.Event{
			Revision: nextRevision, Type: protocol.TypeRpsResigned, ActorID: actor.UserID,
			Payload: append(json.RawMessage(nil), payload...),
		}
		nextGame = cloneGameSnapshot(current.Game)
		resultValue := ResultResignation
		result = &resultValue
		winner = &winnerID
		terminal = true
	default:
		return Event{}, Snapshot{}, ErrInvalidRequest
	}

	playerIDs := [2]string{players[0].UserID, players[1].UserID}
	if terminal {
		if slotsErr := validateCompleteActiveSlotSet(ctx, transaction.Tx, match.GameID, match.ID, playerIDs, singleActiveMatch(rules)); slotsErr != nil {
			return Event{}, Snapshot{}, slotsErr
		}
	}
	resultExec, insertErr := transaction.ExecContext(ctx, `
INSERT INTO match_events(match_id,revision,event_type,action_id,actor_user_id,payload_json,created_at)
VALUES (?,?,?,?,?,?,?)`, match.ID, nextRevision, gameEvent.Type, request.ActionID, request.ActorUserID, string(gameEvent.Payload), nowMillis)
	if insertErr != nil {
		return Event{}, Snapshot{}, matchDatabaseError(ctx, insertErr)
	}
	if affectedExactlyOne(resultExec) != nil {
		return Event{}, Snapshot{}, ErrInternal
	}

	if terminal {
		resultExec, updateErr := transaction.ExecContext(ctx, `
UPDATE matches
SET status=?,revision=?,updated_at=?,finished_at=?,result=?,winner_user_id=?,both_offline_since=NULL
WHERE id=? AND status=? AND revision=?`, StatusFinished, nextRevision, nowMillis, nowMillis, valueOrNil(result), valueOrNil(winner), match.ID, StatusActive, match.Revision)
		if updateErr != nil {
			return Event{}, Snapshot{}, matchDatabaseError(ctx, updateErr)
		}
		if affectedExactlyOne(resultExec) != nil {
			return Event{}, Snapshot{}, ErrInternal
		}
		resultExec, deleteErr := transaction.ExecContext(ctx, `
DELETE FROM active_game_slots
WHERE game_id=? AND match_id=? AND user_id IN (?,?)`, match.GameID, match.ID, players[0].UserID, players[1].UserID)
		if deleteErr != nil {
			return Event{}, Snapshot{}, matchDatabaseError(ctx, deleteErr)
		}
		deleted, rowsErr := resultExec.RowsAffected()
		if rowsErr != nil {
			return Event{}, Snapshot{}, matchDatabaseError(ctx, rowsErr)
		}
		wantDeleted := int64(0)
		if singleActiveMatch(rules) {
			wantDeleted = 2
		}
		if deleted != wantDeleted {
			return Event{}, Snapshot{}, ErrInternal
		}
		if deleteErr := deleteMatchCredentials(ctx, transaction.Tx, match.ID); deleteErr != nil {
			return Event{}, Snapshot{}, deleteErr
		}
	} else {
		resultExec, updateErr := transaction.ExecContext(ctx, `
UPDATE matches
SET revision=?,updated_at=?
WHERE id=? AND status=? AND revision=?`, nextRevision, nowMillis, match.ID, StatusActive, match.Revision)
		if updateErr != nil {
			return Event{}, Snapshot{}, matchDatabaseError(ctx, updateErr)
		}
		if affectedExactlyOne(resultExec) != nil {
			return Event{}, Snapshot{}, ErrInternal
		}
	}
	if commitErr := transaction.Commit(); commitErr != nil {
		return Event{}, Snapshot{}, matchDatabaseError(ctx, commitErr)
	}

	actionID, actorID := request.ActionID, request.ActorUserID
	committedEvent := Event{
		MatchID: match.ID, Revision: nextRevision, Type: gameEvent.Type,
		ActionID: &actionID, ActorUserID: &actorID,
		Payload: append(json.RawMessage(nil), gameEvent.Payload...), CreatedAt: now,
	}
	match.Revision = nextRevision
	match.UpdatedAt = now
	match.Result = cloneStringPointer(result)
	match.WinnerUserID = cloneStringPointer(winner)
	if terminal {
		match.Status = StatusFinished
		match.FinishedAt = &now
	}
	return committedEvent, cloneMatchSnapshot(Snapshot{Match: match, Players: players, Game: nextGame}), nil
}

func acceptsPreviousRpsChoiceRevision(ctx context.Context, transaction *sql.Tx, match Match, request ActionRequest) (bool, error) {
	if match.GameID != rps.GameID || request.Type != rps.ChoiceRequested || match.Revision <= 0 ||
		request.ExpectedRevision != match.Revision-1 {
		return false, nil
	}
	var eventType, actorUserID string
	err := transaction.QueryRowContext(ctx, `
SELECT event_type,actor_user_id
FROM match_events
WHERE match_id=? AND revision=?`, match.ID, match.Revision).Scan(&eventType, &actorUserID)
	if err != nil {
		return false, matchDatabaseError(ctx, err)
	}
	return eventType == rps.ChoiceLocked && actorUserID != request.ActorUserID, nil
}

// SetPlayerOnline clears an active match's fully-offline timer. Inactive
// matches are deliberately left untouched so a late transport close/open
// cannot rewrite terminal lifecycle data.
func (service *Service) SetPlayerOnline(ctx context.Context, matchID, userID string) error {
	return service.setPlayerPresence(ctx, matchID, userID, true)
}

// SetPlayerOffline starts the fully-offline timer once. Presence calls this
// only after its in-memory connection set confirms neither player is online.
func (service *Service) SetPlayerOffline(ctx context.Context, matchID, userID string) error {
	return service.setPlayerPresence(ctx, matchID, userID, false)
}

func (service *Service) setPlayerPresence(ctx context.Context, matchID, userID string, online bool) (err error) {
	if !service.configured() {
		return ErrInvalidConfiguration
	}
	if ctx == nil || !canonicalUUID(matchID) || !canonicalUUID(userID) {
		return ErrInvalidRequest
	}
	transaction, beginErr := service.beginWriteTransaction(ctx)
	if beginErr != nil {
		return beginErr
	}
	defer func() {
		if rollbackErr := transaction.Rollback(); rollbackErr != nil && !errors.Is(rollbackErr, sql.ErrTxDone) && err == nil {
			err = matchDatabaseError(ctx, rollbackErr)
		}
		_ = transaction.release()
	}()

	match, players, loadErr := loadMatchAndPlayers(ctx, transaction.Tx, matchID)
	if loadErr != nil {
		return loadErr
	}
	if userID != players[0].UserID && userID != players[1].UserID {
		return ErrInvalidRequest
	}
	if match.Status != StatusActive {
		if commitErr := transaction.Commit(); commitErr != nil {
			return matchDatabaseError(ctx, commitErr)
		}
		return nil
	}

	var result sql.Result
	var updateErr error
	if online {
		result, updateErr = transaction.ExecContext(ctx, `
UPDATE matches
SET both_offline_since=NULL
WHERE id=? AND status=?`, matchID, StatusActive)
	} else {
		nowMillis := service.clock.Now().UTC().UnixMilli()
		result, updateErr = transaction.ExecContext(ctx, `
UPDATE matches
SET both_offline_since=COALESCE(both_offline_since,?)
WHERE id=? AND status=?`, nowMillis, matchID, StatusActive)
	}
	if updateErr != nil {
		return matchDatabaseError(ctx, updateErr)
	}
	if affectedExactlyOne(result) != nil {
		return ErrInternal
	}
	if commitErr := transaction.Commit(); commitErr != nil {
		return matchDatabaseError(ctx, commitErr)
	}
	return nil
}

// AbandonExpired commits one platform abandonment event per active match that
// has remained fully offline for at least 24 hours. Returned events are always
// already committed and are therefore safe to publish.
func (service *Service) AbandonExpired(ctx context.Context) ([]Event, error) {
	if !service.configured() {
		return nil, ErrInvalidConfiguration
	}
	if ctx == nil {
		return nil, ErrInvalidRequest
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	nowMillis := service.clock.Now().UTC().UnixMilli()
	cutoffMillis := nowMillis - fullyOfflineAbandonAfter.Milliseconds()
	rows, queryErr := service.db.QueryContext(ctx, `
SELECT id
FROM matches
WHERE status=? AND both_offline_since IS NOT NULL AND both_offline_since<=?
ORDER BY id`, StatusActive, cutoffMillis)
	if queryErr != nil {
		return nil, matchDatabaseError(ctx, queryErr)
	}
	matchIDs := make([]string, 0, 16)
	for rows.Next() {
		var matchID string
		if scanErr := rows.Scan(&matchID); scanErr != nil {
			_ = rows.Close()
			return nil, matchDatabaseError(ctx, scanErr)
		}
		if !canonicalUUID(matchID) {
			_ = rows.Close()
			return nil, ErrInternal
		}
		matchIDs = append(matchIDs, matchID)
	}
	if rowsErr := rows.Err(); rowsErr != nil {
		_ = rows.Close()
		return nil, matchDatabaseError(ctx, rowsErr)
	}
	if closeErr := rows.Close(); closeErr != nil {
		return nil, matchDatabaseError(ctx, closeErr)
	}

	committed := make([]Event, 0, len(matchIDs))
	for _, matchID := range matchIDs {
		event, changed, abandonErr := service.abandonIfExpired(ctx, matchID, cutoffMillis, nowMillis)
		if abandonErr != nil {
			return committed, abandonErr
		}
		if changed {
			committed = append(committed, event)
		}
	}
	return committed, nil
}

func (service *Service) abandonIfExpired(ctx context.Context, matchID string, cutoffMillis, nowMillis int64) (_ Event, changed bool, err error) {
	transaction, beginErr := service.beginWriteTransaction(ctx)
	if beginErr != nil {
		return Event{}, false, beginErr
	}
	defer func() {
		if rollbackErr := transaction.Rollback(); rollbackErr != nil && !errors.Is(rollbackErr, sql.ErrTxDone) && err == nil {
			err = matchDatabaseError(ctx, rollbackErr)
			changed = false
		}
		_ = transaction.release()
	}()

	match, players, loadErr := loadMatchAndPlayers(ctx, transaction.Tx, matchID)
	if loadErr != nil {
		if errors.Is(loadErr, ErrMatchNotFound) {
			if commitErr := transaction.Commit(); commitErr != nil {
				return Event{}, false, matchDatabaseError(ctx, commitErr)
			}
			return Event{}, false, nil
		}
		return Event{}, false, loadErr
	}
	var bothOfflineSince sql.NullInt64
	if queryErr := transaction.QueryRowContext(ctx, `SELECT both_offline_since FROM matches WHERE id=?`, matchID).Scan(&bothOfflineSince); queryErr != nil {
		return Event{}, false, matchDatabaseError(ctx, queryErr)
	}
	if match.Status != StatusActive || !bothOfflineSince.Valid || bothOfflineSince.Int64 > cutoffMillis {
		if commitErr := transaction.Commit(); commitErr != nil {
			return Event{}, false, matchDatabaseError(ctx, commitErr)
		}
		return Event{}, false, nil
	}
	if _, snapshotErr := service.rebuildSnapshot(ctx, transaction.Tx, match, players); snapshotErr != nil {
		return Event{}, false, snapshotErr
	}
	if match.Revision == int64(^uint64(0)>>1) {
		return Event{}, false, ErrInternal
	}
	nextRevision := match.Revision + 1
	rules, ok := service.games.Lookup(match.GameID)
	if !ok || rules.PlayerLimit() != 2 {
		return Event{}, false, ErrInternal
	}

	result, insertErr := transaction.ExecContext(ctx, `
INSERT INTO match_events(match_id,revision,event_type,action_id,actor_user_id,payload_json,created_at)
VALUES (?,?,?,NULL,NULL,?,?)`, match.ID, nextRevision, protocol.TypePlatformMatchAbandoned, cancelledPayloadJSON, nowMillis)
	if insertErr != nil {
		return Event{}, false, matchDatabaseError(ctx, insertErr)
	}
	if affectedExactlyOne(result) != nil {
		return Event{}, false, ErrInternal
	}
	result, updateErr := transaction.ExecContext(ctx, `
UPDATE matches
SET status=?,revision=?,updated_at=?,finished_at=?,winner_user_id=NULL,result=NULL,both_offline_since=NULL
WHERE id=? AND status=? AND revision=? AND both_offline_since IS NOT NULL AND both_offline_since<=?`,
		StatusAbandoned, nextRevision, nowMillis, nowMillis, match.ID, StatusActive, match.Revision, cutoffMillis)
	if updateErr != nil {
		return Event{}, false, matchDatabaseError(ctx, updateErr)
	}
	if affectedExactlyOne(result) != nil {
		return Event{}, false, ErrInternal
	}
	result, deleteErr := transaction.ExecContext(ctx, `
DELETE FROM active_game_slots
WHERE game_id=? AND match_id=? AND user_id IN (?,?)`, match.GameID, match.ID, players[0].UserID, players[1].UserID)
	if deleteErr != nil {
		return Event{}, false, matchDatabaseError(ctx, deleteErr)
	}
	deleted, rowsErr := result.RowsAffected()
	if rowsErr != nil {
		return Event{}, false, matchDatabaseError(ctx, rowsErr)
	}
	wantDeleted := int64(0)
	if singleActiveMatch(rules) {
		wantDeleted = 2
	}
	if deleted != wantDeleted {
		return Event{}, false, ErrInternal
	}
	if deleteErr := deleteMatchCredentials(ctx, transaction.Tx, match.ID); deleteErr != nil {
		return Event{}, false, deleteErr
	}
	if commitErr := transaction.Commit(); commitErr != nil {
		return Event{}, false, matchDatabaseError(ctx, commitErr)
	}
	return Event{
		MatchID: match.ID, Revision: nextRevision, Type: protocol.TypePlatformMatchAbandoned,
		Payload: append(json.RawMessage(nil), cancelledPayloadJSON...), CreatedAt: time.UnixMilli(nowMillis).UTC(),
	}, true, nil
}

func deleteMatchCredentials(ctx context.Context, transaction *sql.Tx, matchID string) error {
	if ctx == nil || transaction == nil || !canonicalUUID(matchID) {
		return ErrInternal
	}
	if _, err := transaction.ExecContext(ctx, `
DELETE FROM launch_tickets
WHERE match_id=?`, matchID); err != nil {
		return matchDatabaseError(ctx, err)
	}
	if _, err := transaction.ExecContext(ctx, `
DELETE FROM resume_tokens
WHERE match_id=?`, matchID); err != nil {
		return matchDatabaseError(ctx, err)
	}
	return nil
}

// MarkActiveMatchesOfflineOnBoot starts a timer only for active matches that
// did not already have one. Existing downtime is preserved across restarts.
func (service *Service) MarkActiveMatchesOfflineOnBoot(ctx context.Context) error {
	if !service.configured() {
		return ErrInvalidConfiguration
	}
	return MarkActiveMatchesOfflineOnBoot(ctx, service.db, service.clock)
}

// MarkActiveMatchesOfflineOnBoot is the narrow process-bootstrap recovery
// boundary. It deliberately needs only the migrated store and clock, allowing
// recovery to finish before runtime auth, rules, Hub, and Router construction.
func MarkActiveMatchesOfflineOnBoot(ctx context.Context, db *sql.DB, serviceClock clock.Clock) (err error) {
	if db == nil || nilDependency(serviceClock) {
		return ErrInvalidConfiguration
	}
	if ctx == nil {
		return ErrInvalidRequest
	}
	bootstrap := &Service{db: db}
	transaction, beginErr := bootstrap.beginWriteTransaction(ctx)
	if beginErr != nil {
		return beginErr
	}
	defer func() {
		if rollbackErr := transaction.Rollback(); rollbackErr != nil && !errors.Is(rollbackErr, sql.ErrTxDone) && err == nil {
			err = matchDatabaseError(ctx, rollbackErr)
		}
		_ = transaction.release()
	}()
	nowMillis := serviceClock.Now().UTC().UnixMilli()
	if _, updateErr := transaction.ExecContext(ctx, `
UPDATE matches
SET both_offline_since=?
WHERE status=? AND both_offline_since IS NULL`, nowMillis, StatusActive); updateErr != nil {
		return matchDatabaseError(ctx, updateErr)
	}
	if commitErr := transaction.Commit(); commitErr != nil {
		return matchDatabaseError(ctx, commitErr)
	}
	return nil
}

type actionSemantics struct {
	x          int
	y          int
	pieceIndex int
	choice     string
	path       []int
}

type resignedPayload struct {
	UserID       string `json:"userId"`
	WinnerUserID string `json:"winnerUserId"`
}

type gameStateSummary struct {
	Status       string  `json:"status"`
	BlackUserID  *string `json:"blackUserId"`
	WhiteUserID  *string `json:"whiteUserId"`
	NextColor    string  `json:"nextColor"`
	WinnerUserID *string `json:"winnerUserId"`
	Result       *string `json:"result"`
}

func validateActionRequest(ctx context.Context, request ActionRequest) (actionSemantics, error) {
	if ctx == nil || !validIdentifier(request.MatchID) || !validIdentifier(request.ActorUserID) || !canonicalUUID(request.ActionID) || request.ExpectedRevision < 0 {
		return actionSemantics{}, ErrInvalidRequest
	}
	switch request.Type {
	case chinesecheckers.MoveRequested:
		path, err := decodeChineseCheckersMoveRequest(request.Payload)
		if err != nil {
			return actionSemantics{}, ErrInvalidRequest
		}
		return actionSemantics{path: path}, nil
	case protocol.TypeChineseCheckersResignRequested:
		fields, err := strictJSONObject(request.Payload, map[string]struct{}{})
		if err != nil || len(fields) != 0 {
			return actionSemantics{}, ErrInvalidRequest
		}
		return actionSemantics{}, nil
	case flightchess.RollRequested, protocol.TypeFlightChessResignRequested:
		fields, err := strictJSONObject(request.Payload, map[string]struct{}{})
		if err != nil || len(fields) != 0 {
			return actionSemantics{}, ErrInvalidRequest
		}
		return actionSemantics{}, nil
	case flightchess.MoveRequested:
		fields, err := strictJSONObject(request.Payload, map[string]struct{}{"pieceIndex": {}})
		if err != nil || len(fields) != 1 {
			return actionSemantics{}, ErrInvalidRequest
		}
		pieceIndex, err := strictJSONInteger(fields["pieceIndex"])
		if err != nil || pieceIndex < 0 || pieceIndex >= flightchess.PieceCount {
			return actionSemantics{}, ErrInvalidRequest
		}
		return actionSemantics{pieceIndex: pieceIndex}, nil
	case gomoku.MoveRequested:
		x, y, err := decodeMoveRequest(request.Payload)
		if err != nil {
			return actionSemantics{}, ErrInvalidRequest
		}
		return actionSemantics{x: x, y: y}, nil
	case protocol.TypeGomokuResignRequested:
		fields, err := strictJSONObject(request.Payload, map[string]struct{}{})
		if err != nil || len(fields) != 0 {
			return actionSemantics{}, ErrInvalidRequest
		}
		return actionSemantics{}, nil
	case rps.ChoiceRequested:
		fields, err := strictJSONObject(request.Payload, map[string]struct{}{"choice": {}})
		if err != nil || len(fields) != 1 {
			return actionSemantics{}, ErrInvalidRequest
		}
		var choice string
		if json.Unmarshal(fields["choice"], &choice) != nil || (choice != rps.Rock && choice != rps.Paper && choice != rps.Scissors) {
			return actionSemantics{}, ErrInvalidRequest
		}
		return actionSemantics{choice: choice}, nil
	case protocol.TypeRpsResignRequested:
		fields, err := strictJSONObject(request.Payload, map[string]struct{}{})
		if err != nil || len(fields) != 0 {
			return actionSemantics{}, ErrInvalidRequest
		}
		return actionSemantics{}, nil
	default:
		return actionSemantics{}, ErrInvalidRequest
	}
}

func canonicalUUID(value string) bool {
	parsed, err := uuid.Parse(value)
	return err == nil && parsed.String() == value && parsed.Variant() == uuid.RFC4122
}

func decodeMoveRequest(payload json.RawMessage) (int, int, error) {
	fields, err := strictJSONObject(payload, map[string]struct{}{"x": {}, "y": {}})
	if err != nil || len(fields) != 2 {
		return 0, 0, ErrInvalidRequest
	}
	x, err := strictJSONInteger(fields["x"])
	if err != nil {
		return 0, 0, ErrInvalidRequest
	}
	y, err := strictJSONInteger(fields["y"])
	if err != nil {
		return 0, 0, ErrInvalidRequest
	}
	return x, y, nil
}

func decodeChineseCheckersMoveRequest(payload json.RawMessage) ([]int, error) {
	fields, err := strictJSONObject(payload, map[string]struct{}{"path": {}})
	if err != nil || len(fields) != 1 {
		return nil, ErrInvalidRequest
	}
	return decodeChineseCheckersPath(fields["path"])
}

func decodeChineseCheckersPath(raw json.RawMessage) ([]int, error) {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	opening, err := decoder.Token()
	if err != nil || opening != json.Delim('[') {
		return nil, ErrInvalidRequest
	}
	path := make([]int, 0, 8)
	seen := make(map[int]struct{}, 8)
	for decoder.More() {
		if len(path) >= chinesecheckers.BoardCells {
			return nil, ErrInvalidRequest
		}
		var raw json.RawMessage
		if err := decoder.Decode(&raw); err != nil {
			return nil, ErrInvalidRequest
		}
		value, err := strictJSONInteger(raw)
		if err != nil || value < 0 || value >= chinesecheckers.BoardCells {
			return nil, ErrInvalidRequest
		}
		if _, duplicate := seen[value]; duplicate {
			return nil, ErrInvalidRequest
		}
		seen[value] = struct{}{}
		path = append(path, value)
	}
	if closing, err := decoder.Token(); err != nil || closing != json.Delim(']') || len(path) < 2 {
		return nil, ErrInvalidRequest
	}
	if _, err := decoder.Token(); !errors.Is(err, io.EOF) {
		return nil, ErrInvalidRequest
	}
	return path, nil
}

func strictJSONObject(payload json.RawMessage, allowed map[string]struct{}) (map[string]json.RawMessage, error) {
	if len(payload) == 0 || len(payload) > maximumActionPayloadBytes || !utf8.Valid(payload) {
		return nil, ErrInvalidRequest
	}
	decoder := json.NewDecoder(bytes.NewReader(payload))
	token, err := decoder.Token()
	if err != nil || token != json.Delim('{') {
		return nil, ErrInvalidRequest
	}
	fields := make(map[string]json.RawMessage, len(allowed))
	for decoder.More() {
		token, err := decoder.Token()
		if err != nil {
			return nil, ErrInvalidRequest
		}
		key, ok := token.(string)
		if !ok {
			return nil, ErrInvalidRequest
		}
		if _, permitted := allowed[key]; !permitted {
			return nil, ErrInvalidRequest
		}
		if _, duplicate := fields[key]; duplicate {
			return nil, ErrInvalidRequest
		}
		var raw json.RawMessage
		if err := decoder.Decode(&raw); err != nil {
			return nil, ErrInvalidRequest
		}
		fields[key] = append(json.RawMessage(nil), raw...)
	}
	if token, err = decoder.Token(); err != nil || token != json.Delim('}') {
		return nil, ErrInvalidRequest
	}
	if _, err = decoder.Token(); !errors.Is(err, io.EOF) {
		return nil, ErrInvalidRequest
	}
	return fields, nil
}

func strictJSONInteger(raw json.RawMessage) (int, error) {
	if len(raw) == 0 || len(raw) > 32 {
		return 0, ErrInvalidRequest
	}
	for index, character := range raw {
		if character == '-' && index == 0 {
			continue
		}
		if character < '0' || character > '9' {
			return 0, ErrInvalidRequest
		}
	}
	if raw[0] == '-' && len(raw) == 1 || len(raw) > 1 && raw[0] == '0' || len(raw) > 2 && raw[0] == '-' && raw[1] == '0' {
		return 0, ErrInvalidRequest
	}
	value, err := strconv.ParseInt(string(raw), 10, 0)
	if err != nil {
		return 0, ErrInvalidRequest
	}
	return int(value), nil
}

func loadMatchAndPlayers(ctx context.Context, transaction *sql.Tx, matchID string) (Match, []Player, error) {
	var match Match
	var result, winner, gameConfig sql.NullString
	var createdAt, updatedAt int64
	var finishedAt sql.NullInt64
	err := transaction.QueryRowContext(ctx, `
SELECT game_id,status,revision,result,winner_user_id,game_config_json,created_at,updated_at,finished_at
FROM matches
WHERE id=?`, matchID).Scan(&match.GameID, &match.Status, &match.Revision, &result, &winner, &gameConfig, &createdAt, &updatedAt, &finishedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return Match{}, nil, ErrMatchNotFound
	}
	if err != nil {
		return Match{}, nil, matchDatabaseError(ctx, err)
	}
	match.ID = matchID
	match.CreatedAt = time.UnixMilli(createdAt).UTC()
	match.UpdatedAt = time.UnixMilli(updatedAt).UTC()
	if result.Valid {
		match.Result = stringPointer(result.String)
	}
	if winner.Valid {
		match.WinnerUserID = stringPointer(winner.String)
	}
	if gameConfig.Valid {
		match.GameConfig = append(json.RawMessage(nil), gameConfig.String...)
	}
	if finishedAt.Valid {
		value := time.UnixMilli(finishedAt.Int64).UTC()
		match.FinishedAt = &value
	}
	if !canonicalUUID(match.ID) || match.GameID == "" || match.Revision < 0 || createdAt > updatedAt {
		return Match{}, nil, ErrInternal
	}

	rows, queryErr := transaction.QueryContext(ctx, `
SELECT user_id,seat,color
FROM match_players
WHERE match_id=?
ORDER BY seat`, matchID)
	if queryErr != nil {
		return Match{}, nil, matchDatabaseError(ctx, queryErr)
	}
	defer rows.Close()
	players := make([]Player, 0, 2)
	for rows.Next() {
		var player Player
		if scanErr := rows.Scan(&player.UserID, &player.Seat, &player.Color); scanErr != nil {
			return Match{}, nil, matchDatabaseError(ctx, scanErr)
		}
		players = append(players, player)
	}
	if rowsErr := rows.Err(); rowsErr != nil {
		return Match{}, nil, matchDatabaseError(ctx, rowsErr)
	}
	if len(players) != 2 || players[0].Seat != 0 || players[1].Seat != 1 || players[0].UserID == players[1].UserID ||
		!validIdentifier(players[0].UserID) || !validIdentifier(players[1].UserID) ||
		players[0].Color == players[1].Color ||
		(players[0].Color != ColorBlack && players[0].Color != ColorWhite) ||
		(players[1].Color != ColorBlack && players[1].Color != ColorWhite) {
		return Match{}, nil, ErrInternal
	}
	return match, players, nil
}

func (service *Service) rebuildSnapshot(ctx context.Context, transaction *sql.Tx, match Match, players []Player) (Snapshot, error) {
	template, ok := service.games.Lookup(match.GameID)
	if !ok || template.PlayerLimit() != 2 {
		return Snapshot{}, ErrInternal
	}
	rules, rulesErr := rulesForMatch(template, match.GameConfig)
	if rulesErr != nil {
		return Snapshot{}, rulesErr
	}
	eventLimit := maximumMatchEventsFor(match.GameID)
	events, err := readMatchEvents(ctx, transaction, match.ID, eventLimit)
	if err != nil {
		return Snapshot{}, err
	}
	if match.Revision != int64(len(events)) || len(events) > eventLimit {
		return Snapshot{}, ErrInternal
	}
	if match.GameID == rps.GameID {
		return service.rebuildRpsSnapshot(ctx, transaction, match, players, rules, events)
	}
	if match.GameID == chinesecheckers.GameID {
		return service.rebuildChineseCheckersSnapshot(ctx, transaction, match, players, rules, events)
	}
	if match.GameID == flightchess.GameID {
		return service.rebuildFlightChessSnapshot(ctx, transaction, match, players, rules, events)
	}
	if match.GameID != gomoku.GameID {
		return Snapshot{}, ErrInternal
	}
	black, white, ok := coloredPlayers(players)
	if !ok {
		return Snapshot{}, ErrInternal
	}
	accepted := make([]games.Event, 0, len(events))
	terminalType := ""
	for index, event := range events {
		if event.Revision != int64(index+1) || event.MatchID != match.ID {
			return Snapshot{}, ErrInternal
		}
		switch event.Type {
		case gomoku.MoveAccepted:
			if terminalType != "" || event.ActionID == nil || !canonicalUUID(*event.ActionID) || event.ActorUserID == nil {
				return Snapshot{}, ErrInternal
			}
			move, decodeErr := decodeAcceptedMove(event.Payload)
			if decodeErr != nil || move.userID != *event.ActorUserID {
				return Snapshot{}, ErrInternal
			}
			expected := black
			if len(accepted)%2 == 1 {
				expected = white
			}
			if expected.UserID != *event.ActorUserID || string(expected.Color) != move.color {
				return Snapshot{}, ErrInternal
			}
			accepted = append(accepted, games.Event{
				Revision: event.Revision, Type: event.Type, ActorID: *event.ActorUserID,
				Payload: append(json.RawMessage(nil), event.Payload...),
			})
		case protocol.TypeGomokuResigned:
			if index != len(events)-1 || event.ActionID == nil || !canonicalUUID(*event.ActionID) || event.ActorUserID == nil {
				return Snapshot{}, ErrInternal
			}
			actor, opponent, member := actionPlayers(players, *event.ActorUserID)
			resigned, decodeErr := decodeResignedPayload(event.Payload)
			if !member || decodeErr != nil || resigned.UserID != actor.UserID || resigned.WinnerUserID != opponent.UserID {
				return Snapshot{}, ErrInternal
			}
			terminalType = event.Type
		case protocol.TypePlatformMatchCancelled:
			if index != len(events)-1 || len(accepted) != 0 || event.ActionID != nil || event.ActorUserID == nil || !playerMember(players, *event.ActorUserID) || !isStrictEmptyObject(event.Payload) {
				return Snapshot{}, ErrInternal
			}
			terminalType = event.Type
		case protocol.TypePlatformMatchAbandoned:
			if index != len(events)-1 || event.ActionID != nil || event.ActorUserID != nil || !isStrictEmptyObject(event.Payload) {
				return Snapshot{}, ErrInternal
			}
			terminalType = event.Type
		default:
			return Snapshot{}, ErrInternal
		}
	}
	gameSnapshot, rebuildErr := rules.Rebuild(accepted)
	if rebuildErr != nil || gameSnapshot.Revision != int64(len(accepted)) {
		return Snapshot{}, ErrInternal
	}
	summary, summaryErr := readGameStateSummary(gameSnapshot)
	if summaryErr != nil {
		return Snapshot{}, ErrInternal
	}
	if len(accepted) == 0 {
		if summary.BlackUserID != nil || summary.WhiteUserID != nil || summary.NextColor != string(ColorBlack) {
			return Snapshot{}, ErrInternal
		}
	} else {
		if summary.BlackUserID == nil || *summary.BlackUserID != black.UserID {
			return Snapshot{}, ErrInternal
		}
		if len(accepted) >= 2 {
			if summary.WhiteUserID == nil || *summary.WhiteUserID != white.UserID {
				return Snapshot{}, ErrInternal
			}
		} else if summary.WhiteUserID != nil {
			return Snapshot{}, ErrInternal
		}
		wantNext := string(ColorBlack)
		if len(accepted)%2 == 1 {
			wantNext = string(ColorWhite)
		}
		if summary.NextColor != wantNext {
			return Snapshot{}, ErrInternal
		}
	}
	if lifecycleErr := validateLifecycle(match, summary, terminalType, players, events); lifecycleErr != nil {
		return Snapshot{}, lifecycleErr
	}
	playerIDs := [2]string{players[0].UserID, players[1].UserID}
	expectActiveSlots := match.Status == StatusActive && singleActiveMatch(rules)
	if slotsErr := validateCompleteActiveSlotSet(ctx, transaction, match.GameID, match.ID, playerIDs, expectActiveSlots); slotsErr != nil {
		return Snapshot{}, slotsErr
	}
	return cloneMatchSnapshot(Snapshot{Match: match, Players: players, Game: gameSnapshot}), nil
}

func (service *Service) rebuildFlightChessSnapshot(ctx context.Context, transaction *sql.Tx, match Match, players []Player, rules games.Rules, events []Event) (Snapshot, error) {
	black, white, ok := coloredPlayers(players)
	if !ok {
		return Snapshot{}, ErrInternal
	}
	accepted := make([]games.Event, 0, len(events))
	terminalType := ""
	for index, event := range events {
		if event.Revision != int64(index+1) || event.MatchID != match.ID {
			return Snapshot{}, ErrInternal
		}
		switch event.Type {
		case flightchess.RollAccepted:
			payload, decodeErr := decodeAcceptedFlightChessRoll(event.Payload)
			if terminalType != "" || event.ActionID == nil || !canonicalUUID(*event.ActionID) || event.ActorUserID == nil || decodeErr != nil || payload.UserID != *event.ActorUserID {
				return Snapshot{}, ErrInternal
			}
			actor, _, member := actionPlayers(players, *event.ActorUserID)
			if !member || payload.Color != string(actor.Color) {
				return Snapshot{}, ErrInternal
			}
			accepted = append(accepted, games.Event{Revision: event.Revision, Type: event.Type, ActorID: *event.ActorUserID, Payload: append(json.RawMessage(nil), event.Payload...)})
		case flightchess.MoveAccepted:
			payload, decodeErr := decodeAcceptedFlightChessMove(event.Payload)
			if terminalType != "" || event.ActionID == nil || !canonicalUUID(*event.ActionID) || event.ActorUserID == nil || decodeErr != nil || payload.UserID != *event.ActorUserID {
				return Snapshot{}, ErrInternal
			}
			actor, _, member := actionPlayers(players, *event.ActorUserID)
			if !member || payload.Color != string(actor.Color) {
				return Snapshot{}, ErrInternal
			}
			accepted = append(accepted, games.Event{Revision: event.Revision, Type: event.Type, ActorID: *event.ActorUserID, Payload: append(json.RawMessage(nil), event.Payload...)})
		case protocol.TypeFlightChessResigned:
			if index != len(events)-1 || event.ActionID == nil || !canonicalUUID(*event.ActionID) || event.ActorUserID == nil {
				return Snapshot{}, ErrInternal
			}
			actor, opponent, member := actionPlayers(players, *event.ActorUserID)
			payload, decodeErr := decodeResignedPayload(event.Payload)
			if !member || decodeErr != nil || payload.UserID != actor.UserID || payload.WinnerUserID != opponent.UserID {
				return Snapshot{}, ErrInternal
			}
			terminalType = event.Type
		case protocol.TypePlatformMatchCancelled:
			if index != len(events)-1 || len(accepted) != 0 || event.ActionID != nil || event.ActorUserID == nil || !playerMember(players, *event.ActorUserID) || !isStrictEmptyObject(event.Payload) {
				return Snapshot{}, ErrInternal
			}
			terminalType = event.Type
		case protocol.TypePlatformMatchAbandoned:
			if index != len(events)-1 || event.ActionID != nil || event.ActorUserID != nil || !isStrictEmptyObject(event.Payload) {
				return Snapshot{}, ErrInternal
			}
			terminalType = event.Type
		default:
			return Snapshot{}, ErrInternal
		}
	}
	gameSnapshot, rebuildErr := rules.Rebuild(accepted)
	if rebuildErr != nil || gameSnapshot.Revision != int64(len(accepted)) {
		return Snapshot{}, ErrInternal
	}
	summary, summaryErr := readGameStateSummary(gameSnapshot)
	if summaryErr != nil || summary.NextColor != string(ColorBlack) && summary.NextColor != string(ColorWhite) {
		return Snapshot{}, ErrInternal
	}
	if len(accepted) == 0 {
		if summary.BlackUserID != nil || summary.WhiteUserID != nil || summary.NextColor != string(ColorBlack) {
			return Snapshot{}, ErrInternal
		}
	} else if summary.BlackUserID == nil || *summary.BlackUserID != black.UserID {
		return Snapshot{}, ErrInternal
	}
	if summary.WhiteUserID != nil && *summary.WhiteUserID != white.UserID {
		return Snapshot{}, ErrInternal
	}
	if lifecycleErr := validateLifecycle(match, summary, terminalType, players, events); lifecycleErr != nil {
		return Snapshot{}, lifecycleErr
	}
	playerIDs := [2]string{players[0].UserID, players[1].UserID}
	expectActiveSlots := match.Status == StatusActive && singleActiveMatch(rules)
	if slotsErr := validateCompleteActiveSlotSet(ctx, transaction, match.GameID, match.ID, playerIDs, expectActiveSlots); slotsErr != nil {
		return Snapshot{}, slotsErr
	}
	return cloneMatchSnapshot(Snapshot{Match: match, Players: players, Game: gameSnapshot}), nil
}

func (service *Service) rebuildChineseCheckersSnapshot(ctx context.Context, transaction *sql.Tx, match Match, players []Player, rules games.Rules, events []Event) (Snapshot, error) {
	black, white, ok := coloredPlayers(players)
	if !ok {
		return Snapshot{}, ErrInternal
	}
	accepted := make([]games.Event, 0, len(events))
	terminalType := ""
	for index, event := range events {
		if event.Revision != int64(index+1) || event.MatchID != match.ID {
			return Snapshot{}, ErrInternal
		}
		switch event.Type {
		case chinesecheckers.MoveAccepted:
			if terminalType != "" || event.ActionID == nil || !canonicalUUID(*event.ActionID) || event.ActorUserID == nil {
				return Snapshot{}, ErrInternal
			}
			move, decodeErr := decodeAcceptedChineseCheckersMove(event.Payload)
			if decodeErr != nil || move.userID != *event.ActorUserID {
				return Snapshot{}, ErrInternal
			}
			expected := black
			if len(accepted)%2 == 1 {
				expected = white
			}
			if expected.UserID != *event.ActorUserID || string(expected.Color) != move.color {
				return Snapshot{}, ErrInternal
			}
			accepted = append(accepted, games.Event{
				Revision: event.Revision, Type: event.Type, ActorID: *event.ActorUserID,
				Payload: append(json.RawMessage(nil), event.Payload...),
			})
		case protocol.TypeChineseCheckersResigned:
			if index != len(events)-1 || event.ActionID == nil || !canonicalUUID(*event.ActionID) || event.ActorUserID == nil {
				return Snapshot{}, ErrInternal
			}
			actor, opponent, member := actionPlayers(players, *event.ActorUserID)
			resigned, decodeErr := decodeResignedPayload(event.Payload)
			if !member || decodeErr != nil || resigned.UserID != actor.UserID || resigned.WinnerUserID != opponent.UserID {
				return Snapshot{}, ErrInternal
			}
			terminalType = event.Type
		case protocol.TypePlatformMatchCancelled:
			if index != len(events)-1 || len(accepted) != 0 || event.ActionID != nil || event.ActorUserID == nil || !playerMember(players, *event.ActorUserID) || !isStrictEmptyObject(event.Payload) {
				return Snapshot{}, ErrInternal
			}
			terminalType = event.Type
		case protocol.TypePlatformMatchAbandoned:
			if index != len(events)-1 || event.ActionID != nil || event.ActorUserID != nil || !isStrictEmptyObject(event.Payload) {
				return Snapshot{}, ErrInternal
			}
			terminalType = event.Type
		default:
			return Snapshot{}, ErrInternal
		}
	}
	gameSnapshot, rebuildErr := rules.Rebuild(accepted)
	if rebuildErr != nil || gameSnapshot.Revision != int64(len(accepted)) {
		return Snapshot{}, ErrInternal
	}
	summary, summaryErr := readGameStateSummary(gameSnapshot)
	if summaryErr != nil {
		return Snapshot{}, ErrInternal
	}
	if len(accepted) == 0 {
		if summary.BlackUserID != nil || summary.WhiteUserID != nil || summary.NextColor != string(ColorBlack) {
			return Snapshot{}, ErrInternal
		}
	} else {
		if summary.BlackUserID == nil || *summary.BlackUserID != black.UserID {
			return Snapshot{}, ErrInternal
		}
		if len(accepted) >= 2 {
			if summary.WhiteUserID == nil || *summary.WhiteUserID != white.UserID {
				return Snapshot{}, ErrInternal
			}
		} else if summary.WhiteUserID != nil {
			return Snapshot{}, ErrInternal
		}
		wantNext := string(ColorBlack)
		if len(accepted)%2 == 1 {
			wantNext = string(ColorWhite)
		}
		if summary.NextColor != wantNext {
			return Snapshot{}, ErrInternal
		}
	}
	if lifecycleErr := validateLifecycle(match, summary, terminalType, players, events); lifecycleErr != nil {
		return Snapshot{}, lifecycleErr
	}
	playerIDs := [2]string{players[0].UserID, players[1].UserID}
	expectActiveSlots := match.Status == StatusActive && singleActiveMatch(rules)
	if slotsErr := validateCompleteActiveSlotSet(ctx, transaction, match.GameID, match.ID, playerIDs, expectActiveSlots); slotsErr != nil {
		return Snapshot{}, slotsErr
	}
	return cloneMatchSnapshot(Snapshot{Match: match, Players: players, Game: gameSnapshot}), nil
}

func (service *Service) rebuildRpsSnapshot(ctx context.Context, transaction *sql.Tx, match Match, players []Player, rules games.Rules, events []Event) (Snapshot, error) {
	accepted := make([]games.Event, 0, len(events))
	terminalType := ""
	for index, event := range events {
		if event.Revision != int64(index+1) || event.MatchID != match.ID {
			return Snapshot{}, ErrInternal
		}
		switch event.Type {
		case rps.ChoiceLocked:
			payload, decodeErr := decodeRpsLocked(event.Payload)
			if terminalType != "" || event.ActionID == nil || !canonicalUUID(*event.ActionID) || event.ActorUserID == nil || !playerMember(players, *event.ActorUserID) || decodeErr != nil || payload.UserID != *event.ActorUserID {
				return Snapshot{}, ErrInternal
			}
			accepted = append(accepted, games.Event{Revision: event.Revision, Type: event.Type, ActorID: *event.ActorUserID, Payload: append(json.RawMessage(nil), event.Payload...)})
		case rps.RoundRevealed:
			payload, decodeErr := decodeRpsReveal(event.Payload)
			if terminalType != "" || event.ActionID == nil || !canonicalUUID(*event.ActionID) || event.ActorUserID == nil || !playerMember(players, *event.ActorUserID) || decodeErr != nil || payload.Choices[*event.ActorUserID] == "" {
				return Snapshot{}, ErrInternal
			}
			accepted = append(accepted, games.Event{Revision: event.Revision, Type: event.Type, ActorID: *event.ActorUserID, Payload: append(json.RawMessage(nil), event.Payload...)})
		case protocol.TypeRpsResigned:
			if index != len(events)-1 || event.ActionID == nil || !canonicalUUID(*event.ActionID) || event.ActorUserID == nil {
				return Snapshot{}, ErrInternal
			}
			actor, opponent, member := actionPlayers(players, *event.ActorUserID)
			payload, decodeErr := decodeResignedPayload(event.Payload)
			if !member || decodeErr != nil || payload.UserID != actor.UserID || payload.WinnerUserID != opponent.UserID {
				return Snapshot{}, ErrInternal
			}
			terminalType = event.Type
		case protocol.TypePlatformMatchCancelled:
			if index != len(events)-1 || len(accepted) != 0 || event.ActionID != nil || event.ActorUserID == nil || !playerMember(players, *event.ActorUserID) || !isStrictEmptyObject(event.Payload) {
				return Snapshot{}, ErrInternal
			}
			terminalType = event.Type
		case protocol.TypePlatformMatchAbandoned:
			if index != len(events)-1 || event.ActionID != nil || event.ActorUserID != nil || !isStrictEmptyObject(event.Payload) {
				return Snapshot{}, ErrInternal
			}
			terminalType = event.Type
		default:
			return Snapshot{}, ErrInternal
		}
	}
	gameSnapshot, rebuildErr := rules.Rebuild(accepted)
	if rebuildErr != nil || gameSnapshot.Revision != int64(len(accepted)) {
		return Snapshot{}, ErrInternal
	}
	summary, summaryErr := readGameStateSummary(gameSnapshot)
	if summaryErr != nil {
		return Snapshot{}, ErrInternal
	}
	switch match.Status {
	case StatusActive:
		if terminalType != "" || match.Result != nil || match.WinnerUserID != nil || match.FinishedAt != nil || summary.Status != StatusActive || summary.Result != nil || summary.WinnerUserID != nil {
			return Snapshot{}, ErrInternal
		}
	case StatusFinished:
		if match.FinishedAt == nil || match.Result == nil {
			return Snapshot{}, ErrInternal
		}
		switch *match.Result {
		case ResultRounds:
			if terminalType != "" || summary.Status != StatusFinished || summary.Result == nil || *summary.Result != ResultRounds || match.WinnerUserID == nil || summary.WinnerUserID == nil || *match.WinnerUserID != *summary.WinnerUserID || !playerMember(players, *match.WinnerUserID) {
				return Snapshot{}, ErrInternal
			}
		case ResultResignation:
			if terminalType != protocol.TypeRpsResigned || summary.Status != StatusActive || summary.Result != nil || summary.WinnerUserID != nil || match.WinnerUserID == nil || !playerMember(players, *match.WinnerUserID) {
				return Snapshot{}, ErrInternal
			}
		default:
			return Snapshot{}, ErrInternal
		}
	case StatusCancelled:
		if terminalType != protocol.TypePlatformMatchCancelled || match.FinishedAt == nil || match.Result != nil || match.WinnerUserID != nil || summary.Status != StatusActive {
			return Snapshot{}, ErrInternal
		}
	case StatusAbandoned:
		if terminalType != protocol.TypePlatformMatchAbandoned || match.FinishedAt == nil || match.Result != nil || match.WinnerUserID != nil || summary.Status != StatusActive {
			return Snapshot{}, ErrInternal
		}
	default:
		return Snapshot{}, ErrInternal
	}
	playerIDs := [2]string{players[0].UserID, players[1].UserID}
	expectSlots := match.Status == StatusActive && singleActiveMatch(rules)
	if slotsErr := validateCompleteActiveSlotSet(ctx, transaction, match.GameID, match.ID, playerIDs, expectSlots); slotsErr != nil {
		return Snapshot{}, slotsErr
	}
	return cloneMatchSnapshot(Snapshot{Match: match, Players: players, Game: gameSnapshot}), nil
}

func validateLifecycle(match Match, game gameStateSummary, terminalType string, players []Player, events []Event) error {
	if match.Revision > int64(maximumMatchEventsFor(match.GameID)) {
		return ErrInternal
	}
	switch match.Status {
	case StatusActive:
		if terminalType != "" || match.Result != nil || match.WinnerUserID != nil || match.FinishedAt != nil || game.Status != StatusActive || game.Result != nil || game.WinnerUserID != nil {
			return ErrInternal
		}
	case StatusFinished:
		if match.FinishedAt == nil || match.Result == nil || terminalType == protocol.TypePlatformMatchCancelled || terminalType == protocol.TypePlatformMatchAbandoned {
			return ErrInternal
		}
		switch *match.Result {
		case ResultFive:
			if terminalType != "" || game.Status != StatusFinished || game.Result == nil || *game.Result != ResultFive ||
				match.WinnerUserID == nil || game.WinnerUserID == nil || *match.WinnerUserID != *game.WinnerUserID || !playerMember(players, *match.WinnerUserID) {
				return ErrInternal
			}
		case ResultGoal:
			if match.GameID != chinesecheckers.GameID && match.GameID != flightchess.GameID || terminalType != "" || game.Status != StatusFinished || game.Result == nil || *game.Result != ResultGoal ||
				match.WinnerUserID == nil || game.WinnerUserID == nil || *match.WinnerUserID != *game.WinnerUserID || !playerMember(players, *match.WinnerUserID) {
				return ErrInternal
			}
		case ResultDraw:
			if terminalType != "" || game.Status != StatusFinished || game.Result == nil || *game.Result != ResultDraw || match.WinnerUserID != nil || game.WinnerUserID != nil {
				return ErrInternal
			}
		case ResultResignation:
			expectedTerminal := protocol.TypeGomokuResigned
			if match.GameID == chinesecheckers.GameID {
				expectedTerminal = protocol.TypeChineseCheckersResigned
			} else if match.GameID == flightchess.GameID {
				expectedTerminal = protocol.TypeFlightChessResigned
			}
			if terminalType != expectedTerminal || game.Status != StatusActive || game.Result != nil || game.WinnerUserID != nil || match.WinnerUserID == nil || !playerMember(players, *match.WinnerUserID) || len(events) == 0 {
				return ErrInternal
			}
			last := events[len(events)-1]
			payload, err := decodeResignedPayload(last.Payload)
			if err != nil || payload.WinnerUserID != *match.WinnerUserID {
				return ErrInternal
			}
		default:
			return ErrInternal
		}
	case StatusCancelled:
		if terminalType != protocol.TypePlatformMatchCancelled || match.FinishedAt == nil || match.Result != nil || match.WinnerUserID != nil || game.Status != StatusActive || game.Result != nil || game.WinnerUserID != nil {
			return ErrInternal
		}
	case StatusAbandoned:
		if terminalType != protocol.TypePlatformMatchAbandoned || match.FinishedAt == nil || match.Result != nil || match.WinnerUserID != nil || game.Status != StatusActive || game.Result != nil || game.WinnerUserID != nil {
			return ErrInternal
		}
	default:
		return ErrInternal
	}
	return nil
}

func readMatchEvents(ctx context.Context, transaction *sql.Tx, matchID string, eventLimit int) ([]Event, error) {
	rows, err := transaction.QueryContext(ctx, `
SELECT revision,event_type,action_id,actor_user_id,payload_json,created_at
FROM match_events
WHERE match_id=?
ORDER BY revision`, matchID)
	if err != nil {
		return nil, matchDatabaseError(ctx, err)
	}
	defer rows.Close()
	events := make([]Event, 0, 16)
	for rows.Next() {
		if len(events) >= eventLimit+1 {
			return nil, ErrInternal
		}
		var event Event
		var actionID, actorID sql.NullString
		var payload string
		var createdAt int64
		if scanErr := rows.Scan(&event.Revision, &event.Type, &actionID, &actorID, &payload, &createdAt); scanErr != nil {
			return nil, matchDatabaseError(ctx, scanErr)
		}
		event.MatchID = matchID
		if actionID.Valid {
			event.ActionID = stringPointer(actionID.String)
		}
		if actorID.Valid {
			event.ActorUserID = stringPointer(actorID.String)
		}
		event.Payload = append(json.RawMessage(nil), payload...)
		event.CreatedAt = time.UnixMilli(createdAt).UTC()
		events = append(events, event)
	}
	if rowsErr := rows.Err(); rowsErr != nil {
		return nil, matchDatabaseError(ctx, rowsErr)
	}
	return events, nil
}

func maximumMatchEventsFor(gameID string) int {
	if gameID == flightchess.GameID {
		return maximumFlightChessEvents
	}
	return maximumMatchEvents
}

func readActionEvent(ctx context.Context, transaction *sql.Tx, matchID, actorID, actionID string) (Event, bool, error) {
	var event Event
	var storedActionID, storedActorID sql.NullString
	var payload string
	var createdAt int64
	err := transaction.QueryRowContext(ctx, `
SELECT revision,event_type,action_id,actor_user_id,payload_json,created_at
FROM match_events
WHERE match_id=? AND actor_user_id=? AND action_id=?`, matchID, actorID, actionID).
		Scan(&event.Revision, &event.Type, &storedActionID, &storedActorID, &payload, &createdAt)
	if errors.Is(err, sql.ErrNoRows) {
		return Event{}, false, nil
	}
	if err != nil {
		return Event{}, false, matchDatabaseError(ctx, err)
	}
	event.MatchID = matchID
	if storedActionID.Valid {
		event.ActionID = stringPointer(storedActionID.String)
	}
	if storedActorID.Valid {
		event.ActorUserID = stringPointer(storedActorID.String)
	}
	event.Payload = append(json.RawMessage(nil), payload...)
	event.CreatedAt = time.UnixMilli(createdAt).UTC()
	return event, true, nil
}

func committedActionMatches(event Event, request ActionRequest, semantics actionSemantics, players []Player) (bool, error) {
	if event.ActionID == nil || *event.ActionID != request.ActionID || event.ActorUserID == nil || *event.ActorUserID != request.ActorUserID || !canonicalUUID(*event.ActionID) {
		return false, ErrInternal
	}
	switch request.Type {
	case chinesecheckers.MoveRequested:
		if event.Type != chinesecheckers.MoveAccepted {
			return false, nil
		}
		move, err := decodeAcceptedChineseCheckersMove(event.Payload)
		if err != nil || move.userID != request.ActorUserID {
			return false, ErrInternal
		}
		actor, _, member := actionPlayers(players, request.ActorUserID)
		if !member || move.color != string(actor.Color) {
			return false, ErrInternal
		}
		return slices.Equal(move.path, semantics.path), nil
	case protocol.TypeChineseCheckersResignRequested:
		if event.Type != protocol.TypeChineseCheckersResigned {
			return false, nil
		}
		payload, err := decodeResignedPayload(event.Payload)
		actor, opponent, member := actionPlayers(players, request.ActorUserID)
		if err != nil || !member || payload.UserID != actor.UserID || payload.WinnerUserID != opponent.UserID {
			return false, ErrInternal
		}
		return true, nil
	case flightchess.RollRequested:
		if event.Type != flightchess.RollAccepted {
			return false, nil
		}
		payload, err := decodeAcceptedFlightChessRoll(event.Payload)
		actor, _, member := actionPlayers(players, request.ActorUserID)
		if err != nil || !member || payload.UserID != request.ActorUserID || payload.Color != string(actor.Color) {
			return false, ErrInternal
		}
		return true, nil
	case flightchess.MoveRequested:
		if event.Type != flightchess.MoveAccepted {
			return false, nil
		}
		payload, err := decodeAcceptedFlightChessMove(event.Payload)
		actor, _, member := actionPlayers(players, request.ActorUserID)
		if err != nil || !member || payload.UserID != request.ActorUserID || payload.Color != string(actor.Color) {
			return false, ErrInternal
		}
		return payload.PieceIndex == semantics.pieceIndex, nil
	case protocol.TypeFlightChessResignRequested:
		if event.Type != protocol.TypeFlightChessResigned {
			return false, nil
		}
		payload, err := decodeResignedPayload(event.Payload)
		actor, opponent, member := actionPlayers(players, request.ActorUserID)
		if err != nil || !member || payload.UserID != actor.UserID || payload.WinnerUserID != opponent.UserID {
			return false, ErrInternal
		}
		return true, nil
	case gomoku.MoveRequested:
		if event.Type != gomoku.MoveAccepted {
			return false, nil
		}
		move, err := decodeAcceptedMove(event.Payload)
		if err != nil || move.userID != request.ActorUserID {
			return false, ErrInternal
		}
		actor, _, member := actionPlayers(players, request.ActorUserID)
		if !member || move.color != string(actor.Color) {
			return false, ErrInternal
		}
		return move.x == semantics.x && move.y == semantics.y, nil
	case protocol.TypeGomokuResignRequested:
		if event.Type != protocol.TypeGomokuResigned {
			return false, nil
		}
		payload, err := decodeResignedPayload(event.Payload)
		actor, opponent, member := actionPlayers(players, request.ActorUserID)
		if err != nil || !member || payload.UserID != actor.UserID || payload.WinnerUserID != opponent.UserID {
			return false, ErrInternal
		}
		return true, nil
	case rps.ChoiceRequested:
		switch event.Type {
		case rps.ChoiceLocked:
			payload, err := decodeRpsLocked(event.Payload)
			if err != nil || payload.UserID != request.ActorUserID {
				return false, ErrInternal
			}
			return payload.Choice == semantics.choice, nil
		case rps.RoundRevealed:
			payload, err := decodeRpsReveal(event.Payload)
			if err != nil {
				return false, ErrInternal
			}
			return payload.Choices[request.ActorUserID] == semantics.choice, nil
		default:
			return false, nil
		}
	case protocol.TypeRpsResignRequested:
		if event.Type != protocol.TypeRpsResigned {
			return false, nil
		}
		payload, err := decodeResignedPayload(event.Payload)
		actor, opponent, member := actionPlayers(players, request.ActorUserID)
		if err != nil || !member || payload.UserID != actor.UserID || payload.WinnerUserID != opponent.UserID {
			return false, ErrInternal
		}
		return true, nil
	default:
		return false, ErrInvalidRequest
	}
}

type acceptedMove struct {
	x      int
	y      int
	color  string
	userID string
}

type acceptedChineseCheckersMove struct {
	path   []int
	color  string
	userID string
}

type acceptedFlightChessRoll struct {
	Color               string `json:"color"`
	UserID              string `json:"userId"`
	Value               int    `json:"value"`
	MovablePieceIndices []int  `json:"movablePieceIndices"`
}

type acceptedFlightChessMove struct {
	Color                string            `json:"color"`
	UserID               string            `json:"userId"`
	PieceIndex           int               `json:"pieceIndex"`
	Roll                 int               `json:"roll"`
	From                 flightchess.Piece `json:"from"`
	To                   flightchess.Piece `json:"to"`
	Effect               string            `json:"effect"`
	CapturedPieceIndices []int             `json:"capturedPieceIndices"`
}

func decodeAcceptedFlightChessRoll(payload json.RawMessage) (acceptedFlightChessRoll, error) {
	allowed := map[string]struct{}{"color": {}, "userId": {}, "value": {}, "movablePieceIndices": {}}
	fields, err := strictJSONObject(payload, allowed)
	if err != nil || len(fields) != len(allowed) {
		return acceptedFlightChessRoll{}, ErrInternal
	}
	var value acceptedFlightChessRoll
	if json.Unmarshal(payload, &value) != nil || value.Color != string(ColorBlack) && value.Color != string(ColorWhite) ||
		!validIdentifier(value.UserID) || value.Value < 1 || value.Value > 6 || !validFlightChessIndices(value.MovablePieceIndices) {
		return acceptedFlightChessRoll{}, ErrInternal
	}
	return value, nil
}

func decodeAcceptedFlightChessMove(payload json.RawMessage) (acceptedFlightChessMove, error) {
	allowed := map[string]struct{}{"color": {}, "userId": {}, "pieceIndex": {}, "roll": {}, "from": {}, "to": {}, "effect": {}, "capturedPieceIndices": {}}
	fields, err := strictJSONObject(payload, allowed)
	if err != nil || len(fields) != len(allowed) {
		return acceptedFlightChessMove{}, ErrInternal
	}
	var value acceptedFlightChessMove
	if json.Unmarshal(payload, &value) != nil || value.Color != string(ColorBlack) && value.Color != string(ColorWhite) ||
		!validIdentifier(value.UserID) || value.PieceIndex < 0 || value.PieceIndex >= flightchess.PieceCount || value.Roll < 1 || value.Roll > 6 ||
		!validFlightChessIndices(value.CapturedPieceIndices) {
		return acceptedFlightChessMove{}, ErrInternal
	}
	return value, nil
}

func validFlightChessIndices(values []int) bool {
	seen := map[int]bool{}
	for _, value := range values {
		if value < 0 || value >= flightchess.PieceCount || seen[value] {
			return false
		}
		seen[value] = true
	}
	return true
}

func decodeAcceptedChineseCheckersMove(payload json.RawMessage) (acceptedChineseCheckersMove, error) {
	fields, err := strictJSONObject(payload, map[string]struct{}{"path": {}, "color": {}, "userId": {}})
	if err != nil || len(fields) != 3 {
		return acceptedChineseCheckersMove{}, ErrInternal
	}
	path, err := decodeChineseCheckersPath(fields["path"])
	if err != nil {
		return acceptedChineseCheckersMove{}, ErrInternal
	}
	var color, userID string
	if json.Unmarshal(fields["color"], &color) != nil || json.Unmarshal(fields["userId"], &userID) != nil ||
		(color != string(ColorBlack) && color != string(ColorWhite)) || !validIdentifier(userID) {
		return acceptedChineseCheckersMove{}, ErrInternal
	}
	return acceptedChineseCheckersMove{path: path, color: color, userID: userID}, nil
}

func decodeAcceptedMove(payload json.RawMessage) (acceptedMove, error) {
	fields, err := strictJSONObject(payload, map[string]struct{}{"x": {}, "y": {}, "color": {}, "userId": {}})
	if err != nil || len(fields) != 4 {
		return acceptedMove{}, ErrInternal
	}
	x, err := strictJSONInteger(fields["x"])
	if err != nil {
		return acceptedMove{}, ErrInternal
	}
	y, err := strictJSONInteger(fields["y"])
	if err != nil {
		return acceptedMove{}, ErrInternal
	}
	var color, userID string
	if json.Unmarshal(fields["color"], &color) != nil || json.Unmarshal(fields["userId"], &userID) != nil ||
		(color != string(ColorBlack) && color != string(ColorWhite)) || !validIdentifier(userID) || x < 0 || x >= 15 || y < 0 || y >= 15 {
		return acceptedMove{}, ErrInternal
	}
	return acceptedMove{x: x, y: y, color: color, userID: userID}, nil
}

func decodeResignedPayload(payload json.RawMessage) (resignedPayload, error) {
	fields, err := strictJSONObject(payload, map[string]struct{}{"userId": {}, "winnerUserId": {}})
	if err != nil || len(fields) != 2 {
		return resignedPayload{}, ErrInternal
	}
	var result resignedPayload
	if json.Unmarshal(fields["userId"], &result.UserID) != nil || json.Unmarshal(fields["winnerUserId"], &result.WinnerUserID) != nil ||
		!validIdentifier(result.UserID) || !validIdentifier(result.WinnerUserID) || result.UserID == result.WinnerUserID {
		return resignedPayload{}, ErrInternal
	}
	return result, nil
}

func validateProducedMove(event games.Event, snapshot games.Snapshot, request ActionRequest, semantics actionSemantics, color Color, revision int64) error {
	if event.Revision != revision || snapshot.Revision != revision || event.Type != gomoku.MoveAccepted || event.ActorID != request.ActorUserID {
		return ErrInternal
	}
	move, err := decodeAcceptedMove(event.Payload)
	if err != nil || move.x != semantics.x || move.y != semantics.y || move.color != string(color) || move.userID != request.ActorUserID {
		return ErrInternal
	}
	return nil
}

func validateProducedChineseCheckersMove(event games.Event, snapshot games.Snapshot, request ActionRequest, semantics actionSemantics, color Color, revision int64) error {
	if event.Revision != revision || snapshot.Revision != revision || event.Type != chinesecheckers.MoveAccepted || event.ActorID != request.ActorUserID {
		return ErrInternal
	}
	move, err := decodeAcceptedChineseCheckersMove(event.Payload)
	if err != nil || !slices.Equal(move.path, semantics.path) || move.color != string(color) || move.userID != request.ActorUserID {
		return ErrInternal
	}
	return nil
}

func validateProducedFlightChess(event games.Event, snapshot games.Snapshot, request ActionRequest, semantics actionSemantics, color Color, revision int64) error {
	if event.Revision != revision || snapshot.Revision != revision || event.ActorID != request.ActorUserID {
		return ErrInternal
	}
	switch request.Type {
	case flightchess.RollRequested:
		if event.Type != flightchess.RollAccepted {
			return ErrInternal
		}
		payload, err := decodeAcceptedFlightChessRoll(event.Payload)
		if err != nil || payload.UserID != request.ActorUserID || payload.Color != string(color) {
			return ErrInternal
		}
	case flightchess.MoveRequested:
		if event.Type != flightchess.MoveAccepted {
			return ErrInternal
		}
		payload, err := decodeAcceptedFlightChessMove(event.Payload)
		if err != nil || payload.UserID != request.ActorUserID || payload.Color != string(color) || payload.PieceIndex != semantics.pieceIndex {
			return ErrInternal
		}
	default:
		return ErrInternal
	}
	return nil
}

type rpsLockedPayload struct {
	Round  int    `json:"round"`
	UserID string `json:"userId"`
	Choice string `json:"choice"`
}

type rpsRevealPayload struct {
	Round             int               `json:"round"`
	Choices           map[string]string `json:"choices"`
	RoundWinnerUserID *string           `json:"roundWinnerUserId"`
	Draw              bool              `json:"draw"`
	Scores            map[string]int    `json:"scores"`
	MatchWinnerUserID *string           `json:"matchWinnerUserId"`
	Result            *string           `json:"result"`
}

func decodeRpsLocked(payload json.RawMessage) (rpsLockedPayload, error) {
	fields, err := strictJSONObject(payload, map[string]struct{}{"round": {}, "userId": {}, "choice": {}})
	if err != nil || len(fields) != 3 {
		return rpsLockedPayload{}, ErrInternal
	}
	var value rpsLockedPayload
	if json.Unmarshal(payload, &value) != nil || value.Round < 1 || !validIdentifier(value.UserID) || !validRpsChoice(value.Choice) {
		return rpsLockedPayload{}, ErrInternal
	}
	return value, nil
}

func decodeRpsReveal(payload json.RawMessage) (rpsRevealPayload, error) {
	allowed := map[string]struct{}{"round": {}, "choices": {}, "roundWinnerUserId": {}, "draw": {}, "scores": {}, "matchWinnerUserId": {}, "result": {}}
	fields, err := strictJSONObject(payload, allowed)
	if err != nil || len(fields) != len(allowed) {
		return rpsRevealPayload{}, ErrInternal
	}
	var value rpsRevealPayload
	if json.Unmarshal(payload, &value) != nil || value.Round < 1 || len(value.Choices) != 2 || len(value.Scores) > 2 {
		return rpsRevealPayload{}, ErrInternal
	}
	for userID, choice := range value.Choices {
		if !validIdentifier(userID) || !validRpsChoice(choice) {
			return rpsRevealPayload{}, ErrInternal
		}
	}
	return value, nil
}

func validRpsChoice(choice string) bool {
	return choice == rps.Rock || choice == rps.Paper || choice == rps.Scissors
}

func validateProducedChoice(event games.Event, snapshot games.Snapshot, request ActionRequest, semantics actionSemantics, revision int64) error {
	if event.Revision != revision || snapshot.Revision != revision || event.ActorID != request.ActorUserID {
		return ErrInternal
	}
	switch event.Type {
	case rps.ChoiceLocked:
		payload, err := decodeRpsLocked(event.Payload)
		if err != nil || payload.UserID != request.ActorUserID || payload.Choice != semantics.choice {
			return ErrInternal
		}
	case rps.RoundRevealed:
		payload, err := decodeRpsReveal(event.Payload)
		if err != nil || payload.Choices[request.ActorUserID] != semantics.choice {
			return ErrInternal
		}
	default:
		return ErrInternal
	}
	return nil
}

func safeActionRuleError(err error) error {
	switch {
	case errors.Is(err, chinesecheckers.ErrNotYourTurn):
		return chinesecheckers.ErrNotYourTurn
	case errors.Is(err, chinesecheckers.ErrInvalidPath):
		return chinesecheckers.ErrInvalidPath
	case errors.Is(err, flightchess.ErrNotYourTurn):
		return flightchess.ErrNotYourTurn
	case errors.Is(err, flightchess.ErrInvalidMove), errors.Is(err, flightchess.ErrInvalidPhase):
		return ErrInvalidRequest
	case errors.Is(err, flightchess.ErrRandomUnavailable):
		return ErrInternal
	case errors.Is(err, gomoku.ErrNotYourTurn):
		return gomoku.ErrNotYourTurn
	case errors.Is(err, gomoku.ErrCellOccupied):
		return gomoku.ErrCellOccupied
	case errors.Is(err, rps.ErrChoiceLocked):
		return rps.ErrChoiceLocked
	case errors.Is(err, rps.ErrInvalidChoice), errors.Is(err, rps.ErrMatchFinished):
		return ErrInvalidRequest
	case errors.Is(err, games.ErrInvalidAction):
		return ErrInvalidRequest
	default:
		return ErrInternal
	}
}

func readGameStateSummary(snapshot games.Snapshot) (gameStateSummary, error) {
	if snapshot.Revision < 0 || len(snapshot.State) == 0 || len(snapshot.State) > 8192 || !utf8.Valid(snapshot.State) {
		return gameStateSummary{}, ErrInternal
	}
	var summary gameStateSummary
	if err := json.Unmarshal(snapshot.State, &summary); err != nil {
		return gameStateSummary{}, ErrInternal
	}
	if summary.Status != StatusActive && summary.Status != StatusFinished {
		return gameStateSummary{}, ErrInternal
	}
	return summary, nil
}

func coloredPlayers(players []Player) (Player, Player, bool) {
	if len(players) != 2 {
		return Player{}, Player{}, false
	}
	if players[0].Color == ColorBlack && players[1].Color == ColorWhite {
		return players[0], players[1], true
	}
	if players[1].Color == ColorBlack && players[0].Color == ColorWhite {
		return players[1], players[0], true
	}
	return Player{}, Player{}, false
}

func actionPlayers(players []Player, actorID string) (Player, Player, bool) {
	if len(players) != 2 {
		return Player{}, Player{}, false
	}
	if players[0].UserID == actorID {
		return players[0], players[1], true
	}
	if players[1].UserID == actorID {
		return players[1], players[0], true
	}
	return Player{}, Player{}, false
}

func playerMember(players []Player, userID string) bool {
	_, _, ok := actionPlayers(players, userID)
	return ok
}

func isStrictEmptyObject(payload json.RawMessage) bool {
	fields, err := strictJSONObject(payload, map[string]struct{}{})
	return err == nil && len(fields) == 0
}

func cloneEvent(event Event) Event {
	return Event{
		MatchID: event.MatchID, Revision: event.Revision, Type: event.Type,
		ActionID: cloneStringPointer(event.ActionID), ActorUserID: cloneStringPointer(event.ActorUserID),
		Payload: append(json.RawMessage(nil), event.Payload...), CreatedAt: event.CreatedAt,
	}
}

func cloneMatchSnapshot(snapshot Snapshot) Snapshot {
	return Snapshot{
		Match: Match{
			ID: snapshot.Match.ID, GameID: snapshot.Match.GameID, Status: snapshot.Match.Status, Revision: snapshot.Match.Revision,
			Result: cloneStringPointer(snapshot.Match.Result), WinnerUserID: cloneStringPointer(snapshot.Match.WinnerUserID),
			GameConfig: append(json.RawMessage(nil), snapshot.Match.GameConfig...),
			CreatedAt:  snapshot.Match.CreatedAt, UpdatedAt: snapshot.Match.UpdatedAt, FinishedAt: cloneTimePointer(snapshot.Match.FinishedAt),
		},
		Players: append([]Player(nil), snapshot.Players...),
		Game:    cloneGameSnapshot(snapshot.Game),
	}
}

func cloneGameSnapshot(snapshot games.Snapshot) games.Snapshot {
	return games.Snapshot{Revision: snapshot.Revision, State: append(json.RawMessage(nil), snapshot.State...)}
}

func cloneStringPointer(value *string) *string {
	if value == nil {
		return nil
	}
	copy := *value
	return &copy
}

func cloneTimePointer(value *time.Time) *time.Time {
	if value == nil {
		return nil
	}
	copy := *value
	return &copy
}

func stringPointer(value string) *string { return &value }

func valueOrNil(value *string) any {
	if value == nil {
		return nil
	}
	return *value
}

func (service *Service) configured() bool {
	return service != nil && service.db != nil && service.games != nil && !nilDependency(service.clock) && !nilDependency(service.random)
}

func nilDependency(value any) bool {
	if value == nil {
		return true
	}
	reflected := reflect.ValueOf(value)
	switch reflected.Kind() {
	case reflect.Chan, reflect.Func, reflect.Interface, reflect.Map, reflect.Pointer, reflect.Slice:
		return reflected.IsNil()
	default:
		return false
	}
}

func validIdentifier(value string) bool {
	return value != "" && len(value) <= maximumIdentifierBytes && strings.TrimSpace(value) == value
}

func enabledUser(ctx context.Context, transaction *sql.Tx, userID string) (bool, error) {
	var enabled int
	if err := transaction.QueryRowContext(ctx, `SELECT enabled FROM users WHERE id=?`, userID).Scan(&enabled); err != nil {
		return false, err
	}
	return enabled == 1, nil
}

func readTwoMatchPlayers(ctx context.Context, transaction *sql.Tx, matchID string) ([2]string, error) {
	rows, err := transaction.QueryContext(ctx, `
SELECT user_id
FROM match_players
WHERE match_id=?
ORDER BY seat`, matchID)
	if err != nil {
		return [2]string{}, matchDatabaseError(ctx, err)
	}
	defer rows.Close()
	var players []string
	for rows.Next() {
		var userID string
		if err := rows.Scan(&userID); err != nil {
			return [2]string{}, matchDatabaseError(ctx, err)
		}
		players = append(players, userID)
	}
	if err := rows.Err(); err != nil {
		return [2]string{}, matchDatabaseError(ctx, err)
	}
	if len(players) != 2 || players[0] == players[1] {
		return [2]string{}, ErrInternal
	}
	return [2]string{players[0], players[1]}, nil
}

type activeSlot struct {
	gameID  string
	userID  string
	matchID string
}

// validateCompleteActiveSlotSet runs before Cancel writes its event or terminal
// state. Reading by match_id deliberately includes wrong-game and extra-user
// rows so no corrupt slot can be silently left behind or deleted on behalf of
// somebody outside the match.
func validateCompleteActiveSlotSet(ctx context.Context, transaction *sql.Tx, gameID, matchID string, players [2]string, single bool) error {
	rows, err := transaction.QueryContext(ctx, `
SELECT game_id,user_id,match_id
FROM active_game_slots
WHERE match_id=?
ORDER BY game_id,user_id`, matchID)
	if err != nil {
		return matchDatabaseError(ctx, err)
	}
	defer rows.Close()
	var slots []activeSlot
	for rows.Next() {
		var slot activeSlot
		if err := rows.Scan(&slot.gameID, &slot.userID, &slot.matchID); err != nil {
			return matchDatabaseError(ctx, err)
		}
		slots = append(slots, slot)
	}
	if err := rows.Err(); err != nil {
		return matchDatabaseError(ctx, err)
	}
	if !single {
		if len(slots) != 0 {
			return ErrInternal
		}
		return nil
	}
	if len(slots) != 2 {
		return ErrInternal
	}
	expectedUsers := map[string]bool{players[0]: false, players[1]: false}
	for _, slot := range slots {
		seen, expected := expectedUsers[slot.userID]
		if !expected || seen || slot.gameID != gameID || slot.matchID != matchID {
			return ErrInternal
		}
		expectedUsers[slot.userID] = true
	}
	if !expectedUsers[players[0]] || !expectedUsers[players[1]] {
		return ErrInternal
	}
	return nil
}

func (service *Service) randomColors() (Color, Color, error) {
	service.randomMu.Lock()
	defer service.randomMu.Unlock()
	var colorByte [1]byte
	if _, err := io.ReadFull(service.random, colorByte[:]); err != nil {
		return "", "", err
	}
	if colorByte[0]&1 == 0 {
		return ColorBlack, ColorWhite, nil
	}
	return ColorWhite, ColorBlack, nil
}

func singleActiveMatch(rules games.Rules) bool {
	policy, ok := rules.(games.SingleActiveMatchPolicy)
	return ok && policy.SingleActiveMatchPerUser()
}

func configureRules(template games.Rules, config json.RawMessage) (games.Rules, json.RawMessage, error) {
	configurator, configurable := template.(games.Configurator)
	if !configurable {
		if len(config) != 0 {
			return nil, nil, ErrInvalidRequest
		}
		return template, nil, nil
	}
	if len(config) == 0 || len(config) > 1024 || !utf8.Valid(config) {
		return nil, nil, ErrInvalidRequest
	}
	var compact bytes.Buffer
	if err := json.Compact(&compact, config); err != nil {
		return nil, nil, ErrInvalidRequest
	}
	normalized := append(json.RawMessage(nil), compact.Bytes()...)
	configured, err := configurator.Configure(normalized)
	if err != nil || configured == nil || configured.GameID() != template.GameID() || configured.PlayerLimit() != template.PlayerLimit() {
		return nil, nil, ErrInvalidRequest
	}
	return configured, normalized, nil
}

func rulesForMatch(template games.Rules, config json.RawMessage) (games.Rules, error) {
	rules, _, err := configureRules(template, config)
	if err != nil {
		return nil, ErrInternal
	}
	return rules, nil
}

func nullableJSON(value json.RawMessage) any {
	if len(value) == 0 {
		return nil
	}
	return string(value)
}

func affectedExactlyOne(result sql.Result) error {
	rows, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if rows != 1 {
		return ErrInternal
	}
	return nil
}

func isActiveSlotConflict(err error) bool {
	var sqliteErr *sqlite.Error
	if !errors.As(err, &sqliteErr) {
		return false
	}
	code := sqliteErr.Code()
	return (code == sqlite3.SQLITE_CONSTRAINT_PRIMARYKEY || code == sqlite3.SQLITE_CONSTRAINT_UNIQUE) &&
		strings.Contains(sqliteErr.Error(), "UNIQUE constraint failed: active_game_slots.game_id, active_game_slots.user_id")
}

type writeTransaction struct {
	*sql.Tx
	connection          *sql.Conn
	originalBusyTimeout int
	cancel              context.CancelFunc
}

func (service *Service) beginWriteTransaction(ctx context.Context) (*writeTransaction, error) {
	operationContext, cancel := context.WithTimeout(ctx, matchWriteLimit)
	for {
		connection, err := service.db.Conn(operationContext)
		if err != nil {
			cancel()
			return nil, matchBeginError(ctx, operationContext, err)
		}
		originalBusyTimeout, err := configureMatchConnection(operationContext, connection)
		if err != nil {
			_ = discardMatchConnection(connection)
			cancel()
			return nil, matchBeginError(ctx, operationContext, err)
		}
		transaction, err := connection.BeginTx(operationContext, nil)
		if err == nil {
			return &writeTransaction{
				Tx:                  transaction,
				connection:          connection,
				originalBusyTimeout: originalBusyTimeout,
				cancel:              cancel,
			}, nil
		}
		failed := &writeTransaction{connection: connection, originalBusyTimeout: originalBusyTimeout}
		_ = failed.release()
		if !isSQLiteBusy(err) {
			cancel()
			return nil, matchBeginError(ctx, operationContext, err)
		}
		retry := time.NewTimer(time.Millisecond)
		select {
		case <-operationContext.Done():
			retry.Stop()
			cancel()
			return nil, matchBeginError(ctx, operationContext, operationContext.Err())
		case <-retry.C:
		}
	}
}

func configureMatchConnection(ctx context.Context, connection *sql.Conn) (int, error) {
	var originalBusyTimeout int
	if err := connection.QueryRowContext(ctx, `PRAGMA busy_timeout`).Scan(&originalBusyTimeout); err != nil {
		return 0, err
	}
	busyMilliseconds := int(matchSQLiteBusySlice / time.Millisecond)
	if _, err := connection.ExecContext(ctx, `PRAGMA busy_timeout = `+strconv.Itoa(busyMilliseconds)); err != nil {
		return 0, err
	}
	return originalBusyTimeout, nil
}

func (transaction *writeTransaction) release() error {
	if transaction.cancel != nil {
		transaction.cancel()
	}
	cleanupContext, cancel := context.WithTimeout(context.Background(), matchConnectionCleanLimit)
	defer cancel()
	if transaction.connection == nil {
		return nil
	}
	_, restoreErr := transaction.connection.ExecContext(cleanupContext, `PRAGMA busy_timeout = `+strconv.Itoa(transaction.originalBusyTimeout))
	if restoreErr != nil {
		return errors.Join(restoreErr, discardMatchConnection(transaction.connection))
	}
	return transaction.connection.Close()
}

func discardMatchConnection(connection *sql.Conn) error {
	if connection == nil {
		return nil
	}
	rawErr := connection.Raw(func(any) error { return driver.ErrBadConn })
	closeErr := connection.Close()
	if errors.Is(rawErr, driver.ErrBadConn) {
		rawErr = nil
	}
	if errors.Is(closeErr, sql.ErrConnDone) {
		closeErr = nil
	}
	return errors.Join(rawErr, closeErr)
}

func isSQLiteBusy(err error) bool {
	var sqliteErr *sqlite.Error
	return errors.As(err, &sqliteErr) && sqliteErr.Code()&0xff == matchSQLiteBusyCode
}

func matchBeginError(callerContext, operationContext context.Context, err error) error {
	if callerErr := callerContext.Err(); callerErr != nil {
		return callerErr
	}
	if operationContext.Err() != nil {
		return diagnostics.Wrap(ErrInternal, err)
	}
	return matchDatabaseError(callerContext, err)
}

func matchDatabaseError(ctx context.Context, err error) error {
	if contextErr := ctx.Err(); contextErr != nil {
		return contextErr
	}
	if errors.Is(err, context.Canceled) {
		return context.Canceled
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return context.DeadlineExceeded
	}
	return diagnostics.Wrap(ErrInternal, err)
}
