package auth

import (
	"bytes"
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"me.zqydev/gamebox/server/internal/clock"
)

const testJWTSecret = "test-only-jwt-secret-that-is-long-enough"

func insertSessionUser(t *testing.T, fixture authFixture, id, nickname string, enabled bool) {
	t.Helper()
	enabledValue := 0
	if enabled {
		enabledValue = 1
	}
	if _, err := fixture.db.Exec(`
INSERT INTO users(id, nickname, normalized_nickname, enabled, created_at, updated_at)
VALUES (?, ?, ?, ?, ?, ?)`, id, nickname, strings.ToLower(nickname), enabledValue, fixture.now.Unix(), fixture.now.Unix()); err != nil {
		t.Fatalf("insert session user: %v", err)
	}
}

func newSessionService(t *testing.T, fixture authFixture, serviceClock clock.Clock) *Service {
	t.Helper()
	service, err := NewService(fixture.db, serviceClock, ServiceConfig{
		JWTSecret:   []byte(testJWTSecret),
		TokenPepper: testPepper,
	})
	if err != nil {
		t.Fatalf("create session service: %v", err)
	}
	return service
}

func TestIssueSessionCreatesHS256AccessAndHashedRefreshToken(t *testing.T) {
	fixture := newAuthFixture(t)
	insertSessionUser(t, fixture, "user-session", "Alice", true)
	service := newSessionService(t, fixture, clock.NewFake(fixture.now))

	session, err := service.Issue(context.Background(), "user-session")
	if err != nil {
		t.Fatalf("Issue returned error: %v", err)
	}
	if session.User.ID != "user-session" || session.User.Nickname != "Alice" {
		t.Fatalf("Issue user = %+v", session.User)
	}
	issuedAt := time.Unix(fixture.now.UTC().Unix(), 0).UTC()
	if !session.AccessExpiresAt.Equal(issuedAt.Add(15 * time.Minute)) {
		t.Fatalf("access expiry = %v, want %v", session.AccessExpiresAt, issuedAt.Add(15*time.Minute))
	}
	if !session.RefreshExpiresAt.Equal(issuedAt.Add(30 * 24 * time.Hour)) {
		t.Fatalf("refresh expiry = %v, want %v", session.RefreshExpiresAt, issuedAt.Add(30*24*time.Hour))
	}
	decodedRefresh, err := base64.RawURLEncoding.DecodeString(session.RefreshToken)
	if err != nil || len(decodedRefresh) != 32 {
		t.Fatalf("refresh token has %d decoded bytes (decode error %v), want 32", len(decodedRefresh), err)
	}

	parsed, err := jwt.Parse(session.AccessToken, func(token *jwt.Token) (any, error) {
		if token.Method != jwt.SigningMethodHS256 {
			t.Fatalf("access signing method = %T/%q, want HS256", token.Method, token.Method.Alg())
		}
		return []byte(testJWTSecret), nil
	}, jwt.WithValidMethods([]string{"HS256"}), jwt.WithIssuer("gamebox"), jwt.WithExpirationRequired(), jwt.WithTimeFunc(func() time.Time { return fixture.now }))
	if err != nil || !parsed.Valid {
		t.Fatalf("parse issued access token: valid=%v err=%v", parsed.Valid, err)
	}
	claims := parsed.Claims.(jwt.MapClaims)
	if claims["sub"] != "user-session" || claims["iss"] != "gamebox" {
		t.Fatalf("access identity claims = %#v", claims)
	}
	if claims["iat"] != float64(issuedAt.Unix()) || claims["exp"] != float64(issuedAt.Add(15*time.Minute).Unix()) {
		t.Fatalf("access time claims = %#v, want Unix seconds", claims)
	}

	hash, err := HashRefreshToken(testPepper, session.RefreshToken)
	if err != nil {
		t.Fatalf("hash issued refresh: %v", err)
	}
	var storedHash, storedUser string
	var expiresAt, createdAt int64
	if err := fixture.db.QueryRow(`SELECT token_hash, user_id, expires_at, created_at FROM refresh_tokens`).Scan(&storedHash, &storedUser, &expiresAt, &createdAt); err != nil {
		t.Fatalf("read refresh row: %v", err)
	}
	if storedHash != hash || storedHash == session.RefreshToken || storedUser != "user-session" {
		t.Fatalf("stored refresh identity: expectedHash=%t plaintextAbsent=%t expectedUser=%t", storedHash == hash, storedHash != session.RefreshToken, storedUser == "user-session")
	}
	if expiresAt != session.RefreshExpiresAt.Unix() || createdAt != issuedAt.Unix() {
		t.Fatalf("stored refresh times = (%d, %d)", expiresAt, createdAt)
	}
	var plaintextRows int
	if err := fixture.db.QueryRow(`SELECT COUNT(*) FROM refresh_tokens WHERE token_hash = ?`, session.RefreshToken).Scan(&plaintextRows); err != nil {
		t.Fatalf("search refresh plaintext: %v", err)
	}
	if plaintextRows != 0 {
		t.Fatal("refresh token plaintext was stored")
	}
}

func TestParseAccessAllowsOnlyHS256GameboxAndEnforcesTimeBoundaries(t *testing.T) {
	fixture := newAuthFixture(t)
	insertSessionUser(t, fixture, "access-user", "Alice", true)
	fakeClock := clock.NewFake(fixture.now)
	service := newSessionService(t, fixture, fakeClock)
	session, err := service.Issue(context.Background(), "access-user")
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}

	identity, err := service.ParseAccess(session.AccessToken)
	if err != nil || identity.UserID != "access-user" {
		t.Fatalf("ParseAccess valid path: authenticated=%t expectedUser=%t", err == nil, identity.UserID == "access-user")
	}

	tests := []struct {
		name  string
		token func() string
	}{
		{
			name: "HS384 algorithm confusion",
			token: func() string {
				token := jwt.NewWithClaims(jwt.SigningMethodHS384, jwt.RegisteredClaims{
					Issuer: "gamebox", Subject: "access-user",
					IssuedAt: jwt.NewNumericDate(fixture.now), ExpiresAt: jwt.NewNumericDate(fixture.now.Add(time.Hour)),
				})
				signed, _ := token.SignedString([]byte(testJWTSecret))
				return signed
			},
		},
		{
			name: "none algorithm",
			token: func() string {
				token := jwt.NewWithClaims(jwt.SigningMethodNone, jwt.RegisteredClaims{
					Issuer: "gamebox", Subject: "access-user",
					IssuedAt: jwt.NewNumericDate(fixture.now), ExpiresAt: jwt.NewNumericDate(fixture.now.Add(time.Hour)),
				})
				signed, _ := token.SignedString(jwt.UnsafeAllowNoneSignatureType)
				return signed
			},
		},
		{
			name: "wrong issuer",
			token: func() string {
				token := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.RegisteredClaims{
					Issuer: "other", Subject: "access-user",
					IssuedAt: jwt.NewNumericDate(fixture.now), ExpiresAt: jwt.NewNumericDate(fixture.now.Add(time.Hour)),
				})
				signed, _ := token.SignedString([]byte(testJWTSecret))
				return signed
			},
		},
		{
			name: "missing subject",
			token: func() string {
				token := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.RegisteredClaims{
					Issuer: "gamebox", IssuedAt: jwt.NewNumericDate(fixture.now), ExpiresAt: jwt.NewNumericDate(fixture.now.Add(time.Hour)),
				})
				signed, _ := token.SignedString([]byte(testJWTSecret))
				return signed
			},
		},
		{
			name: "missing issued at",
			token: func() string {
				token := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.RegisteredClaims{
					Issuer: "gamebox", Subject: "access-user", ExpiresAt: jwt.NewNumericDate(fixture.now.Add(15 * time.Minute)),
				})
				signed, _ := token.SignedString([]byte(testJWTSecret))
				return signed
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			raw := test.token()
			identity, err := service.ParseAccess(raw)
			if identity != (AccessIdentity{}) || !errors.Is(err, ErrUnauthorized) || err.Error() != ErrUnauthorized.Error() || strings.Contains(err.Error(), raw) {
				t.Fatalf("ParseAccess rejection: zeroIdentity=%t unauthorized=%t fixedError=%t redacted=%t",
					identity == (AccessIdentity{}), errors.Is(err, ErrUnauthorized), err != nil && err.Error() == ErrUnauthorized.Error(), err != nil && !strings.Contains(err.Error(), raw))
			}
		})
	}

	fakeClock.Advance(15 * time.Minute)
	if identity, err := service.ParseAccess(session.AccessToken); identity != (AccessIdentity{}) || !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("ParseAccess exact expiration: zeroIdentity=%t unauthorized=%t", identity == (AccessIdentity{}), errors.Is(err, ErrUnauthorized))
	}

	earlierService := newSessionService(t, fixture, clock.NewFake(fixture.now.Add(-time.Second)))
	if identity, err := earlierService.ParseAccess(session.AccessToken); identity != (AccessIdentity{}) || !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("ParseAccess clock rollback: zeroIdentity=%t unauthorized=%t", identity == (AccessIdentity{}), errors.Is(err, ErrUnauthorized))
	}
}

func TestServiceDefensivelyCopiesJWTSecret(t *testing.T) {
	fixture := newAuthFixture(t)
	insertSessionUser(t, fixture, "copy-user", "Alice", true)
	secret := []byte(testJWTSecret)
	service, err := NewService(fixture.db, clock.NewFake(fixture.now), ServiceConfig{JWTSecret: secret, TokenPepper: testPepper})
	if err != nil {
		t.Fatalf("NewService: %v", err)
	}
	for index := range secret {
		secret[index] = 'x'
	}
	session, err := service.Issue(context.Background(), "copy-user")
	if err != nil {
		t.Fatalf("Issue after caller mutated secret: %v", err)
	}
	if _, err := service.ParseAccess(session.AccessToken); err != nil {
		t.Fatalf("ParseAccess after caller mutated secret: %v", err)
	}
}

func TestRefreshRotatesAtomicallyAndReturnsEnabledUser(t *testing.T) {
	fixture := newAuthFixture(t)
	insertSessionUser(t, fixture, "rotate-user", "Alice", true)
	service := newSessionService(t, fixture, clock.NewFake(fixture.now))
	original, err := service.Issue(context.Background(), "rotate-user")
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}

	rotated, err := service.Refresh(context.Background(), original.RefreshToken)
	if err != nil {
		t.Fatalf("Refresh: %v", err)
	}
	if rotated.RefreshToken == original.RefreshToken || rotated.User != original.User {
		t.Fatalf("rotated session contract: tokenRotated=%t sameUser=%t", rotated.RefreshToken != original.RefreshToken, rotated.User == original.User)
	}
	oldHash, _ := HashRefreshToken(testPepper, original.RefreshToken)
	newHash, _ := HashRefreshToken(testPepper, rotated.RefreshToken)
	var oldRevoked sql.NullInt64
	if err := fixture.db.QueryRow(`SELECT revoked_at FROM refresh_tokens WHERE token_hash = ?`, oldHash).Scan(&oldRevoked); err != nil {
		t.Fatalf("read old refresh: %v", err)
	}
	if !oldRevoked.Valid || oldRevoked.Int64 != fixture.now.Unix() {
		t.Fatalf("old revoked_at = %v, want %d", oldRevoked, fixture.now.Unix())
	}
	var newRevoked sql.NullInt64
	if err := fixture.db.QueryRow(`SELECT revoked_at FROM refresh_tokens WHERE token_hash = ?`, newHash).Scan(&newRevoked); err != nil {
		t.Fatalf("read new refresh: %v", err)
	}
	if newRevoked.Valid {
		t.Fatalf("new refresh already revoked at %d", newRevoked.Int64)
	}
	if _, err := service.Refresh(context.Background(), original.RefreshToken); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("reusing old refresh error = %v, want unauthorized", err)
	}
	if _, err := service.Refresh(context.Background(), rotated.RefreshToken); err != nil {
		t.Fatalf("new refresh token is not valid: %v", err)
	}
}

func TestRefreshConcurrentUseAllowsExactlyOneRotation(t *testing.T) {
	fixture := newAuthFixture(t)
	insertSessionUser(t, fixture, "concurrent-user", "Alice", true)
	service := newSessionService(t, fixture, clock.NewFake(fixture.now))
	original, err := service.Issue(context.Background(), "concurrent-user")
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}

	start := make(chan struct{})
	results := make(chan struct {
		session Session
		err     error
	}, 2)
	var calls sync.WaitGroup
	for range 2 {
		calls.Add(1)
		go func() {
			defer calls.Done()
			<-start
			session, err := service.Refresh(context.Background(), original.RefreshToken)
			results <- struct {
				session Session
				err     error
			}{session, err}
		}()
	}
	close(start)
	calls.Wait()
	close(results)

	successes, unauthorized := 0, 0
	for result := range results {
		switch {
		case result.err == nil:
			successes++
			if result.session.RefreshToken == "" {
				t.Fatal("successful concurrent refresh returned no token")
			}
		case errors.Is(result.err, ErrUnauthorized):
			unauthorized++
			if result.err.Error() != ErrUnauthorized.Error() || result.session != (Session{}) {
				t.Fatalf("losing refresh: zeroSession=%t fixedError=%t", result.session == (Session{}), result.err.Error() == ErrUnauthorized.Error())
			}
		default:
			t.Fatalf("concurrent Refresh error = %v", result.err)
		}
	}
	if successes != 1 || unauthorized != 1 {
		t.Fatalf("concurrent results = %d success, %d unauthorized; want one each", successes, unauthorized)
	}
	var rows int
	if err := fixture.db.QueryRow(`SELECT COUNT(*) FROM refresh_tokens`).Scan(&rows); err != nil {
		t.Fatalf("count refresh rows: %v", err)
	}
	if rows != 2 {
		t.Fatalf("refresh rows = %d, want original plus exactly one successor", rows)
	}
}

func TestRefreshRejectsDisabledExpiredRevokedUnknownRollbackAndOversizedTokens(t *testing.T) {
	fixture := newAuthFixture(t)
	insertSessionUser(t, fixture, "reject-user", "Alice", true)
	service := newSessionService(t, fixture, clock.NewFake(fixture.now))

	makeToken := func(t *testing.T) Session {
		t.Helper()
		session, err := service.Issue(context.Background(), "reject-user")
		if err != nil {
			t.Fatalf("Issue: %v", err)
		}
		return session
	}
	disabled := makeToken(t)
	if _, err := fixture.db.Exec(`UPDATE users SET enabled = 0 WHERE id = 'reject-user'`); err != nil {
		t.Fatalf("disable user: %v", err)
	}
	tests := []struct {
		name  string
		raw   string
		setup func()
	}{
		{name: "disabled user", raw: disabled.RefreshToken},
		{name: "unknown", raw: strings.Repeat("A", 43)},
		{name: "empty", raw: ""},
		{name: "oversized", raw: strings.Repeat("x", maximumRefreshTokenTextBytes+1)},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			before := refreshRowCount(t, fixture.db)
			session, err := service.Refresh(context.Background(), test.raw)
			if session != (Session{}) || !errors.Is(err, ErrUnauthorized) || err.Error() != ErrUnauthorized.Error() || (test.raw != "" && strings.Contains(err.Error(), test.raw)) {
				t.Fatalf("Refresh rejection: zeroSession=%t unauthorized=%t fixedError=%t redacted=%t",
					session == (Session{}), errors.Is(err, ErrUnauthorized), err != nil && err.Error() == ErrUnauthorized.Error(), err != nil && !strings.Contains(err.Error(), test.raw))
			}
			if after := refreshRowCount(t, fixture.db); after != before {
				t.Fatalf("rejected refresh changed row count from %d to %d", before, after)
			}
		})
	}

	if _, err := fixture.db.Exec(`UPDATE users SET enabled = 1 WHERE id = 'reject-user'`); err != nil {
		t.Fatalf("enable user: %v", err)
	}
	expired := makeToken(t)
	expiredHash, _ := HashRefreshToken(testPepper, expired.RefreshToken)
	if _, err := fixture.db.Exec(`UPDATE refresh_tokens SET expires_at = ? WHERE token_hash = ?`, fixture.now.Unix(), expiredHash); err != nil {
		t.Fatalf("expire token: %v", err)
	}
	revoked := makeToken(t)
	revokedHash, _ := HashRefreshToken(testPepper, revoked.RefreshToken)
	if _, err := fixture.db.Exec(`UPDATE refresh_tokens SET revoked_at = ? WHERE token_hash = ?`, fixture.now.Unix(), revokedHash); err != nil {
		t.Fatalf("revoke token: %v", err)
	}
	rollback := makeToken(t)
	earlierService := newSessionService(t, fixture, clock.NewFake(fixture.now.Add(-time.Second)))
	for name, candidate := range map[string]string{"expired": expired.RefreshToken, "revoked": revoked.RefreshToken, "clock rollback": rollback.RefreshToken} {
		t.Run(name, func(t *testing.T) {
			candidateService := service
			if name == "clock rollback" {
				candidateService = earlierService
			}
			before := refreshRowCount(t, fixture.db)
			if session, err := candidateService.Refresh(context.Background(), candidate); session != (Session{}) || !errors.Is(err, ErrUnauthorized) || err.Error() != ErrUnauthorized.Error() {
				t.Fatalf("Refresh state rejection: zeroSession=%t unauthorized=%t fixedError=%t",
					session == (Session{}), errors.Is(err, ErrUnauthorized), err != nil && err.Error() == ErrUnauthorized.Error())
			}
			if after := refreshRowCount(t, fixture.db); after != before {
				t.Fatalf("rejected refresh changed row count from %d to %d", before, after)
			}
		})
	}
}

func TestIssueAndRefreshErrorsAreFixedAndSecretFree(t *testing.T) {
	fixture := newAuthFixture(t)
	insertSessionUser(t, fixture, "error-user", "Alice", false)
	service := newSessionService(t, fixture, clock.NewFake(fixture.now))
	if session, err := service.Issue(context.Background(), "error-user"); session != (Session{}) || !errors.Is(err, ErrUnauthorized) || err.Error() != ErrUnauthorized.Error() {
		t.Fatalf("Issue disabled: zeroSession=%t unauthorized=%t fixedError=%t", session == (Session{}), errors.Is(err, ErrUnauthorized), err != nil && err.Error() == ErrUnauthorized.Error())
	}
	if session, err := service.Issue(context.Background(), "missing-secret-user-id"); session != (Session{}) || !errors.Is(err, ErrUnauthorized) || strings.Contains(err.Error(), "missing-secret-user-id") {
		t.Fatalf("Issue missing: zeroSession=%t unauthorized=%t redacted=%t", session == (Session{}), errors.Is(err, ErrUnauthorized), err != nil && !strings.Contains(err.Error(), "missing-secret-user-id"))
	}

	if err := fixture.db.Close(); err != nil {
		t.Fatalf("close database: %v", err)
	}
	secret := strings.Repeat("A", 43)
	if session, err := service.Refresh(context.Background(), secret); session != (Session{}) || !errors.Is(err, ErrInternal) || err.Error() != ErrInternal.Error() || strings.Contains(err.Error(), secret) || strings.Contains(strings.ToLower(err.Error()), "sql") {
		t.Fatalf("Refresh database error: zeroSession=%t internal=%t fixedError=%t redacted=%t",
			session == (Session{}), errors.Is(err, ErrInternal), err != nil && err.Error() == ErrInternal.Error(), err != nil && !strings.Contains(err.Error(), secret) && !strings.Contains(strings.ToLower(err.Error()), "sql"))
	}
}

func refreshRowCount(t *testing.T, db *sql.DB) int {
	t.Helper()
	var count int
	if err := db.QueryRow(`SELECT COUNT(*) FROM refresh_tokens`).Scan(&count); err != nil {
		t.Fatalf("count refresh rows: %v", err)
	}
	return count
}

func TestIssueRefreshCollisionFailsWithoutReturningPlaintext(t *testing.T) {
	fixture := newAuthFixture(t)
	insertSessionUser(t, fixture, "collision-user", "Alice", true)
	service := newSessionService(t, fixture, clock.NewFake(fixture.now))
	service.entropy = strings.NewReader(strings.Repeat("\x00", 64))
	first, err := service.Issue(context.Background(), "collision-user")
	if err != nil {
		t.Fatalf("first Issue: %v", err)
	}
	second, err := service.Issue(context.Background(), "collision-user")
	if second != (Session{}) || !errors.Is(err, ErrInternal) || err.Error() != ErrInternal.Error() || strings.Contains(err.Error(), first.RefreshToken) {
		t.Fatalf("colliding Issue: zeroSession=%t internal=%t fixedError=%t redacted=%t",
			second == (Session{}), errors.Is(err, ErrInternal), err != nil && err.Error() == ErrInternal.Error(), err != nil && !strings.Contains(err.Error(), first.RefreshToken))
	}
	if rows := refreshRowCount(t, fixture.db); rows != 1 {
		t.Fatalf("collision stored %d refresh rows, want 1", rows)
	}
}

func TestRefreshGenerationAndCollisionFailuresRollbackOldRevocation(t *testing.T) {
	for _, test := range []struct {
		name    string
		entropy func(t *testing.T, original Session) *bytes.Reader
	}{
		{
			name: "successor collides with original hash",
			entropy: func(t *testing.T, original Session) *bytes.Reader {
				t.Helper()
				decoded, err := base64.RawURLEncoding.DecodeString(original.RefreshToken)
				if err != nil {
					t.Fatalf("decode original refresh: %v", err)
				}
				return bytes.NewReader(decoded)
			},
		},
		{
			name: "entropy source fails",
			entropy: func(_ *testing.T, _ Session) *bytes.Reader {
				return bytes.NewReader(nil)
			},
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			fixture := newAuthFixture(t)
			insertSessionUser(t, fixture, "rollback-user", "Alice", true)
			service := newSessionService(t, fixture, clock.NewFake(fixture.now))
			original, err := service.Issue(context.Background(), "rollback-user")
			if err != nil {
				t.Fatalf("Issue: %v", err)
			}
			service.entropy = test.entropy(t, original)

			failed, err := service.Refresh(context.Background(), original.RefreshToken)
			if failed != (Session{}) || !errors.Is(err, ErrInternal) || err.Error() != ErrInternal.Error() || strings.Contains(err.Error(), original.RefreshToken) {
				t.Fatalf("failed Refresh: zeroSession=%t internal=%t fixedError=%t redacted=%t",
					failed == (Session{}), errors.Is(err, ErrInternal), err != nil && err.Error() == ErrInternal.Error(), err != nil && !strings.Contains(err.Error(), original.RefreshToken))
			}
			if rows := refreshRowCount(t, fixture.db); rows != 1 {
				t.Fatalf("failed Refresh stored %d rows, want original only", rows)
			}
			originalHash, _ := HashRefreshToken(testPepper, original.RefreshToken)
			var revokedAt sql.NullInt64
			if err := fixture.db.QueryRow(`SELECT revoked_at FROM refresh_tokens WHERE token_hash = ?`, originalHash).Scan(&revokedAt); err != nil {
				t.Fatalf("read original after rollback: %v", err)
			}
			if revokedAt.Valid {
				t.Fatalf("failed Refresh left original revoked at %d", revokedAt.Int64)
			}

			service.entropy = rand.Reader
			if _, err := service.Refresh(context.Background(), original.RefreshToken); err != nil {
				t.Fatalf("original token was not valid after rollback: %v", err)
			}
		})
	}
}

func TestSessionCommitFailuresReturnNothingAndRollbackAllTokenWrites(t *testing.T) {
	fixture := newAuthFixture(t)
	insertSessionUser(t, fixture, "commit-user", "Alice", true)
	service := newSessionService(t, fixture, clock.NewFake(fixture.now))
	service.commit = func(*writeTransaction) error {
		return errors.New("private SQL commit detail")
	}

	issued, err := service.Issue(context.Background(), "commit-user")
	if issued != (Session{}) || !errors.Is(err, ErrInternal) || err.Error() != ErrInternal.Error() || strings.Contains(strings.ToLower(err.Error()), "sql") {
		t.Fatalf("Issue commit failure: zeroSession=%t internal=%t fixedError=%t redacted=%t",
			issued == (Session{}), errors.Is(err, ErrInternal), err != nil && err.Error() == ErrInternal.Error(), err != nil && !strings.Contains(strings.ToLower(err.Error()), "sql"))
	}
	if rows := refreshRowCount(t, fixture.db); rows != 0 {
		t.Fatalf("failed Issue commit left %d refresh rows", rows)
	}

	service.commit = commitWriteTransaction
	original, err := service.Issue(context.Background(), "commit-user")
	if err != nil {
		t.Fatalf("Issue for rotation: %v", err)
	}
	service.commit = func(*writeTransaction) error {
		return errors.New("private SQL commit detail")
	}
	rotated, err := service.Refresh(context.Background(), original.RefreshToken)
	if rotated != (Session{}) || !errors.Is(err, ErrInternal) || err.Error() != ErrInternal.Error() || strings.Contains(strings.ToLower(err.Error()), "sql") {
		t.Fatalf("Refresh commit failure: zeroSession=%t internal=%t fixedError=%t redacted=%t",
			rotated == (Session{}), errors.Is(err, ErrInternal), err != nil && err.Error() == ErrInternal.Error(), err != nil && !strings.Contains(strings.ToLower(err.Error()), "sql"))
	}
	if rows := refreshRowCount(t, fixture.db); rows != 1 {
		t.Fatalf("failed Refresh commit left %d rows, want original only", rows)
	}
	originalHash, _ := HashRefreshToken(testPepper, original.RefreshToken)
	var revokedAt sql.NullInt64
	if err := fixture.db.QueryRow(`SELECT revoked_at FROM refresh_tokens WHERE token_hash = ?`, originalHash).Scan(&revokedAt); err != nil {
		t.Fatalf("read original after commit rollback: %v", err)
	}
	if revokedAt.Valid {
		t.Fatalf("failed Refresh commit left original revoked at %d", revokedAt.Int64)
	}
	service.commit = commitWriteTransaction
	if _, err := service.Refresh(context.Background(), original.RefreshToken); err != nil {
		t.Fatalf("original token was not valid after commit rollback: %v", err)
	}
}

func TestAccessInputLengthLimitReturnsFixedError(t *testing.T) {
	fixture := newAuthFixture(t)
	service := newSessionService(t, fixture, clock.NewFake(fixture.now))
	raw := strings.Repeat("private-jwt", maximumAccessTokenTextBytes)
	identity, err := service.ParseAccess(raw)
	if identity != (AccessIdentity{}) || !errors.Is(err, ErrUnauthorized) || err.Error() != ErrUnauthorized.Error() || strings.Contains(err.Error(), raw) {
		t.Fatalf("oversized ParseAccess: zeroIdentity=%t unauthorized=%t fixedError=%t redacted=%t",
			identity == (AccessIdentity{}), errors.Is(err, ErrUnauthorized), err != nil && err.Error() == ErrUnauthorized.Error(), err != nil && !strings.Contains(err.Error(), raw))
	}
}

func TestSessionConfigurationRejectsWeakOrMissingDependencies(t *testing.T) {
	fixture := newAuthFixture(t)
	tests := []struct {
		name   string
		db     *sql.DB
		clock  clock.Clock
		config ServiceConfig
	}{
		{name: "nil database", clock: clock.NewFake(fixture.now), config: ServiceConfig{JWTSecret: []byte(testJWTSecret), TokenPepper: testPepper}},
		{name: "nil clock", db: fixture.db, config: ServiceConfig{JWTSecret: []byte(testJWTSecret), TokenPepper: testPepper}},
		{name: "short JWT secret", db: fixture.db, clock: clock.NewFake(fixture.now), config: ServiceConfig{JWTSecret: []byte("short"), TokenPepper: testPepper}},
		{name: "short pepper", db: fixture.db, clock: clock.NewFake(fixture.now), config: ServiceConfig{JWTSecret: []byte(testJWTSecret), TokenPepper: "short"}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			service, err := NewService(test.db, test.clock, test.config)
			if service != nil || !errors.Is(err, ErrInvalidConfiguration) || err.Error() != ErrInvalidConfiguration.Error() {
				t.Fatalf("NewService rejection: nilService=%t invalidConfiguration=%t fixedError=%t", service == nil, errors.Is(err, ErrInvalidConfiguration), err != nil && err.Error() == ErrInvalidConfiguration.Error())
			}
		})
	}
}

func TestRefreshHonorsContextCancellationWithoutChangingToken(t *testing.T) {
	fixture := newAuthFixture(t)
	insertSessionUser(t, fixture, "blocked-refresh-user", "Alice", true)
	service := newSessionService(t, fixture, clock.NewFake(fixture.now))
	session, err := service.Issue(context.Background(), "blocked-refresh-user")
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}
	locker, err := fixture.db.Conn(context.Background())
	if err != nil {
		t.Fatalf("reserve lock connection: %v", err)
	}
	defer locker.Close()
	if _, err := locker.ExecContext(context.Background(), `BEGIN IMMEDIATE`); err != nil {
		t.Fatalf("acquire write lock: %v", err)
	}
	defer locker.ExecContext(context.Background(), `ROLLBACK`)

	ctx, cancel := context.WithTimeout(context.Background(), 75*time.Millisecond)
	defer cancel()
	started := time.Now()
	rotated, err := service.Refresh(ctx, session.RefreshToken)
	if rotated != (Session{}) || !errors.Is(err, context.DeadlineExceeded) || time.Since(started) > 750*time.Millisecond {
		t.Fatalf("blocked Refresh: zeroSession=%t deadline=%t timely=%t", rotated == (Session{}), errors.Is(err, context.DeadlineExceeded), time.Since(started) <= 750*time.Millisecond)
	}
	if _, err := locker.ExecContext(context.Background(), `ROLLBACK`); err != nil {
		t.Fatalf("release write lock: %v", err)
	}
	if _, err := service.Refresh(context.Background(), session.RefreshToken); err != nil {
		t.Fatalf("canceled refresh invalidated original token: %v", err)
	}
}

func TestMalformedRefreshNeverLeaksInputInFormatting(t *testing.T) {
	fixture := newAuthFixture(t)
	service := newSessionService(t, fixture, clock.NewFake(fixture.now))
	private := fmt.Sprintf("private-%d", fixture.now.UnixNano())
	_, err := service.Refresh(context.Background(), private)
	if err == nil || strings.Contains(fmt.Sprintf("%v", err), private) {
		t.Fatalf("Refresh error leaked input: %v", err)
	}
}
