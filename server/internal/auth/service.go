// Package auth implements account registration and session authentication.
package auth

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
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
	db     *sql.DB
	clock  clock.Clock
	pepper string
}

func NewService(db *sql.DB, serviceClock clock.Clock, tokenPepper string) (*Service, error) {
	if db == nil || serviceClock == nil || tokenPepper == "" {
		return nil, ErrInvalidConfiguration
	}
	return &Service{db: db, clock: serviceClock, pepper: tokenPepper}, nil
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

	transaction, beginErr := service.beginRegistrationTransaction(ctx)
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

func isNormalizedNicknameConflict(err error) bool {
	var sqliteErr *sqlite.Error
	return errors.As(err, &sqliteErr) &&
		sqliteErr.Code()&0xff == sqliteConstraintCode &&
		strings.Contains(sqliteErr.Error(), "UNIQUE constraint failed: users.normalized_nickname")
}

type registrationTransaction struct {
	*sql.Tx
	connection          *sql.Conn
	originalBusyTimeout int
	cancel              context.CancelFunc
}

// beginRegistrationTransaction keeps SQLite's immediate transaction semantics
// while slicing its five-second busy wait into short attempts. This is needed
// because SQLite's busy handler does not observe context cancellation until its
// current wait completes.
func (service *Service) beginRegistrationTransaction(ctx context.Context) (*registrationTransaction, error) {
	operationContext, cancel := context.WithTimeout(ctx, registrationBusyLimit)

	for {
		connection, err := service.db.Conn(operationContext)
		if err != nil {
			cancel()
			return nil, registrationBeginError(ctx, operationContext, err)
		}
		originalBusyTimeout, err := configureRegistrationConnection(operationContext, connection)
		if err != nil {
			_ = connection.Close()
			cancel()
			return nil, registrationBeginError(ctx, operationContext, err)
		}
		transaction, err := connection.BeginTx(operationContext, nil)
		if err == nil {
			return &registrationTransaction{
				Tx:                  transaction,
				connection:          connection,
				originalBusyTimeout: originalBusyTimeout,
				cancel:              cancel,
			}, nil
		}
		failed := &registrationTransaction{connection: connection, originalBusyTimeout: originalBusyTimeout}
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

func (transaction *registrationTransaction) release() error {
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
			_ = transaction.connection.Raw(func(rawConnection any) error {
				if closer, ok := rawConnection.(driver.Conn); ok {
					_ = closer.Close()
				}
				return driver.ErrBadConn
			})
		}
		closeErr := transaction.connection.Close()
		if restoreErr == nil {
			restoreErr = closeErr
		}
	}
	return restoreErr
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
