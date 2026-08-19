// Package auth implements account registration and session authentication.
package auth

import (
	"context"
	"crypto/rand"
	"database/sql"
	"database/sql/driver"
	"errors"
	"io"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	sqlite "modernc.org/sqlite"

	"me.zqydev/gamebox/server/internal/clock"
	"me.zqydev/gamebox/server/internal/users"
)

var (
	ErrInvalidConfiguration = errors.New("invalid auth configuration")
	ErrInvalidRequest       = errors.New("invalid_request")
	ErrInviteInvalid        = errors.New("invite_invalid")
	ErrNicknameTaken        = errors.New("nickname_taken")
	ErrUnauthorized         = errors.New("unauthorized")
	ErrInternal             = errors.New("internal_error")
)

const sqliteConstraintCode = 19

const (
	registrationBusySlice  = 25 * time.Millisecond
	registrationBusyLimit  = 5 * time.Second
	connectionCleanupLimit = time.Second
)

// Service owns transactional account operations. Its database must come from
// store.Open so every transaction begins with SQLite's immediate lock mode.
type Service struct {
	db        *sql.DB
	clock     clock.Clock
	pepper    string
	jwtSecret []byte
	entropy   io.Reader
	commit    func(*writeTransaction) error
}

// String prevents internal authentication dependencies from being exposed by
// ordinary diagnostic formatting.
func (Service) String() string {
	return "Service{credentials:<redacted>}"
}

// GoString keeps %#v redacted as well.
func (service Service) GoString() string {
	return service.String()
}

// ServiceConfig carries authentication secrets explicitly. JWTSecret is copied
// during construction so callers cannot mutate the service's signing key.
type ServiceConfig struct {
	JWTSecret   []byte
	TokenPepper string
}

// String prevents accidental disclosure when configuration is formatted by
// loggers, diagnostics, or tests.
func (ServiceConfig) String() string {
	return "ServiceConfig{JWTSecret:<redacted> TokenPepper:<redacted>}"
}

// GoString keeps %#v redacted as well.
func (config ServiceConfig) GoString() string {
	return config.String()
}

func NewService(db *sql.DB, serviceClock clock.Clock, config ServiceConfig) (*Service, error) {
	if db == nil || serviceClock == nil || len(config.JWTSecret) < 32 || len([]byte(config.TokenPepper)) < 32 {
		return nil, ErrInvalidConfiguration
	}
	return &Service{
		db:        db,
		clock:     serviceClock,
		pepper:    config.TokenPepper,
		jwtSecret: append([]byte(nil), config.JWTSecret...),
		entropy:   rand.Reader,
		commit:    commitWriteTransaction,
	}, nil
}

// Register atomically creates one user and consumes one invite. It never
// returns an invitation, token hash, or database diagnostic to the caller.
func (service *Service) Register(ctx context.Context, inviteCode, rawNickname string) (_ users.User, err error) {
	if ctx == nil || inviteCode == "" {
		return users.User{}, ErrInvalidRequest
	}
	displayNickname, normalizedNickname, normalizeErr := users.NormalizeNickname(rawNickname)
	if normalizeErr != nil {
		return users.User{}, ErrInvalidRequest
	}
	inviteHash, hashErr := HashToken(service.pepper, inviteCode)
	if hashErr != nil {
		return users.User{}, ErrInvalidRequest
	}

	transaction, beginErr := service.beginWriteTransaction(ctx)
	if beginErr != nil {
		return users.User{}, beginErr
	}
	defer func() {
		if rollbackErr := transaction.Rollback(); rollbackErr != nil && !errors.Is(rollbackErr, sql.ErrTxDone) && err == nil {
			err = databaseError(ctx, rollbackErr)
		}
		// A committed registration remains successful even if returning its
		// connection to the pool fails. release discards any connection whose
		// original busy timeout cannot be restored.
		_ = transaction.release()
	}()

	var available int
	queryErr := transaction.QueryRowContext(ctx, `
SELECT 1
FROM invite_codes
WHERE code_hash = ? AND consumed_at IS NULL AND consumed_by IS NULL`, inviteHash).Scan(&available)
	if errors.Is(queryErr, sql.ErrNoRows) {
		return users.User{}, ErrInviteInvalid
	}
	if queryErr != nil {
		return users.User{}, databaseError(ctx, queryErr)
	}

	userID, idErr := uuid.NewRandom()
	if idErr != nil {
		return users.User{}, ErrInternal
	}
	timestamp := service.clock.Now().UTC().Unix()
	_, insertErr := transaction.ExecContext(ctx, `
INSERT INTO users(id, nickname, normalized_nickname, created_at, updated_at)
VALUES (?, ?, ?, ?, ?)`, userID.String(), displayNickname, normalizedNickname, timestamp, timestamp)
	if insertErr != nil {
		if isNormalizedNicknameConflict(insertErr) {
			return users.User{}, ErrNicknameTaken
		}
		return users.User{}, databaseError(ctx, insertErr)
	}

	result, updateErr := transaction.ExecContext(ctx, `
UPDATE invite_codes
SET consumed_by = ?, consumed_at = ?
WHERE code_hash = ? AND consumed_at IS NULL AND consumed_by IS NULL`, userID.String(), timestamp, inviteHash)
	if updateErr != nil {
		return users.User{}, databaseError(ctx, updateErr)
	}
	affected, rowsErr := result.RowsAffected()
	if rowsErr != nil {
		return users.User{}, databaseError(ctx, rowsErr)
	}
	if affected != 1 {
		return users.User{}, ErrInviteInvalid
	}
	if commitErr := transaction.Commit(); commitErr != nil {
		return users.User{}, databaseError(ctx, commitErr)
	}
	return users.User{ID: userID.String(), Nickname: displayNickname}, nil
}

// Authenticate verifies an access token against the signing policy, confirms
// that its user is still enabled, and records authenticated activity in one
// transaction. The timestamp is deliberately persisted in UTC milliseconds so
// lobby presence comparisons use the same unit as match lifecycle data.
func (service *Service) Authenticate(ctx context.Context, rawAccessToken string) (_ users.User, err error) {
	if ctx == nil {
		return users.User{}, ErrUnauthorized
	}
	identity, parseErr := service.ParseAccess(rawAccessToken)
	if parseErr != nil {
		return users.User{}, ErrUnauthorized
	}
	transaction, beginErr := service.beginWriteTransaction(ctx)
	if beginErr != nil {
		return users.User{}, beginErr
	}
	defer func() {
		if rollbackErr := transaction.Rollback(); rollbackErr != nil && !errors.Is(rollbackErr, sql.ErrTxDone) && err == nil {
			err = databaseError(ctx, rollbackErr)
		}
		_ = transaction.release()
	}()

	nowMillis := service.clock.Now().UTC().UnixMilli()
	result, updateErr := transaction.ExecContext(ctx, `
UPDATE users
SET last_seen_at = ?
WHERE id = ? AND enabled = 1`, nowMillis, identity.UserID)
	if updateErr != nil {
		return users.User{}, databaseError(ctx, updateErr)
	}
	affected, rowsErr := result.RowsAffected()
	if rowsErr != nil {
		return users.User{}, databaseError(ctx, rowsErr)
	}
	if affected != 1 {
		return users.User{}, ErrUnauthorized
	}
	user := users.User{ID: identity.UserID}
	var normalizedNickname string
	if queryErr := transaction.QueryRowContext(ctx, `SELECT nickname,normalized_nickname FROM users WHERE id = ? AND enabled = 1`, identity.UserID).Scan(&user.Nickname, &normalizedNickname); queryErr != nil {
		if errors.Is(queryErr, sql.ErrNoRows) {
			return users.User{}, ErrUnauthorized
		}
		return users.User{}, databaseError(ctx, queryErr)
	}
	parsedID, idErr := uuid.Parse(user.ID)
	displayNickname, normalized, normalizeErr := users.NormalizeNickname(user.Nickname)
	if idErr != nil || parsedID.String() != user.ID || parsedID.Variant() != uuid.RFC4122 || normalizeErr != nil || displayNickname != user.Nickname || normalized != normalizedNickname {
		return users.User{}, ErrInternal
	}
	if commitErr := service.commit(transaction); commitErr != nil {
		return users.User{}, databaseError(ctx, commitErr)
	}
	return user, nil
}

func isNormalizedNicknameConflict(err error) bool {
	var sqliteErr *sqlite.Error
	return errors.As(err, &sqliteErr) &&
		sqliteErr.Code()&0xff == sqliteConstraintCode &&
		strings.Contains(sqliteErr.Error(), "UNIQUE constraint failed: users.normalized_nickname")
}

type writeTransaction struct {
	*sql.Tx
	connection          *sql.Conn
	originalBusyTimeout int
	cancel              context.CancelFunc
}

func commitWriteTransaction(transaction *writeTransaction) error {
	return transaction.Commit()
}

// beginWriteTransaction keeps SQLite's immediate transaction semantics
// while slicing its five-second busy wait into short attempts. This is needed
// because SQLite's busy handler does not observe context cancellation until its
// current wait completes.
func (service *Service) beginWriteTransaction(ctx context.Context) (*writeTransaction, error) {
	operationContext, cancel := context.WithTimeout(ctx, registrationBusyLimit)

	for {
		connection, err := service.db.Conn(operationContext)
		if err != nil {
			cancel()
			return nil, registrationBeginError(ctx, operationContext, err)
		}
		originalBusyTimeout, err := configureRegistrationConnection(operationContext, connection)
		if err != nil {
			// The assignment may have taken effect before the driver reported
			// failure. Never return a connection with unknown policy to the pool.
			_ = discardConnection(connection)
			cancel()
			return nil, registrationBeginError(ctx, operationContext, err)
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
			return nil, registrationBeginError(ctx, operationContext, err)
		}
		select {
		case <-operationContext.Done():
			cancel()
			return nil, registrationBeginError(ctx, operationContext, operationContext.Err())
		case <-time.After(time.Millisecond):
		}
	}
}

func configureRegistrationConnection(ctx context.Context, connection *sql.Conn) (int, error) {
	var originalBusyTimeout int
	if err := connection.QueryRowContext(ctx, `PRAGMA busy_timeout`).Scan(&originalBusyTimeout); err != nil {
		return 0, err
	}
	busyMilliseconds := int(registrationBusySlice / time.Millisecond)
	if _, err := connection.ExecContext(ctx, `PRAGMA busy_timeout = `+strconv.Itoa(busyMilliseconds)); err != nil {
		return 0, err
	}
	return originalBusyTimeout, nil
}

func (transaction *writeTransaction) release() error {
	if transaction.cancel != nil {
		transaction.cancel()
	}
	cleanupContext, cancel := context.WithTimeout(context.Background(), connectionCleanupLimit)
	defer cancel()
	restoreErr := error(nil)
	if transaction.connection != nil {
		_, restoreErr = transaction.connection.ExecContext(cleanupContext, `PRAGMA busy_timeout = `+strconv.Itoa(transaction.originalBusyTimeout))
		if restoreErr != nil {
			// Never return a connection with mutated lock policy to the pool.
			discardErr := discardConnection(transaction.connection)
			return errors.Join(restoreErr, discardErr)
		}
		closeErr := transaction.connection.Close()
		if restoreErr == nil {
			restoreErr = closeErr
		}
	}
	return restoreErr
}

// beginRegistrationTransaction remains a narrow compatibility name for the
// registration hardening tests; all account writes use the same safe helper.
func (service *Service) beginRegistrationTransaction(ctx context.Context) (*writeTransaction, error) {
	return service.beginWriteTransaction(ctx)
}

// discardConnection transfers disposal ownership to database/sql. Returning
// driver.ErrBadConn from Raw marks the sql.Conn unusable and makes the pool
// close the physical connection exactly once; callers must never close the
// exposed driver connection themselves.
func discardConnection(connection *sql.Conn) error {
	if connection == nil {
		return nil
	}
	rawErr := connection.Raw(func(any) error {
		return driver.ErrBadConn
	})
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
	return errors.As(err, &sqliteErr) && sqliteErr.Code()&0xff == 5
}

func registrationBeginError(callerContext, operationContext context.Context, err error) error {
	if callerErr := callerContext.Err(); callerErr != nil {
		return callerErr
	}
	if operationContext.Err() != nil {
		return ErrInternal
	}
	return databaseError(callerContext, err)
}

func databaseError(ctx context.Context, err error) error {
	if contextErr := ctx.Err(); contextErr != nil {
		return contextErr
	}
	if errors.Is(err, context.Canceled) {
		return context.Canceled
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return context.DeadlineExceeded
	}
	return ErrInternal
}
