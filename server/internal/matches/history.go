package matches

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"time"

	"github.com/google/uuid"

	"me.zqydev/gamebox/server/internal/games/chinesecheckers"
	"me.zqydev/gamebox/server/internal/games/flightchess"
	"me.zqydev/gamebox/server/internal/games/gomoku"
	"me.zqydev/gamebox/server/internal/games/rps"
)

const (
	historyOutcomeWin       = "win"
	historyOutcomeLoss      = "loss"
	historyOutcomeDraw      = "draw"
	historyOutcomeAbandoned = "abandoned"

	// Flutter's DateTime accepts exactly 100,000,000 days on either side
	// of the Unix epoch. This is narrower than the strict JSON safe-integer
	// range, so it is the shared wire boundary.
	maximumHistoryWireMilliseconds int64 = 8_640_000_000_000_000
)

type HistoryPageRequest struct {
	Limit  int
	Cursor *HistoryCursor
}

type HistoryCursor struct {
	FinishedAt time.Time
	MatchID    string
}

type HistoryStatistics struct {
	ValidMatches int64
	Wins         int64
	Losses       int64
	Draws        int64
	WinRate      float64
}

type HistoryEntry struct {
	ID               string
	Outcome          string
	OpponentNickname string
	Color            Color
	FinishedAt       time.Time
	MoveCount        int64
	Format           string
}

type historyGameSpec struct {
	decisiveResult   string
	countedEventType string
	allowsDraw       bool
	requiresFormat   bool
}

type HistoryPage struct {
	Statistics HistoryStatistics
	Matches    []HistoryEntry
	NextCursor *HistoryCursor
}

type historyFailure struct {
	phase    string
	category string
	cause    error
}

func (failure *historyFailure) Error() string {
	switch {
	case errors.Is(failure.cause, context.Canceled):
		return context.Canceled.Error()
	case errors.Is(failure.cause, context.DeadlineExceeded):
		return context.DeadlineExceeded.Error()
	case errors.Is(failure.cause, ErrInvalidConfiguration):
		return ErrInvalidConfiguration.Error()
	case errors.Is(failure.cause, ErrInvalidRequest):
		return ErrInvalidRequest.Error()
	default:
		return ErrInternal.Error()
	}
}

func (failure *historyFailure) Unwrap() error { return failure.cause }

// HistoryFailureMetadata returns only fixed operational labels. The wrapped
// database error, query text, identifiers and row values are never returned.
func HistoryFailureMetadata(err error) (phase string, category string, ok bool) {
	var failure *historyFailure
	if !errors.As(err, &failure) || !validHistoryPhase(failure.phase) || !validHistoryCategory(failure.category) {
		return "", "", false
	}
	return failure.phase, failure.category, true
}

func (service *Service) ListHistory(ctx context.Context, gameID, userID string, request HistoryPageRequest) (_ HistoryPage, err error) {
	if !service.configured() {
		return HistoryPage{}, ErrInvalidConfiguration
	}
	rules, registered := service.games.Lookup(gameID)
	spec, supported := matchHistoryGameSpec(gameID)
	if ctx == nil || !supported || !registered || rules.PlayerLimit() != 2 || !canonicalUUID(userID) ||
		request.Limit < 1 || request.Limit > 50 || !validHistoryCursor(request.Cursor) {
		return HistoryPage{}, ErrInvalidRequest
	}

	transaction, beginErr := service.db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if beginErr != nil {
		return HistoryPage{}, newHistoryFailure(
			"begin", historyDatabaseCategory(ctx, beginErr), matchDatabaseError(ctx, beginErr),
		)
	}
	defer rollbackReadTransaction(ctx, transaction, &err)

	statistics, statisticsErr := readHistoryStatistics(ctx, transaction, gameID, userID, spec)
	if statisticsErr != nil {
		return HistoryPage{}, statisticsErr
	}
	entries, next, entriesErr := readHistoryEntries(ctx, transaction, gameID, userID, request, spec)
	if entriesErr != nil {
		return HistoryPage{}, entriesErr
	}
	if commitErr := transaction.Commit(); commitErr != nil {
		return HistoryPage{}, newHistoryFailure(
			"commit", historyDatabaseCategory(ctx, commitErr), matchDatabaseError(ctx, commitErr),
		)
	}
	return HistoryPage{Statistics: statistics, Matches: entries, NextCursor: next}, nil
}

func matchHistoryGameSpec(gameID string) (historyGameSpec, bool) {
	switch gameID {
	case chinesecheckers.GameID:
		return historyGameSpec{
			decisiveResult:   ResultGoal,
			countedEventType: chinesecheckers.MoveAccepted,
		}, true
	case flightchess.GameID:
		return historyGameSpec{
			decisiveResult:   ResultGoal,
			countedEventType: flightchess.MoveAccepted,
		}, true
	case gomoku.GameID:
		return historyGameSpec{
			decisiveResult:   ResultFive,
			countedEventType: gomoku.MoveAccepted,
			allowsDraw:       true,
		}, true
	case rps.GameID:
		return historyGameSpec{
			decisiveResult:   ResultRounds,
			countedEventType: rps.RoundRevealed,
			requiresFormat:   true,
		}, true
	default:
		return historyGameSpec{}, false
	}
}

func validHistoryCursor(cursor *HistoryCursor) bool {
	if cursor == nil {
		return true
	}
	if cursor.FinishedAt.IsZero() || !ValidHistoryWireValues(cursor.MatchID, cursor.FinishedAt.UnixMilli()) {
		return false
	}
	canonical := time.UnixMilli(cursor.FinishedAt.UnixMilli()).UTC()
	return cursor.FinishedAt == canonical
}

// ValidHistoryWireValues enforces the match-ID and timestamp domain shared by
// the Go history API and the shipped Flutter client. Match IDs are canonical
// lowercase, nonzero RFC UUIDs with versions 1 through 5. Milliseconds use the
// inclusive Flutter DateTime range; that range also fits exact JSON integers.
func ValidHistoryWireValues(matchID string, finishedAtMillis int64) bool {
	if finishedAtMillis < -maximumHistoryWireMilliseconds || finishedAtMillis > maximumHistoryWireMilliseconds {
		return false
	}
	parsed, err := uuid.Parse(matchID)
	if err != nil || parsed == uuid.Nil || parsed.String() != matchID || parsed.Variant() != uuid.RFC4122 {
		return false
	}
	version := parsed.Version()
	return version >= 1 && version <= 5
}

func readHistoryStatistics(ctx context.Context, transaction *sql.Tx, gameID, userID string, spec historyGameSpec) (HistoryStatistics, error) {
	var enabled int
	callerErr := transaction.QueryRowContext(ctx, `SELECT enabled FROM users WHERE id=?`, userID).Scan(&enabled)
	if errors.Is(callerErr, sql.ErrNoRows) {
		return HistoryStatistics{}, ErrInvalidRequest
	}
	if callerErr != nil {
		return HistoryStatistics{}, newHistoryFailure(
			"statistics", historyDatabaseCategory(ctx, callerErr), matchDatabaseError(ctx, callerErr),
		)
	}
	if enabled != 1 {
		return HistoryStatistics{}, ErrInvalidRequest
	}
	if integrityErr := validateHistoryWireRows(ctx, transaction, gameID, userID, spec); integrityErr != nil {
		return HistoryStatistics{}, integrityErr
	}

	var statistics HistoryStatistics
	var invalidRows int64
	statisticsErr := transaction.QueryRowContext(ctx, `
SELECT
  COALESCE(SUM(CASE
    WHEN matches.status='finished'
     AND matches.result IN (?,'resignation')
     AND matches.winner_user_id=current_player.user_id THEN 1 ELSE 0 END),0),
  COALESCE(SUM(CASE
    WHEN matches.status='finished'
     AND matches.result IN (?,'resignation')
     AND matches.winner_user_id<>current_player.user_id THEN 1 ELSE 0 END),0),
  COALESCE(SUM(CASE
    WHEN matches.status='finished'
     AND matches.result='draw'
     AND ?=1
     AND matches.winner_user_id IS NULL THEN 1 ELSE 0 END),0),
  COALESCE(SUM(CASE WHEN
    matches.finished_at IS NULL
    OR (SELECT COUNT(*) FROM match_players AS all_players WHERE all_players.match_id=matches.id)<>2
    OR (SELECT COUNT(DISTINCT all_players.user_id) FROM match_players AS all_players WHERE all_players.match_id=matches.id)<>2
    OR (SELECT COUNT(DISTINCT all_players.color) FROM match_players AS all_players WHERE all_players.match_id=matches.id)<>2
    OR EXISTS(
      SELECT 1 FROM match_players AS invalid_player
      WHERE invalid_player.match_id=matches.id
        AND (invalid_player.seat NOT IN (0,1) OR invalid_player.color NOT IN ('black','white'))
    )
	OR COALESCE((
	  (matches.status='finished'
	   AND matches.result IN (?,'resignation')
	   AND matches.winner_user_id IN (
	     SELECT winner_player.user_id FROM match_players AS winner_player WHERE winner_player.match_id=matches.id
	   ))
	  OR (matches.status='finished' AND matches.result='draw' AND matches.winner_user_id IS NULL AND ?=1)
	  OR (matches.status='abandoned' AND matches.result IS NULL AND matches.winner_user_id IS NULL)
	),0)=0
  THEN 1 ELSE 0 END),0)
FROM match_players AS current_player
JOIN matches ON matches.id=current_player.match_id
WHERE current_player.user_id=? AND matches.game_id=?
  AND matches.status IN ('finished','abandoned')`,
		spec.decisiveResult, spec.decisiveResult, boolToInt(spec.allowsDraw),
		spec.decisiveResult, boolToInt(spec.allowsDraw), userID, gameID,
	).Scan(
		&statistics.Wins, &statistics.Losses, &statistics.Draws, &invalidRows,
	)
	if statisticsErr != nil {
		return HistoryStatistics{}, newHistoryFailure(
			"statistics", historyDatabaseCategory(ctx, statisticsErr), matchDatabaseError(ctx, statisticsErr),
		)
	}
	if invalidRows != 0 || statistics.Wins < 0 || statistics.Losses < 0 || statistics.Draws < 0 {
		return HistoryStatistics{}, newHistoryFailure("statistics", "data_integrity", ErrInternal)
	}
	statistics.ValidMatches = statistics.Wins + statistics.Losses + statistics.Draws
	if statistics.ValidMatches != 0 {
		statistics.WinRate = float64(statistics.Wins) / float64(statistics.ValidMatches)
	}
	return statistics, nil
}

func validateHistoryWireRows(ctx context.Context, transaction *sql.Tx, gameID, userID string, spec historyGameSpec) error {
	rows, queryErr := transaction.QueryContext(ctx, `
SELECT matches.id,matches.finished_at,matches.game_config_json
FROM match_players AS current_player
JOIN matches ON matches.id=current_player.match_id
WHERE current_player.user_id=? AND matches.game_id=?
  AND matches.status IN ('finished','abandoned')`, userID, gameID)
	if queryErr != nil {
		return newHistoryFailure(
			"statistics", historyDatabaseCategory(ctx, queryErr), matchDatabaseError(ctx, queryErr),
		)
	}
	for rows.Next() {
		var matchID string
		var finishedMillis sql.NullInt64
		var gameConfig sql.NullString
		if scanErr := rows.Scan(&matchID, &finishedMillis, &gameConfig); scanErr != nil {
			_ = rows.Close()
			category := "data_integrity"
			cause := error(ErrInternal)
			if historyDatabaseCategory(ctx, scanErr) == "cancelled" {
				category = "cancelled"
				cause = matchDatabaseError(ctx, scanErr)
			}
			return newHistoryFailure("statistics", category, cause)
		}
		if _, valid := historyEntryFormat(spec, gameConfig); !finishedMillis.Valid ||
			!ValidHistoryWireValues(matchID, finishedMillis.Int64) || !valid {
			_ = rows.Close()
			return newHistoryFailure("statistics", "data_integrity", ErrInternal)
		}
	}
	if rowsErr := rows.Err(); rowsErr != nil {
		_ = rows.Close()
		return newHistoryFailure(
			"statistics", historyDatabaseCategory(ctx, rowsErr), matchDatabaseError(ctx, rowsErr),
		)
	}
	if closeErr := rows.Close(); closeErr != nil {
		return newHistoryFailure(
			"statistics", historyDatabaseCategory(ctx, closeErr), matchDatabaseError(ctx, closeErr),
		)
	}
	return nil
}

func readHistoryEntries(ctx context.Context, transaction *sql.Tx, gameID, userID string, request HistoryPageRequest, spec historyGameSpec) ([]HistoryEntry, *HistoryCursor, error) {
	query := `
SELECT
  matches.id,
  matches.status,
  matches.result,
  matches.winner_user_id,
  matches.finished_at,
  matches.game_config_json,
  current_player.user_id,
  current_player.seat,
  current_player.color,
  opponent_player.user_id,
  opponent_player.seat,
  opponent_player.color,
  opponent_user.nickname,
  opponent_user.normalized_nickname,
  opponent_user.enabled,
  (SELECT COUNT(*) FROM match_players AS counted_players WHERE counted_players.match_id=matches.id),
  (SELECT COUNT(DISTINCT counted_players.user_id) FROM match_players AS counted_players WHERE counted_players.match_id=matches.id),
  (SELECT COUNT(DISTINCT counted_players.color) FROM match_players AS counted_players WHERE counted_players.match_id=matches.id),
  (SELECT COUNT(*) FROM match_events
   WHERE match_events.match_id=matches.id AND match_events.event_type=?)
FROM match_players AS current_player
JOIN matches ON matches.id=current_player.match_id
LEFT JOIN match_players AS opponent_player
  ON opponent_player.match_id=matches.id AND opponent_player.user_id<>current_player.user_id
LEFT JOIN users AS opponent_user ON opponent_user.id=opponent_player.user_id
WHERE current_player.user_id=? AND matches.game_id=?
  AND matches.status IN ('finished','abandoned')`
	arguments := []any{spec.countedEventType, userID, gameID}
	if request.Cursor != nil {
		query += `
  AND (matches.finished_at < ? OR (matches.finished_at = ? AND matches.id < ?))`
		cursorMillis := request.Cursor.FinishedAt.UnixMilli()
		arguments = append(arguments, cursorMillis, cursorMillis, request.Cursor.MatchID)
	}
	query += `
ORDER BY matches.finished_at DESC,matches.id DESC
LIMIT ?`
	arguments = append(arguments, request.Limit+1)

	rows, queryErr := transaction.QueryContext(ctx, query, arguments...)
	if queryErr != nil {
		return nil, nil, newHistoryFailure(
			"entries", historyDatabaseCategory(ctx, queryErr), matchDatabaseError(ctx, queryErr),
		)
	}
	entries := make([]HistoryEntry, 0, request.Limit)
	observedRows := 0
	for rows.Next() {
		observedRows++
		var (
			matchID, status, currentUserID, currentColor string
			result, winner, opponentID                   sql.NullString
			finishedMillis                               sql.NullInt64
			gameConfig                                   sql.NullString
			currentSeat                                  int
			opponentSeat                                 sql.NullInt64
			opponentColor, nickname, normalized          sql.NullString
			opponentEnabled                              sql.NullInt64
			memberCount, distinctUsers, distinctColors   int64
			moveCount                                    int64
		)
		scanErr := rows.Scan(
			&matchID, &status, &result, &winner, &finishedMillis, &gameConfig,
			&currentUserID, &currentSeat, &currentColor,
			&opponentID, &opponentSeat, &opponentColor,
			&nickname, &normalized, &opponentEnabled,
			&memberCount, &distinctUsers, &distinctColors, &moveCount,
		)
		if scanErr != nil {
			_ = rows.Close()
			category := "data_integrity"
			cause := error(ErrInternal)
			if historyDatabaseCategory(ctx, scanErr) == "cancelled" {
				category = "cancelled"
				cause = matchDatabaseError(ctx, scanErr)
			}
			return nil, nil, newHistoryFailure("entries", category, cause)
		}

		entry, valid := validatedHistoryEntry(
			spec, userID, matchID, status, result, winner, finishedMillis, gameConfig,
			currentUserID, currentSeat, currentColor,
			opponentID, opponentSeat, opponentColor, nickname, normalized, opponentEnabled,
			memberCount, distinctUsers, distinctColors, moveCount,
		)
		if !valid {
			_ = rows.Close()
			return nil, nil, newHistoryFailure("entries", "data_integrity", ErrInternal)
		}
		if len(entries) < request.Limit {
			entries = append(entries, entry)
		}
	}
	if rowsErr := rows.Err(); rowsErr != nil {
		_ = rows.Close()
		return nil, nil, newHistoryFailure(
			"entries", historyDatabaseCategory(ctx, rowsErr), matchDatabaseError(ctx, rowsErr),
		)
	}
	if closeErr := rows.Close(); closeErr != nil {
		return nil, nil, newHistoryFailure(
			"entries", historyDatabaseCategory(ctx, closeErr), matchDatabaseError(ctx, closeErr),
		)
	}

	var next *HistoryCursor
	if observedRows > request.Limit {
		last := entries[len(entries)-1]
		next = &HistoryCursor{FinishedAt: last.FinishedAt, MatchID: last.ID}
	}
	return entries, next, nil
}

func validatedHistoryEntry(
	spec historyGameSpec,
	userID, matchID, status string,
	result, winner sql.NullString,
	finishedMillis sql.NullInt64,
	gameConfig sql.NullString,
	currentUserID string,
	currentSeat int,
	currentColor string,
	opponentID sql.NullString,
	opponentSeat sql.NullInt64,
	opponentColor, nickname, normalized sql.NullString,
	opponentEnabled sql.NullInt64,
	memberCount, distinctUsers, distinctColors, moveCount int64,
) (HistoryEntry, bool) {
	format, validFormat := historyEntryFormat(spec, gameConfig)
	if !validFormat || !finishedMillis.Valid || !ValidHistoryWireValues(matchID, finishedMillis.Int64) ||
		currentUserID != userID || !canonicalUUID(currentUserID) ||
		!opponentID.Valid || !canonicalUUID(opponentID.String) || opponentID.String == currentUserID ||
		memberCount != 2 || distinctUsers != 2 || distinctColors != 2 ||
		(currentSeat != 0 && currentSeat != 1) || !opponentSeat.Valid ||
		(opponentSeat.Int64 != 0 && opponentSeat.Int64 != 1) || int64(currentSeat) == opponentSeat.Int64 ||
		!validHistoryColors(Color(currentColor), Color(opponentColor.String)) || !opponentColor.Valid ||
		!nickname.Valid || !normalized.Valid || !validStoredUser(opponentID.String, nickname.String, normalized.String) ||
		!opponentEnabled.Valid || (opponentEnabled.Int64 != 0 && opponentEnabled.Int64 != 1) || moveCount < 0 {
		return HistoryEntry{}, false
	}

	outcome := ""
	switch {
	case status == StatusFinished && result.Valid &&
		(result.String == spec.decisiveResult || result.String == ResultResignation) && winner.Valid && winner.String == currentUserID:
		outcome = historyOutcomeWin
	case status == StatusFinished && result.Valid &&
		(result.String == spec.decisiveResult || result.String == ResultResignation) && winner.Valid && winner.String == opponentID.String:
		outcome = historyOutcomeLoss
	case spec.allowsDraw && status == StatusFinished && result.Valid && result.String == ResultDraw && !winner.Valid:
		outcome = historyOutcomeDraw
	case status == StatusAbandoned && !result.Valid && !winner.Valid:
		outcome = historyOutcomeAbandoned
	default:
		return HistoryEntry{}, false
	}

	return HistoryEntry{
		ID:               matchID,
		Outcome:          outcome,
		OpponentNickname: nickname.String,
		Color:            Color(currentColor),
		FinishedAt:       time.UnixMilli(finishedMillis.Int64).UTC(),
		MoveCount:        moveCount,
		Format:           format,
	}, true
}

func historyEntryFormat(spec historyGameSpec, config sql.NullString) (string, bool) {
	if !spec.requiresFormat {
		return "", true
	}
	if !config.Valid {
		return "", false
	}
	_, normalized, err := configureRules(rps.NewRules(), json.RawMessage(config.String))
	if err != nil {
		return "", false
	}
	var parsed struct {
		Format string `json:"format"`
	}
	if json.Unmarshal(normalized, &parsed) != nil {
		return "", false
	}
	switch parsed.Format {
	case rps.FormatSingleRound, rps.FormatBestOfThree:
		return parsed.Format, true
	default:
		return "", false
	}
}

func boolToInt(value bool) int {
	if value {
		return 1
	}
	return 0
}

func validHistoryColors(current, opponent Color) bool {
	return current == ColorBlack && opponent == ColorWhite || current == ColorWhite && opponent == ColorBlack
}

func newHistoryFailure(phase, category string, err error) error {
	if !validHistoryPhase(phase) {
		phase = "entries"
	}
	if !validHistoryCategory(category) {
		category = "data_integrity"
	}
	if err == nil {
		err = ErrInternal
	}
	return &historyFailure{phase: phase, category: category, cause: err}
}

func historyDatabaseCategory(ctx context.Context, err error) string {
	if ctx != nil && ctx.Err() != nil || errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return "cancelled"
	}
	return "database"
}

func rollbackReadTransaction(ctx context.Context, transaction *sql.Tx, target *error) {
	rollbackErr := transaction.Rollback()
	if rollbackErr != nil && !errors.Is(rollbackErr, sql.ErrTxDone) && *target == nil {
		*target = newHistoryFailure(
			"rollback", historyDatabaseCategory(ctx, rollbackErr), matchDatabaseError(ctx, rollbackErr),
		)
	}
}

func validHistoryPhase(value string) bool {
	switch value {
	case "begin", "statistics", "entries", "commit", "rollback":
		return true
	default:
		return false
	}
}

func validHistoryCategory(value string) bool {
	switch value {
	case "database", "data_integrity", "cancelled":
		return true
	default:
		return false
	}
}
