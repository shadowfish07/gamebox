package matches

import (
	"bytes"
	"context"
	"crypto/rand"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"errors"
	"io"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

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
	ErrStaleRevision        = errors.New("stale_revision")
	ErrActionConflict       = errors.New("action_conflict")
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
	nowMillis := service.clock.Now().UTC().UnixMilli()
	matchIDText := matchID.String()
	result, insertErr := transaction.ExecContext(ctx, `
INSERT INTO matches(id,game_id,status,revision,created_at,updated_at)
VALUES (?,?,?,0,?,?)`, matchIDText, gameID, StatusActive, nowMillis, nowMillis)
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
	rules, ok := service.games.Lookup(match.GameID)
	if !ok || rules.PlayerLimit() != 2 {
		return Event{}, Snapshot{}, ErrInternal
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
	if request.ExpectedRevision != match.Revision {
		return Event{}, Snapshot{}, ErrStaleRevision
	}
	actor, opponent, member := actionPlayers(players, request.ActorUserID)
	if !member {
		return Event{}, Snapshot{}, ErrInvalidRequest
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

type actionSemantics struct {
	x int
	y int
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
	var result, winner sql.NullString
	var createdAt, updatedAt int64
	var finishedAt sql.NullInt64
	err := transaction.QueryRowContext(ctx, `
SELECT game_id,status,revision,result,winner_user_id,created_at,updated_at,finished_at
FROM matches
WHERE id=?`, matchID).Scan(&match.GameID, &match.Status, &match.Revision, &result, &winner, &createdAt, &updatedAt, &finishedAt)
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
	rules, ok := service.games.Lookup(match.GameID)
	if !ok || rules.PlayerLimit() != 2 || match.GameID != gomoku.GameID {
		return Snapshot{}, ErrInternal
	}
	events, err := readMatchEvents(ctx, transaction, match.ID)
	if err != nil {
		return Snapshot{}, err
	}
	if match.Revision != int64(len(events)) || len(events) > maximumMatchEvents {
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

func validateLifecycle(match Match, game gameStateSummary, terminalType string, players []Player, events []Event) error {
	if match.Revision > maximumMatchEvents {
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
		case ResultDraw:
			if terminalType != "" || game.Status != StatusFinished || game.Result == nil || *game.Result != ResultDraw || match.WinnerUserID != nil || game.WinnerUserID != nil {
				return ErrInternal
			}
		case ResultResignation:
			if terminalType != protocol.TypeGomokuResigned || game.Status != StatusActive || game.Result != nil || game.WinnerUserID != nil || match.WinnerUserID == nil || !playerMember(players, *match.WinnerUserID) || len(events) == 0 {
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

func readMatchEvents(ctx context.Context, transaction *sql.Tx, matchID string) ([]Event, error) {
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
		if len(events) >= maximumMatchEvents+1 {
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

func safeActionRuleError(err error) error {
	switch {
	case errors.Is(err, gomoku.ErrNotYourTurn):
		return gomoku.ErrNotYourTurn
	case errors.Is(err, gomoku.ErrCellOccupied):
		return gomoku.ErrCellOccupied
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
			CreatedAt: snapshot.Match.CreatedAt, UpdatedAt: snapshot.Match.UpdatedAt, FinishedAt: cloneTimePointer(snapshot.Match.FinishedAt),
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
