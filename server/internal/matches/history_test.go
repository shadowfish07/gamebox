package matches

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"me.zqydev/gamebox/server/internal/games/gomoku"
	"me.zqydev/gamebox/server/internal/protocol"
)

const (
	historyFiveID    = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa6"
	historyResignID  = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa5"
	historyDrawID    = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa4"
	historyAbandonID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3"
	historyCancelID  = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2"
	historyActiveID  = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1"
)

func TestListHistoryMapsTerminalOutcomesAndStatisticsFromBothViews(t *testing.T) {
	fixture := newFixture(t)
	finished := time.UnixMilli(fixture.now.UTC().UnixMilli()).UTC()
	seedHistoryMatch(t, fixture.db, historyFiveID, StatusFinished, ResultFive, initiatorID, finished.Add(-time.Minute), true)
	seedHistoryMatch(t, fixture.db, historyResignID, StatusFinished, ResultResignation, opponentID, finished.Add(-2*time.Minute), true)
	seedHistoryMatch(t, fixture.db, historyDrawID, StatusFinished, ResultDraw, "", finished.Add(-3*time.Minute), true)
	seedHistoryMatch(t, fixture.db, historyAbandonID, StatusAbandoned, "", "", finished.Add(-4*time.Minute), true)
	seedHistoryMatch(t, fixture.db, historyCancelID, StatusCancelled, "", "", finished.Add(-5*time.Minute), true)
	seedHistoryMatch(t, fixture.db, historyActiveID, StatusActive, "", "", time.Time{}, true)

	tests := []struct {
		name       string
		userID     string
		nicknames  []string
		colors     []Color
		outcomes   []string
		statistics HistoryStatistics
	}{
		{
			name: "initiator view", userID: initiatorID,
			nicknames: []string{"Opponent", "Opponent", "Opponent", "Opponent"},
			colors:    []Color{ColorBlack, ColorBlack, ColorBlack, ColorBlack},
			outcomes:  []string{"win", "loss", "draw", "abandoned"},
			statistics: HistoryStatistics{
				ValidMatches: 3, Wins: 1, Losses: 1, Draws: 1, WinRate: 1.0 / 3.0,
			},
		},
		{
			name: "opponent view", userID: opponentID,
			nicknames: []string{"Initiator", "Initiator", "Initiator", "Initiator"},
			colors:    []Color{ColorWhite, ColorWhite, ColorWhite, ColorWhite},
			outcomes:  []string{"loss", "win", "draw", "abandoned"},
			statistics: HistoryStatistics{
				ValidMatches: 3, Wins: 1, Losses: 1, Draws: 1, WinRate: 1.0 / 3.0,
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			page, err := fixture.service(t, bytes.NewReader([]byte{0})).ListHistory(
				context.Background(), gomoku.GameID, test.userID, HistoryPageRequest{Limit: 20},
			)
			if err != nil {
				t.Fatalf("ListHistory: %v", err)
			}
			if page.Statistics != test.statistics {
				t.Fatalf("statistics = %+v, want %+v", page.Statistics, test.statistics)
			}
			if page.NextCursor != nil || len(page.Matches) != 4 {
				t.Fatalf("page size/cursor = %d/%+v, want 4/nil", len(page.Matches), page.NextCursor)
			}
			for index, entry := range page.Matches {
				if entry.Outcome != test.outcomes[index] || entry.OpponentNickname != test.nicknames[index] || entry.Color != test.colors[index] {
					t.Errorf("entry %d = %+v, want outcome=%q nickname=%q color=%q", index, entry, test.outcomes[index], test.nicknames[index], test.colors[index])
				}
				if entry.FinishedAt.Location() != time.UTC || entry.FinishedAt.Nanosecond()%int(time.Millisecond) != 0 {
					t.Errorf("entry %d finishedAt = %v, want canonical UTC milliseconds", index, entry.FinishedAt)
				}
			}
		})
	}
}

func TestListHistoryUsesStableFinishedAtAndIDCursor(t *testing.T) {
	fixture := newFixture(t)
	finished := time.UnixMilli(fixture.now.UTC().UnixMilli()).UTC()
	ids := []string{
		"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa4",
		"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3",
		"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2",
		"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1",
	}
	for index, id := range ids {
		at := finished
		if index == len(ids)-1 {
			at = finished.Add(-time.Millisecond)
		}
		seedHistoryMatch(t, fixture.db, id, StatusFinished, ResultDraw, "", at, true)
	}
	service := fixture.service(t, bytes.NewReader([]byte{0}))
	first, err := service.ListHistory(context.Background(), gomoku.GameID, initiatorID, HistoryPageRequest{Limit: 2})
	if err != nil {
		t.Fatalf("first page: %v", err)
	}
	if len(first.Matches) != 2 || first.Matches[0].ID != ids[0] || first.Matches[1].ID != ids[1] {
		t.Fatalf("first IDs = %v, want %v", historyIDs(first.Matches), ids[:2])
	}
	if first.NextCursor == nil || first.NextCursor.MatchID != ids[1] || first.NextCursor.FinishedAt != finished {
		t.Fatalf("first cursor = %+v, want %s/%v", first.NextCursor, ids[1], finished)
	}
	second, err := service.ListHistory(context.Background(), gomoku.GameID, initiatorID, HistoryPageRequest{Limit: 2, Cursor: first.NextCursor})
	if err != nil {
		t.Fatalf("second page: %v", err)
	}
	if len(second.Matches) != 2 || second.Matches[0].ID != ids[2] || second.Matches[1].ID != ids[3] || second.NextCursor != nil {
		t.Fatalf("second page = %v cursor=%+v, want %v/nil", historyIDs(second.Matches), second.NextCursor, ids[2:])
	}
	seen := map[string]int{}
	for _, entry := range append(first.Matches, second.Matches...) {
		seen[entry.ID]++
	}
	for _, id := range ids {
		if seen[id] != 1 {
			t.Errorf("match %s appeared %d times, want once", id, seen[id])
		}
	}
}

func TestListHistoryCountsOnlyAcceptedMoves(t *testing.T) {
	fixture := newFixture(t)
	finished := time.UnixMilli(fixture.now.UTC().UnixMilli()).UTC()
	seedHistoryMatch(t, fixture.db, historyResignID, StatusFinished, ResultResignation, opponentID, finished, true)
	seedHistoryEvent(t, fixture.db, historyResignID, 1, gomoku.MoveAccepted)
	seedHistoryEvent(t, fixture.db, historyResignID, 2, gomoku.MoveAccepted)
	seedHistoryEvent(t, fixture.db, historyResignID, 3, protocol.TypeGomokuResigned)

	page, err := fixture.service(t, bytes.NewReader([]byte{0})).ListHistory(
		context.Background(), gomoku.GameID, initiatorID, HistoryPageRequest{Limit: 20},
	)
	if err != nil {
		t.Fatalf("ListHistory: %v", err)
	}
	if len(page.Matches) != 1 || page.Matches[0].MoveCount != 2 {
		t.Fatalf("matches = %+v, want one entry with two accepted moves", page.Matches)
	}
}

func TestListHistoryRejectsInvalidRequestAndCorruptTerminalRows(t *testing.T) {
	t.Run("request", func(t *testing.T) {
		fixture := newFixture(t)
		canonicalTime := time.UnixMilli(fixture.now.UTC().UnixMilli()).UTC()
		tests := []struct {
			name    string
			gameID  string
			userID  string
			request HistoryPageRequest
		}{
			{name: "zero limit", gameID: gomoku.GameID, userID: initiatorID, request: HistoryPageRequest{Limit: 0}},
			{name: "limit above maximum", gameID: gomoku.GameID, userID: initiatorID, request: HistoryPageRequest{Limit: 51}},
			{name: "unknown game", gameID: "chess", userID: initiatorID, request: HistoryPageRequest{Limit: 20}},
			{name: "noncanonical user", gameID: gomoku.GameID, userID: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", request: HistoryPageRequest{Limit: 20}},
			{name: "zero cursor time", gameID: gomoku.GameID, userID: initiatorID, request: HistoryPageRequest{Limit: 20, Cursor: &HistoryCursor{MatchID: historyFiveID}}},
			{name: "non UTC cursor", gameID: gomoku.GameID, userID: initiatorID, request: HistoryPageRequest{Limit: 20, Cursor: &HistoryCursor{FinishedAt: canonicalTime.In(time.FixedZone("zero", 0)), MatchID: historyFiveID}}},
			{name: "submillisecond cursor", gameID: gomoku.GameID, userID: initiatorID, request: HistoryPageRequest{Limit: 20, Cursor: &HistoryCursor{FinishedAt: canonicalTime.Add(time.Microsecond), MatchID: historyFiveID}}},
			{name: "noncanonical cursor id", gameID: gomoku.GameID, userID: initiatorID, request: HistoryPageRequest{Limit: 20, Cursor: &HistoryCursor{FinishedAt: canonicalTime, MatchID: strings.ToUpper(historyFiveID)}}},
			{name: "version six cursor id", gameID: gomoku.GameID, userID: initiatorID, request: HistoryPageRequest{Limit: 20, Cursor: &HistoryCursor{FinishedAt: canonicalTime, MatchID: "11111111-1111-6111-8111-111111111111"}}},
			{name: "cursor above Flutter DateTime range", gameID: gomoku.GameID, userID: initiatorID, request: HistoryPageRequest{Limit: 20, Cursor: &HistoryCursor{FinishedAt: time.UnixMilli(8_640_000_000_000_001).UTC(), MatchID: historyFiveID}}},
			{name: "cursor below Flutter DateTime range", gameID: gomoku.GameID, userID: initiatorID, request: HistoryPageRequest{Limit: 20, Cursor: &HistoryCursor{FinishedAt: time.UnixMilli(-8_640_000_000_000_001).UTC(), MatchID: historyFiveID}}},
		}
		service := fixture.service(t, bytes.NewReader([]byte{0}))
		for _, test := range tests {
			t.Run(test.name, func(t *testing.T) {
				page, err := service.ListHistory(context.Background(), test.gameID, test.userID, test.request)
				if !errors.Is(err, ErrInvalidRequest) || !historyPageIsZero(page) {
					t.Fatalf("ListHistory = (%+v, %v), want zero page/%v", page, err, ErrInvalidRequest)
				}
				if _, _, ok := HistoryFailureMetadata(err); ok {
					t.Fatalf("invalid request unexpectedly has internal failure metadata: %v", err)
				}
			})
		}
	})

	corruptions := []struct {
		name  string
		limit int
		setup func(t *testing.T, fixture fixture)
	}{
		{name: "unknown result", setup: func(t *testing.T, fixture fixture) {
			seedHistoryMatch(t, fixture.db, historyFiveID, StatusFinished, "mystery", initiatorID, canonicalHistoryTime(fixture), true)
		}},
		{name: "missing result", setup: func(t *testing.T, fixture fixture) {
			seedHistoryMatch(t, fixture.db, historyFiveID, StatusFinished, "", initiatorID, canonicalHistoryTime(fixture), true)
		}},
		{name: "winner outside match", setup: func(t *testing.T, fixture fixture) {
			seedHistoryMatch(t, fixture.db, historyFiveID, StatusFinished, ResultFive, thirdID, canonicalHistoryTime(fixture), true)
		}},
		{name: "missing opponent", setup: func(t *testing.T, fixture fixture) {
			seedHistoryMatch(t, fixture.db, historyFiveID, StatusFinished, ResultFive, initiatorID, canonicalHistoryTime(fixture), false)
		}},
		{name: "illegal color", setup: func(t *testing.T, fixture fixture) {
			seedHistoryMatch(t, fixture.db, historyFiveID, StatusFinished, ResultFive, initiatorID, canonicalHistoryTime(fixture), true)
			if _, err := fixture.db.Exec(`PRAGMA ignore_check_constraints=ON`); err != nil {
				t.Fatalf("allow corrupt fixture: %v", err)
			}
			if _, err := fixture.db.Exec(`UPDATE match_players SET color='green' WHERE match_id=? AND user_id=?`, historyFiveID, initiatorID); err != nil {
				t.Fatalf("corrupt color: %v", err)
			}
		}},
		{name: "missing finished timestamp", setup: func(t *testing.T, fixture fixture) {
			seedHistoryMatch(t, fixture.db, historyFiveID, StatusFinished, ResultFive, initiatorID, canonicalHistoryTime(fixture), true)
			if _, err := fixture.db.Exec(`UPDATE matches SET finished_at=NULL WHERE id=?`, historyFiveID); err != nil {
				t.Fatalf("remove finished_at: %v", err)
			}
		}},
		{name: "version six match outside limited page", limit: 1, setup: func(t *testing.T, fixture fixture) {
			finished := canonicalHistoryTime(fixture)
			seedHistoryMatch(t, fixture.db, historyFiveID, StatusFinished, ResultFive, initiatorID, finished, true)
			seedHistoryMatch(t, fixture.db, "11111111-1111-6111-8111-111111111111", StatusFinished, ResultFive, initiatorID, finished.Add(-time.Second), true)
		}},
		{name: "timestamp above Flutter DateTime range", setup: func(t *testing.T, fixture fixture) {
			seedHistoryMatch(t, fixture.db, historyFiveID, StatusFinished, ResultFive, initiatorID, canonicalHistoryTime(fixture), true)
			if _, err := fixture.db.Exec(`UPDATE matches SET finished_at=? WHERE id=?`, int64(8_640_000_000_000_001), historyFiveID); err != nil {
				t.Fatalf("corrupt finished_at: %v", err)
			}
		}},
		{name: "timestamp below Flutter DateTime range outside limited page", limit: 1, setup: func(t *testing.T, fixture fixture) {
			finished := canonicalHistoryTime(fixture)
			seedHistoryMatch(t, fixture.db, historyFiveID, StatusFinished, ResultFive, initiatorID, finished, true)
			seedHistoryMatch(t, fixture.db, historyResignID, StatusFinished, ResultFive, initiatorID, finished.Add(-time.Second), true)
			if _, err := fixture.db.Exec(`UPDATE matches SET finished_at=? WHERE id=?`, int64(-8_640_000_000_000_001), historyResignID); err != nil {
				t.Fatalf("corrupt finished_at: %v", err)
			}
		}},
	}
	for _, test := range corruptions {
		t.Run(test.name, func(t *testing.T) {
			fixture := newFixture(t)
			test.setup(t, fixture)
			limit := test.limit
			if limit == 0 {
				limit = 20
			}
			page, err := fixture.service(t, bytes.NewReader([]byte{0})).ListHistory(
				context.Background(), gomoku.GameID, initiatorID, HistoryPageRequest{Limit: limit},
			)
			if !errors.Is(err, ErrInternal) || !historyPageIsZero(page) {
				t.Fatalf("ListHistory = (%+v, %v), want zero page/%v", page, err, ErrInternal)
			}
			phase, category, ok := HistoryFailureMetadata(err)
			if !ok || phase != "statistics" || category != "data_integrity" {
				t.Fatalf("metadata = (%q,%q,%v), want statistics/data_integrity/true", phase, category, ok)
			}
		})
	}
}

func TestListHistoryRejectsUnknownOrDisabledCaller(t *testing.T) {
	tests := []struct {
		name   string
		userID string
		setup  func(t *testing.T, fixture fixture)
	}{
		{name: "unknown", userID: "44444444-4444-4444-8444-444444444444"},
		{name: "disabled", userID: initiatorID, setup: func(t *testing.T, fixture fixture) {
			if _, err := fixture.db.Exec(`UPDATE users SET enabled=0 WHERE id=?`, initiatorID); err != nil {
				t.Fatalf("disable user: %v", err)
			}
		}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fixture := newFixture(t)
			if test.setup != nil {
				test.setup(t, fixture)
			}
			page, err := fixture.service(t, bytes.NewReader([]byte{0})).ListHistory(
				context.Background(), gomoku.GameID, test.userID, HistoryPageRequest{Limit: 20},
			)
			if !errors.Is(err, ErrInvalidRequest) || !historyPageIsZero(page) {
				t.Fatalf("ListHistory = (%+v, %v), want zero page/%v", page, err, ErrInvalidRequest)
			}
		})
	}
}

func TestListHistoryClassifiesCancellationAndBeginFailureWithoutDetails(t *testing.T) {
	t.Run("cancelled", func(t *testing.T) {
		fixture := newFixture(t)
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		_, err := fixture.service(t, bytes.NewReader([]byte{0})).ListHistory(ctx, gomoku.GameID, initiatorID, HistoryPageRequest{Limit: 20})
		phase, category, ok := HistoryFailureMetadata(err)
		if !errors.Is(err, context.Canceled) || !ok || phase != "begin" || category != "cancelled" {
			t.Fatalf("cancelled error/metadata = (%v,%q,%q,%v)", err, phase, category, ok)
		}
	})

	t.Run("database", func(t *testing.T) {
		fixture := newFixture(t)
		service := fixture.service(t, bytes.NewReader([]byte{0}))
		if err := fixture.db.Close(); err != nil {
			t.Fatalf("close database: %v", err)
		}
		_, err := service.ListHistory(context.Background(), gomoku.GameID, initiatorID, HistoryPageRequest{Limit: 20})
		phase, category, ok := HistoryFailureMetadata(err)
		if !errors.Is(err, ErrInternal) || !ok || phase != "begin" || category != "database" {
			t.Fatalf("database error/metadata = (%v,%q,%q,%v)", err, phase, category, ok)
		}
		if strings.Contains(strings.ToLower(err.Error()), "sql") || strings.Contains(err.Error(), initiatorID) {
			t.Fatalf("database failure exposed details: %q", err)
		}
	})
}

func TestListHistoryRollsBackFailedReadTransaction(t *testing.T) {
	fixture := newFixture(t)
	fixture.db.SetMaxOpenConns(1)
	seedHistoryMatch(t, fixture.db, historyFiveID, StatusFinished, "corrupt", initiatorID, canonicalHistoryTime(fixture), true)
	_, err := fixture.service(t, bytes.NewReader([]byte{0})).ListHistory(
		context.Background(), gomoku.GameID, initiatorID, HistoryPageRequest{Limit: 20},
	)
	if !errors.Is(err, ErrInternal) {
		t.Fatalf("ListHistory error = %v, want %v", err, ErrInternal)
	}
	writeContext, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if _, err := fixture.db.ExecContext(writeContext, `UPDATE users SET updated_at=updated_at+1 WHERE id=?`, initiatorID); err != nil {
		t.Fatalf("write after failed history read proves transaction was not released: %v", err)
	}
}

func TestListHistoryQueryPlan(t *testing.T) {
	fixture := newFixture(t)
	rows, err := fixture.db.Query(`
EXPLAIN QUERY PLAN
SELECT matches.id
FROM match_players AS current_player
JOIN matches ON matches.id=current_player.match_id
WHERE current_player.user_id=? AND matches.game_id=?
  AND matches.status IN ('finished','abandoned')
ORDER BY matches.finished_at DESC,matches.id DESC
LIMIT ?`, initiatorID, gomoku.GameID, 21)
	if err != nil {
		t.Fatalf("explain history query: %v", err)
	}
	defer rows.Close()
	var details []string
	for rows.Next() {
		var id, parent, notUsed int
		var detail string
		if err := rows.Scan(&id, &parent, &notUsed, &detail); err != nil {
			t.Fatalf("scan query plan: %v", err)
		}
		details = append(details, detail)
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("query plan rows: %v", err)
	}
	plan := strings.Join(details, "\n")
	if !strings.Contains(plan, "idx_match_players_user_id_match_id") {
		t.Fatalf("query plan did not use membership entry index:\n%s", plan)
	}
	if !strings.Contains(plan, "sqlite_autoindex_matches_1") {
		t.Fatalf("query plan did not use the matches primary key lookup:\n%s", plan)
	}
	t.Logf("history query plan:\n%s", plan)
}

func canonicalHistoryTime(fixture fixture) time.Time {
	return time.UnixMilli(fixture.now.UTC().UnixMilli()).UTC()
}

func seedHistoryMatch(t *testing.T, db *sql.DB, id, status, result, winner string, finishedAt time.Time, includeOpponent bool) {
	t.Helper()
	var resultValue, winnerValue, finishedValue any
	if result != "" {
		resultValue = result
	}
	if winner != "" {
		winnerValue = winner
	}
	if !finishedAt.IsZero() {
		finishedValue = finishedAt.UTC().UnixMilli()
	}
	created := int64(1_700_000_000_000)
	if _, err := db.Exec(`
INSERT INTO matches(id,game_id,status,revision,result,winner_user_id,created_at,updated_at,finished_at)
VALUES (?,?,?,?,?,?,?,?,?)`, id, gomoku.GameID, status, 0, resultValue, winnerValue, created, created, finishedValue); err != nil {
		t.Fatalf("insert history match %s: %v", id, err)
	}
	if _, err := db.Exec(`INSERT INTO match_players(match_id,user_id,seat,color) VALUES (?,?,0,?)`, id, initiatorID, ColorBlack); err != nil {
		t.Fatalf("insert current player for %s: %v", id, err)
	}
	if includeOpponent {
		if _, err := db.Exec(`INSERT INTO match_players(match_id,user_id,seat,color) VALUES (?,?,1,?)`, id, opponentID, ColorWhite); err != nil {
			t.Fatalf("insert opponent for %s: %v", id, err)
		}
	}
}

func seedHistoryEvent(t *testing.T, db *sql.DB, matchID string, revision int64, eventType string) {
	t.Helper()
	actionID := fmt.Sprintf("%08d-bbbb-4bbb-8bbb-bbbbbbbbbbbb", revision)
	if _, err := db.Exec(`
INSERT INTO match_events(match_id,revision,event_type,action_id,actor_user_id,payload_json,created_at)
VALUES (?,?,?,?,?,'{}',?)`, matchID, revision, eventType, actionID, initiatorID, int64(1_700_000_000_000)+revision); err != nil {
		t.Fatalf("insert event %d for %s: %v", revision, matchID, err)
	}
}

func historyIDs(entries []HistoryEntry) []string {
	ids := make([]string, len(entries))
	for index, entry := range entries {
		ids[index] = entry.ID
	}
	return ids
}

func historyPageIsZero(page HistoryPage) bool {
	return page.Statistics == (HistoryStatistics{}) && page.Matches == nil && page.NextCursor == nil
}
