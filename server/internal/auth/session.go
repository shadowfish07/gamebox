package auth

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"me.zqydev/gamebox/server/internal/users"
)

const (
	accessTokenLifetime          = 15 * time.Minute
	refreshTokenLifetime         = 30 * 24 * time.Hour
	refreshTokenEntropyBytes     = 32
	maximumAccessTokenTextBytes  = 4096
	maximumRefreshTokenTextBytes = 512
	maximumUserIDTextBytes       = 128
	accessTokenIssuer            = "gamebox"
)

// Session contains the only plaintext refresh credential returned by the
// service. Callers must persist it securely; the database stores its hash.
type Session struct {
	User             users.User
	AccessToken      string
	AccessExpiresAt  time.Time
	RefreshToken     string
	RefreshExpiresAt time.Time
}

// String deliberately excludes both bearer credentials so ordinary logging
// and assertion formatting cannot disclose them.
func (session Session) String() string {
	return fmt.Sprintf("Session{UserID:%q Nickname:%q AccessExpiresAt:%s RefreshExpiresAt:%s AccessToken:<redacted> RefreshToken:<redacted>}",
		session.User.ID, session.User.Nickname, session.AccessExpiresAt.UTC().Format(time.RFC3339), session.RefreshExpiresAt.UTC().Format(time.RFC3339))
}

// GoString keeps %#v as safe as %v and %+v.
func (session Session) GoString() string {
	return session.String()
}

// AccessIdentity is the authenticated identity carried by a valid access JWT.
type AccessIdentity struct {
	UserID string
}

// Issue creates a new access/refresh pair for an enabled user.
func (service *Service) Issue(ctx context.Context, userID string) (_ Session, err error) {
	if ctx == nil || userID == "" || len(userID) > maximumUserIDTextBytes {
		return Session{}, ErrUnauthorized
	}
	transaction, beginErr := service.beginWriteTransaction(ctx)
	if beginErr != nil {
		return Session{}, beginErr
	}
	defer func() {
		if rollbackErr := transaction.Rollback(); rollbackErr != nil && !errors.Is(rollbackErr, sql.ErrTxDone) && err == nil {
			err = databaseError(ctx, rollbackErr)
		}
		_ = transaction.release()
	}()

	var user users.User
	queryErr := transaction.QueryRowContext(ctx, `
SELECT id, nickname
FROM users
WHERE id = ? AND enabled = 1`, userID).Scan(&user.ID, &user.Nickname)
	if errors.Is(queryErr, sql.ErrNoRows) {
		return Session{}, ErrUnauthorized
	}
	if queryErr != nil {
		return Session{}, databaseError(ctx, queryErr)
	}

	session, materialErr := service.newSession(user)
	if materialErr != nil {
		return Session{}, materialErr
	}
	refreshHash, hashErr := HashRefreshToken(service.pepper, session.RefreshToken)
	if hashErr != nil {
		return Session{}, ErrInternal
	}
	_, insertErr := transaction.ExecContext(ctx, `
INSERT INTO refresh_tokens(token_hash, user_id, expires_at, created_at)
VALUES (?, ?, ?, ?)`, refreshHash, user.ID, session.RefreshExpiresAt.Unix(), sessionAccessIssuedAt(session).Unix())
	if insertErr != nil {
		return Session{}, databaseError(ctx, insertErr)
	}
	if commitErr := service.commit(transaction); commitErr != nil {
		return Session{}, databaseError(ctx, commitErr)
	}
	return session, nil
}

// Refresh atomically revokes one refresh token and inserts its successor. The
// conditional update is the single-use gate; a concurrent loser gets the same
// fixed unauthorized error as every other invalid credential.
func (service *Service) Refresh(ctx context.Context, rawRefreshToken string) (_ Session, err error) {
	if ctx == nil || !validRefreshTokenText(rawRefreshToken) {
		return Session{}, ErrUnauthorized
	}
	refreshHash, hashErr := HashRefreshToken(service.pepper, rawRefreshToken)
	if hashErr != nil {
		return Session{}, ErrUnauthorized
	}
	transaction, beginErr := service.beginWriteTransaction(ctx)
	if beginErr != nil {
		return Session{}, beginErr
	}
	defer func() {
		if rollbackErr := transaction.Rollback(); rollbackErr != nil && !errors.Is(rollbackErr, sql.ErrTxDone) && err == nil {
			err = databaseError(ctx, rollbackErr)
		}
		_ = transaction.release()
	}()

	var user users.User
	queryErr := transaction.QueryRowContext(ctx, `
SELECT refresh_tokens.user_id, users.nickname
FROM refresh_tokens
JOIN users ON users.id = refresh_tokens.user_id
WHERE refresh_tokens.token_hash = ?`, refreshHash).Scan(&user.ID, &user.Nickname)
	if errors.Is(queryErr, sql.ErrNoRows) {
		return Session{}, ErrUnauthorized
	}
	if queryErr != nil {
		return Session{}, databaseError(ctx, queryErr)
	}
	nowUnix := service.clock.Now().UTC().Unix()
	result, updateErr := transaction.ExecContext(ctx, `
UPDATE refresh_tokens
SET revoked_at = ?
WHERE token_hash = ?
  AND user_id = ?
  AND revoked_at IS NULL
  AND expires_at > ?
  AND created_at <= ?
  AND EXISTS (
    SELECT 1 FROM users
    WHERE users.id = refresh_tokens.user_id AND users.enabled = 1
  )`, nowUnix, refreshHash, user.ID, nowUnix, nowUnix)
	if updateErr != nil {
		return Session{}, databaseError(ctx, updateErr)
	}
	affected, rowsErr := result.RowsAffected()
	if rowsErr != nil {
		return Session{}, databaseError(ctx, rowsErr)
	}
	if affected != 1 {
		return Session{}, ErrUnauthorized
	}

	session, materialErr := service.newSessionAt(user, nowUnix)
	if materialErr != nil {
		return Session{}, materialErr
	}
	newHash, newHashErr := HashRefreshToken(service.pepper, session.RefreshToken)
	if newHashErr != nil {
		return Session{}, ErrInternal
	}
	_, insertErr := transaction.ExecContext(ctx, `
INSERT INTO refresh_tokens(token_hash, user_id, expires_at, created_at)
VALUES (?, ?, ?, ?)`, newHash, user.ID, session.RefreshExpiresAt.Unix(), nowUnix)
	if insertErr != nil {
		return Session{}, databaseError(ctx, insertErr)
	}
	if commitErr := service.commit(transaction); commitErr != nil {
		return Session{}, databaseError(ctx, commitErr)
	}
	return session, nil
}

func validRefreshTokenText(raw string) bool {
	if len(raw) == 0 || len(raw) > maximumRefreshTokenTextBytes {
		return false
	}
	decoded, err := base64.RawURLEncoding.DecodeString(raw)
	return err == nil && len(decoded) == refreshTokenEntropyBytes
}

func (service *Service) newSession(user users.User) (Session, error) {
	return service.newSessionAt(user, service.clock.Now().UTC().Unix())
}

func (service *Service) newSessionAt(user users.User, nowUnix int64) (Session, error) {
	refreshToken, tokenErr := randomToken(refreshTokenEntropyBytes, service.entropy)
	if tokenErr != nil {
		return Session{}, ErrInternal
	}
	issuedAt := time.Unix(nowUnix, 0).UTC()
	accessExpiresAt := issuedAt.Add(accessTokenLifetime)
	claims := jwt.RegisteredClaims{
		Issuer:    accessTokenIssuer,
		Subject:   user.ID,
		IssuedAt:  jwt.NewNumericDate(issuedAt),
		ExpiresAt: jwt.NewNumericDate(accessExpiresAt),
	}
	accessToken, signErr := jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString(service.jwtSecret)
	if signErr != nil {
		return Session{}, ErrInternal
	}
	return Session{
		User:             user,
		AccessToken:      accessToken,
		AccessExpiresAt:  accessExpiresAt,
		RefreshToken:     refreshToken,
		RefreshExpiresAt: issuedAt.Add(refreshTokenLifetime),
	}, nil
}

func sessionAccessIssuedAt(session Session) time.Time {
	return session.AccessExpiresAt.Add(-accessTokenLifetime)
}

// ParseAccess verifies a Gamebox access JWT with zero clock leeway. HS256 is
// the only accepted algorithm, expiration is exclusive, and future iat values
// (including those exposed by a wall-clock rollback) are rejected.
func (service *Service) ParseAccess(rawAccessToken string) (AccessIdentity, error) {
	if len(rawAccessToken) == 0 || len(rawAccessToken) > maximumAccessTokenTextBytes {
		return AccessIdentity{}, ErrUnauthorized
	}
	if !jwtJSONObjectsHaveUniqueKeys(rawAccessToken) {
		return AccessIdentity{}, ErrUnauthorized
	}
	claims := &jwt.RegisteredClaims{}
	parser := jwt.NewParser(
		jwt.WithValidMethods([]string{jwt.SigningMethodHS256.Alg()}),
		jwt.WithIssuer(accessTokenIssuer),
		jwt.WithExpirationRequired(),
		jwt.WithIssuedAt(),
		jwt.WithLeeway(0),
		jwt.WithTimeFunc(func() time.Time { return service.clock.Now().UTC() }),
		jwt.WithStrictDecoding(),
	)
	token, parseErr := parser.ParseWithClaims(rawAccessToken, claims, func(token *jwt.Token) (any, error) {
		if token.Method != jwt.SigningMethodHS256 {
			return nil, ErrUnauthorized
		}
		return service.jwtSecret, nil
	})
	if parseErr != nil || token == nil || !token.Valid || claims.Subject == "" || len(claims.Subject) > maximumUserIDTextBytes || claims.IssuedAt == nil || claims.ExpiresAt == nil {
		return AccessIdentity{}, ErrUnauthorized
	}
	if claims.ExpiresAt.Unix()-claims.IssuedAt.Unix() != int64(accessTokenLifetime/time.Second) {
		return AccessIdentity{}, ErrUnauthorized
	}
	return AccessIdentity{UserID: claims.Subject}, nil
}

const maximumJWTJSONDepth = 32

func jwtJSONObjectsHaveUniqueKeys(raw string) bool {
	segments := strings.Split(raw, ".")
	if len(segments) != 3 {
		return false
	}
	strictBase64 := base64.RawURLEncoding.Strict()
	for _, segment := range segments[:2] {
		document, err := strictBase64.DecodeString(segment)
		if err != nil || !uniqueJSONObject(document) {
			return false
		}
	}
	return true
}

func uniqueJSONObject(document []byte) bool {
	decoder := json.NewDecoder(bytes.NewReader(document))
	decoder.UseNumber()
	opening, err := decoder.Token()
	if err != nil || opening != json.Delim('{') || !consumeUniqueJSONObject(decoder, 1) {
		return false
	}
	_, err = decoder.Token()
	return errors.Is(err, io.EOF)
}

func consumeUniqueJSONObject(decoder *json.Decoder, depth int) bool {
	if depth > maximumJWTJSONDepth {
		return false
	}
	keys := make(map[string]struct{})
	for decoder.More() {
		keyToken, err := decoder.Token()
		key, ok := keyToken.(string)
		if err != nil || !ok {
			return false
		}
		if _, duplicate := keys[key]; duplicate {
			return false
		}
		keys[key] = struct{}{}
		if !consumeUniqueJSONValue(decoder, depth) {
			return false
		}
	}
	closing, err := decoder.Token()
	return err == nil && closing == json.Delim('}')
}

func consumeUniqueJSONValue(decoder *json.Decoder, depth int) bool {
	token, err := decoder.Token()
	if err != nil {
		return false
	}
	delimiter, compound := token.(json.Delim)
	if !compound {
		return true
	}
	switch delimiter {
	case '{':
		return consumeUniqueJSONObject(decoder, depth+1)
	case '[':
		if depth >= maximumJWTJSONDepth {
			return false
		}
		for decoder.More() {
			if !consumeUniqueJSONValue(decoder, depth+1) {
				return false
			}
		}
		closing, closeErr := decoder.Token()
		return closeErr == nil && closing == json.Delim(']')
	default:
		return false
	}
}
