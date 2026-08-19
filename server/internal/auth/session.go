package auth

import (
	"context"
	"database/sql"
	"encoding/base64"
	"errors"
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
