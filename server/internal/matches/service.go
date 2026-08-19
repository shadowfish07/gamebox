package matches

import (
	"context"
	"crypto/rand"
	"database/sql"
	"database/sql/driver"
	"errors"
	"io"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	sqlite "modernc.org/sqlite"
	sqlite3 "modernc.org/sqlite/lib"

	"me.zqydev/gamebox/server/internal/clock"
	"me.zqydev/gamebox/server/internal/games"
	"me.zqydev/gamebox/server/internal/games/gomoku"
	"me.zqydev/gamebox/server/internal/protocol"
)

var (
	ErrInvalidConfiguration = errors.New("invalid match configuration")
	ErrInvalidRequest       = errors.New("invalid_request")
	ErrActiveMatchExists    = errors.New("active_match_exists")
	ErrOpponentBusy         = errors.New("opponent_busy")
	ErrMatchNotFound        = errors.New("match_not_found")
	ErrMatchNotCancellable  = errors.New("match_not_cancellable")
	ErrInternal             = errors.New("internal_error")
)

const (
	matchSQLiteBusySlice      = 25 * time.Millisecond
	matchWriteLimit           = 5 * time.Second
	matchConnectionCleanLimit = time.Second
	matchSQLiteBusyCode       = 5
	maximumIdentifierBytes    = 128
	cancelledPayloadJSON      = `{}`
)

// Service atomically owns match creation and lifecycle transitions. The
// database must be opened by store.Open so BeginTx acquires an immediate
// SQLite write transaction.
type Service struct {
	db       *sql.DB
	games    *games.Registry
	clock    clock.Clock
	random   io.Reader
	randomMu sync.Mutex
}

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
	return &Service{db: db, games: registry, clock: serviceClock, random: colorRandom}, nil
}

// Create atomically creates a two-player match. Stable seats are based on the
// call roles; only colors are random.
func (service *Service) Create(ctx context.Context, gameID, initiatorID, opponentID string) (_ Match, err error) {
	if !service.configured() {
		return Match{}, ErrInvalidConfiguration
	}
	if ctx == nil || !validIdentifier(initiatorID) || !validIdentifier(opponentID) || initiatorID == opponentID {
		return Match{}, ErrInvalidRequest
	}
	rules, ok := service.games.Lookup(gameID)
	if !ok || rules.PlayerLimit() != 2 {
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
	nowUnix := service.clock.Now().UTC().Unix()
	matchIDText := matchID.String()
	result, insertErr := transaction.ExecContext(ctx, `
INSERT INTO matches(id,game_id,status,revision,created_at,updated_at)
VALUES (?,?,?,0,?,?)`, matchIDText, gameID, StatusActive, nowUnix, nowUnix)
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
	timestamp := time.Unix(nowUnix, 0).UTC()
	return Match{
		ID:        matchIDText,
		GameID:    gameID,
		Status:    StatusActive,
		Revision:  0,
		CreatedAt: timestamp,
		UpdatedAt: timestamp,
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

	var acceptedMoves int
	if queryErr := transaction.QueryRowContext(ctx, `
SELECT EXISTS(
  SELECT 1 FROM match_events
  WHERE match_id=? AND event_type=?
)`, matchID, gomoku.MoveAccepted).Scan(&acceptedMoves); queryErr != nil {
		return Event{}, matchDatabaseError(ctx, queryErr)
	}
	if acceptedMoves != 0 {
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
	nowUnix := service.clock.Now().UTC().Unix()
	result, insertErr := transaction.ExecContext(ctx, `
INSERT INTO match_events(match_id,revision,event_type,action_id,actor_user_id,payload_json,created_at)
VALUES (?,?,?,NULL,?,?,?)`, matchID, nextRevision, protocol.TypePlatformMatchCancelled, actorUserID, cancelledPayloadJSON, nowUnix)
	if insertErr != nil {
		return Event{}, matchDatabaseError(ctx, insertErr)
	}
	if affectedExactlyOne(result) != nil {
		return Event{}, ErrInternal
	}

	result, updateErr := transaction.ExecContext(ctx, `
UPDATE matches
SET status=?, revision=?, updated_at=?, finished_at=?, winner_user_id=NULL, result=NULL
WHERE id=? AND status=? AND revision=?`, StatusCancelled, nextRevision, nowUnix, nowUnix, matchID, StatusActive, revision)
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
	if commitErr := transaction.Commit(); commitErr != nil {
		return Event{}, matchDatabaseError(ctx, commitErr)
	}
	actorCopy := actorUserID
	timestamp := time.Unix(nowUnix, 0).UTC()
	return Event{
		MatchID:     matchID,
		Revision:    nextRevision,
		Type:        protocol.TypePlatformMatchCancelled,
		ActorUserID: &actorCopy,
		Payload:     append([]byte(nil), cancelledPayloadJSON...),
		CreatedAt:   timestamp,
	}, nil
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
		return ErrInternal
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
	return ErrInternal
}
