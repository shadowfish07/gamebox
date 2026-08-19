package auth

import (
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"

	"me.zqydev/gamebox/server/internal/clock"
	"me.zqydev/gamebox/server/internal/store"
)

const testPepper = "test-only-registration-pepper"

type authFixture struct {
	db      *sql.DB
	service *Service
	now     time.Time
}

func newAuthFixture(t *testing.T) authFixture {
	t.Helper()
	db, err := store.Open(context.Background(), filepath.Join(t.TempDir(), "gamebox.sqlite"))
	if err != nil {
		t.Fatalf("open test store: %v", err)
	}
	t.Cleanup(func() {
		if err := db.Close(); err != nil {
			t.Errorf("close test store: %v", err)
		}
	})
	now := time.Date(2026, time.August, 19, 8, 9, 10, 987654321, time.FixedZone("test", 8*60*60))
	service, err := NewService(db, clock.NewFake(now), testPepper)
	if err != nil {
		t.Fatalf("create auth service: %v", err)
	}
	return authFixture{db: db, service: service, now: now}
}

func (fixture authFixture) addInvite(t *testing.T, plaintext string) string {
	t.Helper()
	hash, err := HashToken(testPepper, plaintext)
	if err != nil {
		t.Fatalf("hash invite: %v", err)
	}
	if _, err := fixture.db.Exec(`INSERT INTO invite_codes(code_hash, created_at) VALUES (?, ?)`, hash, fixture.now.Add(-time.Hour).Unix()); err != nil {
		t.Fatalf("insert invite: %v", err)
	}
	return hash
}

func TestRegisterConsumesInviteOnceAndStoresTrimmedNickname(t *testing.T) {
	fixture := newAuthFixture(t)
	code := "invite-success"
	hash := fixture.addInvite(t, code)

	user, err := fixture.service.Register(context.Background(), code, "\u2003Alice\u2003")
	if err != nil {
		t.Fatalf("Register returned error: %v", err)
	}
	parsedID, err := uuid.Parse(user.ID)
	if err != nil || parsedID.Version() != 4 || parsedID.Variant() != uuid.RFC4122 {
		t.Fatalf("user ID = %q, want RFC 4122 UUIDv4 (parse error %v)", user.ID, err)
	}
	if user.Nickname != "Alice" {
		t.Fatalf("nickname = %q, want trimmed display nickname", user.Nickname)
	}

	var nickname, normalized string
	var createdAt, updatedAt int64
	if err := fixture.db.QueryRow(`SELECT nickname, normalized_nickname, created_at, updated_at FROM users WHERE id = ?`, user.ID).
		Scan(&nickname, &normalized, &createdAt, &updatedAt); err != nil {
		t.Fatalf("read registered user: %v", err)
	}
	if nickname != "Alice" || normalized != "alice" {
		t.Fatalf("stored nickname = (%q, %q), want (Alice, alice)", nickname, normalized)
	}
	if createdAt != fixture.now.Unix() || updatedAt != fixture.now.Unix() {
		t.Fatalf("stored timestamps = (%d, %d), want UTC Unix seconds %d", createdAt, updatedAt, fixture.now.Unix())
	}

	var consumedBy string
	var consumedAt int64
	if err := fixture.db.QueryRow(`SELECT consumed_by, consumed_at FROM invite_codes WHERE code_hash = ?`, hash).Scan(&consumedBy, &consumedAt); err != nil {
		t.Fatalf("read consumed invite: %v", err)
	}
	if consumedBy != user.ID || consumedAt != fixture.now.Unix() {
		t.Fatalf("invite consumption = (%q, %d), want (%q, %d)", consumedBy, consumedAt, user.ID, fixture.now.Unix())
	}
	var plaintextRows int
	if err := fixture.db.QueryRow(`SELECT COUNT(*) FROM invite_codes WHERE code_hash = ?`, code).Scan(&plaintextRows); err != nil {
		t.Fatalf("search for plaintext invite: %v", err)
	}
	if plaintextRows != 0 {
		t.Fatal("plaintext invite code was stored")
	}

	if _, err := fixture.service.Register(context.Background(), code, "Bob"); !errors.Is(err, ErrInviteInvalid) {
		t.Fatalf("second Register error = %v, want ErrInviteInvalid", err)
	}
}

func TestRegisterNicknameConflictDoesNotConsumeInvite(t *testing.T) {
	fixture := newAuthFixture(t)
	if _, err := fixture.db.Exec(`INSERT INTO users(id, nickname, normalized_nickname, created_at, updated_at) VALUES (?, ?, ?, ?, ?)`,
		"existing-user", "Alice", "alice", fixture.now.Add(-time.Hour).Unix(), fixture.now.Add(-time.Hour).Unix()); err != nil {
		t.Fatalf("insert existing user: %v", err)
	}
	hash := fixture.addInvite(t, "invite-for-conflict")

	if _, err := fixture.service.Register(context.Background(), "invite-for-conflict", " alice "); !errors.Is(err, ErrNicknameTaken) {
		t.Fatalf("Register error = %v, want ErrNicknameTaken", err)
	} else if err.Error() != ErrNicknameTaken.Error() {
		t.Fatalf("nickname conflict leaked internal details: %q", err)
	}

	var consumedBy, consumedAt sql.NullString
	if err := fixture.db.QueryRow(`SELECT consumed_by, consumed_at FROM invite_codes WHERE code_hash = ?`, hash).Scan(&consumedBy, &consumedAt); err != nil {
		t.Fatalf("read invite after nickname conflict: %v", err)
	}
	if consumedBy.Valid || consumedAt.Valid {
		t.Fatalf("nickname conflict consumed invite: consumed_by=%v consumed_at=%v", consumedBy, consumedAt)
	}
}

func TestRegisterConcurrentInviteConsumptionAllowsExactlyOneUser(t *testing.T) {
	fixture := newAuthFixture(t)
	fixture.addInvite(t, "single-use-concurrent")

	start := make(chan struct{})
	errorsByCall := make(chan error, 2)
	var calls sync.WaitGroup
	for index, nickname := range []string{"Alice", "Bob"} {
		index, nickname := index, nickname
		calls.Add(1)
		go func() {
			defer calls.Done()
			<-start
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			_, err := fixture.service.Register(ctx, "single-use-concurrent", fmt.Sprintf("%s%d", nickname, index))
			errorsByCall <- err
		}()
	}
	close(start)
	calls.Wait()
	close(errorsByCall)

	successes, invalidInvites := 0, 0
	for err := range errorsByCall {
		switch {
		case err == nil:
			successes++
		case errors.Is(err, ErrInviteInvalid):
			invalidInvites++
		default:
			t.Errorf("concurrent Register error = %v, want nil or ErrInviteInvalid", err)
		}
	}
	if successes != 1 || invalidInvites != 1 {
		t.Fatalf("concurrent results = %d success, %d invite invalid; want exactly one each", successes, invalidInvites)
	}
	var users int
	if err := fixture.db.QueryRow(`SELECT COUNT(*) FROM users`).Scan(&users); err != nil {
		t.Fatalf("count users: %v", err)
	}
	if users != 1 {
		t.Fatalf("stored users = %d, want 1", users)
	}
}

func TestRegisterRejectsMissingConsumedAndEmptyInvitesWithoutLeakingSecrets(t *testing.T) {
	fixture := newAuthFixture(t)
	consumedHash := fixture.addInvite(t, "already-consumed-secret")
	if _, err := fixture.db.Exec(`INSERT INTO users(id, nickname, normalized_nickname, created_at, updated_at) VALUES ('consumer', 'Consumer', 'consumer', ?, ?)`, fixture.now.Unix(), fixture.now.Unix()); err != nil {
		t.Fatalf("insert consuming user: %v", err)
	}
	if _, err := fixture.db.Exec(`UPDATE invite_codes SET consumed_by = 'consumer', consumed_at = ? WHERE code_hash = ?`, fixture.now.Unix(), consumedHash); err != nil {
		t.Fatalf("consume invite: %v", err)
	}

	tests := []struct {
		name string
		code string
		want error
	}{
		{name: "missing", code: "missing-secret", want: ErrInviteInvalid},
		{name: "consumed", code: "already-consumed-secret", want: ErrInviteInvalid},
		{name: "empty", code: "", want: ErrInvalidRequest},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, err := fixture.service.Register(context.Background(), test.code, "Valid Nick")
			if !errors.Is(err, test.want) {
				t.Fatalf("Register error = %v, want %v", err, test.want)
			}
			if err.Error() != test.want.Error() || (test.code != "" && strings.Contains(err.Error(), test.code)) {
				t.Fatalf("Register error leaked request or internal details: %q", err)
			}
		})
	}
}

func TestRegisterInvalidNicknameDoesNotConsumeInvite(t *testing.T) {
	fixture := newAuthFixture(t)
	hash := fixture.addInvite(t, "valid-invite")

	if _, err := fixture.service.Register(context.Background(), "valid-invite", " \u2003 "); !errors.Is(err, ErrInvalidRequest) {
		t.Fatalf("Register error = %v, want ErrInvalidRequest", err)
	}
	var consumedAt sql.NullInt64
	if err := fixture.db.QueryRow(`SELECT consumed_at FROM invite_codes WHERE code_hash = ?`, hash).Scan(&consumedAt); err != nil {
		t.Fatalf("read invite: %v", err)
	}
	if consumedAt.Valid {
		t.Fatalf("invalid nickname consumed invite at %d", consumedAt.Int64)
	}
}

func TestRegisterHonorsContextCancellationWhileDatabaseIsBusy(t *testing.T) {
	fixture := newAuthFixture(t)
	hash := fixture.addInvite(t, "blocked-invite")
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
	_, err = fixture.service.Register(ctx, "blocked-invite", "Blocked User")
	elapsed := time.Since(started)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("Register error = %v, want context deadline", err)
	}
	if elapsed > 750*time.Millisecond {
		t.Fatalf("Register honored a 75ms context in %v, want <= 750ms", elapsed)
	}

	if _, err := locker.ExecContext(context.Background(), `ROLLBACK`); err != nil {
		t.Fatalf("release write lock: %v", err)
	}
	var consumedAt sql.NullInt64
	if err := fixture.db.QueryRow(`SELECT consumed_at FROM invite_codes WHERE code_hash = ?`, hash).Scan(&consumedAt); err != nil {
		t.Fatalf("read invite after cancellation: %v", err)
	}
	if consumedAt.Valid {
		t.Fatalf("canceled registration consumed invite at %d", consumedAt.Int64)
	}
	var users int
	if err := fixture.db.QueryRow(`SELECT COUNT(*) FROM users`).Scan(&users); err != nil {
		t.Fatalf("count users: %v", err)
	}
	if users != 0 {
		t.Fatalf("canceled registration stored %d users, want 0", users)
	}
}

func TestRegisterServiceRejectsInvalidDependenciesAndPepper(t *testing.T) {
	fixture := newAuthFixture(t)
	tests := []struct {
		name   string
		db     *sql.DB
		clock  clock.Clock
		pepper string
	}{
		{name: "nil database", db: nil, clock: clock.NewFake(fixture.now), pepper: testPepper},
		{name: "nil clock", db: fixture.db, clock: nil, pepper: testPepper},
		{name: "empty pepper", db: fixture.db, clock: clock.NewFake(fixture.now), pepper: ""},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			service, err := NewService(test.db, test.clock, test.pepper)
			if service != nil || !errors.Is(err, ErrInvalidConfiguration) || err.Error() != ErrInvalidConfiguration.Error() {
				t.Fatalf("NewService = (%v, %v), want nil and fixed ErrInvalidConfiguration", service, err)
			}
		})
	}
}

func TestRegisterTokenPrimitivesUseSafeUnambiguousRepresentations(t *testing.T) {
	token, err := RandomToken(32)
	if err != nil {
		t.Fatalf("RandomToken returned error: %v", err)
	}
	decoded, err := base64.RawURLEncoding.DecodeString(token)
	if err != nil {
		t.Fatalf("RandomToken produced non-URL-safe encoding %q: %v", token, err)
	}
	if len(decoded) != 32 {
		t.Fatalf("RandomToken(32) decoded bytes = %d, want exactly 32 entropy bytes", len(decoded))
	}
	if strings.ContainsAny(token, "+/=") {
		t.Fatalf("RandomToken returned padded or non-URL-safe text %q", token)
	}
	second, err := RandomToken(32)
	if err != nil || second == token {
		t.Fatalf("second RandomToken = %q, %v; want an independent token", second, err)
	}

	hash, err := HashToken("pepper", "plaintext")
	if err != nil {
		t.Fatalf("HashToken returned error: %v", err)
	}
	decodedHash, err := hex.DecodeString(hash)
	if err != nil || len(decodedHash) != 32 || hash != strings.ToLower(hash) {
		t.Fatalf("HashToken = %q, want lowercase hexadecimal SHA-256 (decode error %v)", hash, err)
	}
	again, err := HashToken("pepper", "plaintext")
	if err != nil || again != hash {
		t.Fatalf("HashToken is not deterministic: first %q, second %q, error %v", hash, again, err)
	}
	left, err := HashToken("ab", "c")
	if err != nil {
		t.Fatalf("HashToken(ab,c): %v", err)
	}
	right, err := HashToken("a", "bc")
	if err != nil {
		t.Fatalf("HashToken(a,bc): %v", err)
	}
	if left == right {
		t.Fatal("HashToken framing is ambiguous between (ab,c) and (a,bc)")
	}

	for _, test := range []struct {
		name      string
		pepper    string
		plaintext string
	}{
		{name: "empty pepper", plaintext: "token"},
		{name: "empty plaintext", pepper: "pepper"},
	} {
		t.Run(test.name, func(t *testing.T) {
			hash, err := HashToken(test.pepper, test.plaintext)
			if hash != "" || !errors.Is(err, ErrInvalidTokenInput) || err.Error() != ErrInvalidTokenInput.Error() {
				t.Fatalf("HashToken = (%q, %v), want no hash and fixed ErrInvalidTokenInput", hash, err)
			}
		})
	}
	if token, err := RandomToken(0); token != "" || !errors.Is(err, ErrInvalidTokenLength) || err.Error() != ErrInvalidTokenLength.Error() {
		t.Fatalf("RandomToken(0) = (%q, %v), want fixed ErrInvalidTokenLength", token, err)
	}
}

type failingEntropyReader struct{}

func (failingEntropyReader) Read([]byte) (int, error) {
	return 0, errors.New("private entropy source detail")
}

func TestRegisterTokenGenerationFailureUsesFixedError(t *testing.T) {
	token, err := randomToken(32, failingEntropyReader{})
	if token != "" || !errors.Is(err, ErrTokenGeneration) || err.Error() != ErrTokenGeneration.Error() {
		t.Fatalf("randomToken failure = (%q, %v), want no token and fixed ErrTokenGeneration", token, err)
	}
}
