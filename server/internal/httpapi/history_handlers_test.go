package httpapi

import (
	"database/sql"
	"encoding/base64"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"me.zqydev/gamebox/server/internal/matches"
)

const (
	historyCursorMatchID   = "11111111-1111-4111-8111-111111111111"
	historyCursorMillis    = int64(1_787_623_200_000)
	canonicalHistoryCursor = "eyJ2IjoxLCJmaW5pc2hlZEF0IjoxNzg3NjIzMjAwMDAwLCJtYXRjaElkIjoiMTExMTExMTEtMTExMS00MTExLTgxMTEtMTExMTExMTExMTExIn0"
)

func TestHistoryCursorCodecRoundTripsOnlyCanonicalUnpaddedV1Payload(t *testing.T) {
	cursor := matches.HistoryCursor{
		FinishedAt: time.UnixMilli(historyCursorMillis).UTC(),
		MatchID:    historyCursorMatchID,
	}
	encoded, err := encodeHistoryCursor(cursor)
	if err != nil || encoded != canonicalHistoryCursor || strings.Contains(encoded, "=") {
		t.Fatalf("encodeHistoryCursor = (%q,%v), want canonical unpadded %q", encoded, err, canonicalHistoryCursor)
	}
	decoded, err := decodeHistoryCursor(canonicalHistoryCursor)
	if err != nil || decoded != cursor {
		t.Fatalf("decodeHistoryCursor = (%+v,%v), want %+v", decoded, err, cursor)
	}
}

func TestHistoryCursorCodecRejectsNoncanonicalOrMalformedValues(t *testing.T) {
	validJSON := `{"v":1,"finishedAt":1787623200000,"matchId":"11111111-1111-4111-8111-111111111111"}`
	tests := []struct {
		name  string
		value string
	}{
		{name: "standard alphabet", value: "+w"},
		{name: "padding", value: canonicalHistoryCursor + "="},
		{name: "non json", value: rawHistoryCursor("not-json")},
		{name: "trailing json", value: rawHistoryCursor(validJSON + `{}`)},
		{name: "leading whitespace", value: rawHistoryCursor(" " + validJSON)},
		{name: "wrong field order", value: rawHistoryCursor(`{"finishedAt":1787623200000,"v":1,"matchId":"11111111-1111-4111-8111-111111111111"}`)},
		{name: "missing version", value: rawHistoryCursor(`{"finishedAt":1787623200000,"matchId":"11111111-1111-4111-8111-111111111111"}`)},
		{name: "missing finished at", value: rawHistoryCursor(`{"v":1,"matchId":"11111111-1111-4111-8111-111111111111"}`)},
		{name: "missing match id", value: rawHistoryCursor(`{"v":1,"finishedAt":1787623200000}`)},
		{name: "extra field", value: rawHistoryCursor(`{"v":1,"finishedAt":1787623200000,"matchId":"11111111-1111-4111-8111-111111111111","extra":true}`)},
		{name: "duplicate version", value: rawHistoryCursor(`{"v":1,"v":1,"finishedAt":1787623200000,"matchId":"11111111-1111-4111-8111-111111111111"}`)},
		{name: "duplicate finished at", value: rawHistoryCursor(`{"v":1,"finishedAt":1787623200000,"finishedAt":1787623200000,"matchId":"11111111-1111-4111-8111-111111111111"}`)},
		{name: "duplicate match id", value: rawHistoryCursor(`{"v":1,"finishedAt":1787623200000,"matchId":"11111111-1111-4111-8111-111111111111","matchId":"11111111-1111-4111-8111-111111111111"}`)},
		{name: "version two", value: rawHistoryCursor(`{"v":2,"finishedAt":1787623200000,"matchId":"11111111-1111-4111-8111-111111111111"}`)},
		{name: "fractional milliseconds", value: rawHistoryCursor(`{"v":1,"finishedAt":1787623200000.5,"matchId":"11111111-1111-4111-8111-111111111111"}`)},
		{name: "string milliseconds", value: rawHistoryCursor(`{"v":1,"finishedAt":"1787623200000","matchId":"11111111-1111-4111-8111-111111111111"}`)},
		{name: "overflow milliseconds", value: rawHistoryCursor(`{"v":1,"finishedAt":9223372036854775808,"matchId":"11111111-1111-4111-8111-111111111111"}`)},
		{name: "milliseconds above Flutter DateTime range", value: rawHistoryCursor(`{"v":1,"finishedAt":8640000000000001,"matchId":"11111111-1111-4111-8111-111111111111"}`)},
		{name: "milliseconds below Flutter DateTime range", value: rawHistoryCursor(`{"v":1,"finishedAt":-8640000000000001,"matchId":"11111111-1111-4111-8111-111111111111"}`)},
		{name: "uppercase uuid", value: rawHistoryCursor(`{"v":1,"finishedAt":1787623200000,"matchId":"11111111-1111-4111-8111-11111111111A"}`)},
		{name: "version six uuid", value: rawHistoryCursor(`{"v":1,"finishedAt":1787623200000,"matchId":"11111111-1111-6111-8111-111111111111"}`)},
		{name: "invalid uuid", value: rawHistoryCursor(`{"v":1,"finishedAt":1787623200000,"matchId":"not-a-uuid"}`)},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			cursor, err := decodeHistoryCursor(test.value)
			if !errors.Is(err, matches.ErrInvalidRequest) || cursor != (matches.HistoryCursor{}) {
				t.Fatalf("decodeHistoryCursor(%q) = (%+v,%v), want zero/%v", test.value, cursor, err, matches.ErrInvalidRequest)
			}
		})
	}
}

func TestHistoryCursorCodecAcceptsInclusiveWireDomainBoundaries(t *testing.T) {
	tests := []struct {
		name  string
		value string
		want  matches.HistoryCursor
	}{
		{
			name:  "minimum timestamp and version one UUID",
			value: rawHistoryCursor(`{"v":1,"finishedAt":-8640000000000000,"matchId":"11111111-1111-1111-8111-111111111111"}`),
			want:  matches.HistoryCursor{FinishedAt: time.UnixMilli(-8_640_000_000_000_000).UTC(), MatchID: "11111111-1111-1111-8111-111111111111"},
		},
		{
			name:  "maximum timestamp and version five UUID",
			value: rawHistoryCursor(`{"v":1,"finishedAt":8640000000000000,"matchId":"11111111-1111-5111-8111-111111111111"}`),
			want:  matches.HistoryCursor{FinishedAt: time.UnixMilli(8_640_000_000_000_000).UTC(), MatchID: "11111111-1111-5111-8111-111111111111"},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			decoded, err := decodeHistoryCursor(test.value)
			if err != nil || decoded != test.want {
				t.Fatalf("decodeHistoryCursor = (%+v,%v), want %+v/nil", decoded, err, test.want)
			}
			encoded, err := encodeHistoryCursor(test.want)
			if err != nil || encoded != test.value {
				t.Fatalf("encodeHistoryCursor = (%q,%v), want %q/nil", encoded, err, test.value)
			}
		})
	}
}

func TestHistoryCursorCodecRejectsNoncanonicalCursorValuesOnEncode(t *testing.T) {
	canonicalTime := time.UnixMilli(historyCursorMillis).UTC()
	tests := []struct {
		name   string
		cursor matches.HistoryCursor
	}{
		{name: "zero time", cursor: matches.HistoryCursor{MatchID: historyCursorMatchID}},
		{name: "non UTC", cursor: matches.HistoryCursor{FinishedAt: canonicalTime.In(time.FixedZone("zero", 0)), MatchID: historyCursorMatchID}},
		{name: "submillisecond", cursor: matches.HistoryCursor{FinishedAt: canonicalTime.Add(time.Microsecond), MatchID: historyCursorMatchID}},
		{name: "uppercase uuid", cursor: matches.HistoryCursor{FinishedAt: canonicalTime, MatchID: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"}},
		{name: "version six uuid", cursor: matches.HistoryCursor{FinishedAt: canonicalTime, MatchID: "11111111-1111-6111-8111-111111111111"}},
		{name: "timestamp above Flutter DateTime range", cursor: matches.HistoryCursor{FinishedAt: time.UnixMilli(8_640_000_000_000_001).UTC(), MatchID: historyCursorMatchID}},
		{name: "timestamp below Flutter DateTime range", cursor: matches.HistoryCursor{FinishedAt: time.UnixMilli(-8_640_000_000_000_001).UTC(), MatchID: historyCursorMatchID}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			encoded, err := encodeHistoryCursor(test.cursor)
			if !errors.Is(err, matches.ErrInvalidRequest) || encoded != "" {
				t.Fatalf("encodeHistoryCursor(%+v) = (%q,%v), want empty/%v", test.cursor, encoded, err, matches.ErrInvalidRequest)
			}
		})
	}
}

func TestGomokuHistoryReturnsContractAndUsesOnlyAuthenticatedUser(t *testing.T) {
	fixture := newAPIFixture(t)
	alice := fixture.register(t, "history-contract-a", "Alice")
	bob := fixture.register(t, "history-contract-b", "Bob")
	carol := fixture.register(t, "history-contract-c", "Carol")

	seedHTTPHistoryMatch(t, fixture.db, historyCursorMatchID, alice.Session.User.ID, bob.Session.User.ID, alice.Session.User.ID, "five", historyCursorMillis, 2)
	seedHTTPHistoryMatch(t, fixture.db, "22222222-2222-4222-8222-222222222222", carol.Session.User.ID, bob.Session.User.ID, bob.Session.User.ID, "resignation", historyCursorMillis-1_000, 1)

	response := fixture.request(t, http.MethodGet, "/v1/games/gomoku/history?limit=50", "", alice.Session.AccessToken)
	want := `{"statistics":{"validMatches":1,"wins":1,"losses":0,"draws":0,"winRate":1},"matches":[{"id":"11111111-1111-4111-8111-111111111111","outcome":"win","opponentNickname":"Bob","color":"black","finishedAt":1787623200000,"moveCount":2}],"nextCursor":null}` + "\n"
	if response.Code != http.StatusOK || response.Body.String() != want {
		t.Fatalf("Alice history=(%d,%s), want 200/%s", response.Code, response.Body.String(), want)
	}

	carolResponse := fixture.request(t, http.MethodGet, "/v1/games/gomoku/history?limit=50", "", carol.Session.AccessToken)
	var carolBody historyResponse
	decodeResponse(t, carolResponse, &carolBody)
	if carolResponse.Code != http.StatusOK || len(carolBody.Matches) != 1 || carolBody.Matches[0].ID != "22222222-2222-4222-8222-222222222222" || carolBody.Matches[0].Outcome != "loss" {
		t.Fatalf("Carol history=(%d,%+v), want only Carol's loss", carolResponse.Code, carolBody)
	}
}

func TestGomokuHistoryReturnsEmptyArrayForNoMatches(t *testing.T) {
	fixture := newAPIFixture(t)
	alice := fixture.register(t, "history-empty", "Alice")
	response := fixture.request(t, http.MethodGet, "/v1/games/gomoku/history", "", alice.Session.AccessToken)
	want := `{"statistics":{"validMatches":0,"wins":0,"losses":0,"draws":0,"winRate":0},"matches":[],"nextCursor":null}` + "\n"
	if response.Code != http.StatusOK || response.Body.String() != want {
		t.Fatalf("empty history=(%d,%s), want 200/%s", response.Code, response.Body.String(), want)
	}
}

func TestGomokuHistoryDefaultsToTwentyAndAcceptsLimitBounds(t *testing.T) {
	fixture := newAPIFixture(t)
	alice := fixture.register(t, "history-limit-a", "Alice")
	bob := fixture.register(t, "history-limit-b", "Bob")
	for index := 0; index < 21; index++ {
		matchID := fmt.Sprintf("%08x-1111-4111-8111-%012x", index+1, index+1)
		seedHTTPHistoryMatch(t, fixture.db, matchID, alice.Session.User.ID, bob.Session.User.ID, alice.Session.User.ID, "five", historyCursorMillis-int64(index)*1_000, 0)
	}

	defaultResponse := fixture.request(t, http.MethodGet, "/v1/games/gomoku/history", "", alice.Session.AccessToken)
	var defaultBody historyResponse
	decodeResponse(t, defaultResponse, &defaultBody)
	if defaultResponse.Code != http.StatusOK || len(defaultBody.Matches) != 20 || defaultBody.NextCursor == nil || defaultBody.Statistics.ValidMatches != 21 {
		t.Fatalf("default history=(%d,%+v), want 20 rows, cursor, 21 stats", defaultResponse.Code, defaultBody)
	}

	oneResponse := fixture.request(t, http.MethodGet, "/v1/games/gomoku/history?limit=1", "", alice.Session.AccessToken)
	var oneBody historyResponse
	decodeResponse(t, oneResponse, &oneBody)
	if oneResponse.Code != http.StatusOK || len(oneBody.Matches) != 1 || oneBody.NextCursor == nil {
		t.Fatalf("limit one history=(%d,%+v), want one row and cursor", oneResponse.Code, oneBody)
	}

	fiftyResponse := fixture.request(t, http.MethodGet, "/v1/games/gomoku/history?limit=50", "", alice.Session.AccessToken)
	var fiftyBody historyResponse
	decodeResponse(t, fiftyResponse, &fiftyBody)
	if fiftyResponse.Code != http.StatusOK || len(fiftyBody.Matches) != 21 || fiftyBody.NextCursor != nil {
		t.Fatalf("limit fifty history=(%d,%+v), want all 21 rows and no cursor", fiftyResponse.Code, fiftyBody)
	}
}

func TestGomokuHistoryRejectsInvalidAuthenticationQueryAndMethod(t *testing.T) {
	fixture := newAPIFixture(t)
	alice := fixture.register(t, "history-errors", "Alice")

	unauthorized := fixture.request(t, http.MethodGet, "/v1/games/gomoku/history", "", "authorization-secret-marker")
	if unauthorized.Code != http.StatusUnauthorized || responseErrorCode(t, unauthorized) != "unauthorized" {
		t.Fatalf("invalid token=(%d,%s), want 401/unauthorized", unauthorized.Code, unauthorized.Body.String())
	}

	tests := []struct {
		name  string
		query string
	}{
		{name: "zero limit", query: "limit=0"},
		{name: "limit above maximum", query: "limit=51"},
		{name: "empty limit", query: "limit="},
		{name: "non integer limit", query: "limit=1.5"},
		{name: "unknown parameter", query: "userId=" + alice.Session.User.ID},
		{name: "duplicate limit", query: "limit=1&limit=50"},
		{name: "duplicate cursor", query: "cursor=cursor-secret-marker&cursor=" + canonicalHistoryCursor},
		{name: "empty cursor", query: "cursor="},
		{name: "invalid cursor", query: "cursor=cursor-secret-marker"},
		{name: "malformed query", query: "limit=1;cursor=cursor-secret-marker"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			response := fixture.request(t, http.MethodGet, "/v1/games/gomoku/history?"+test.query, "", alice.Session.AccessToken)
			if response.Code != http.StatusBadRequest || responseErrorCode(t, response) != "invalid_request" {
				t.Fatalf("response=(%d,%s), want 400/invalid_request", response.Code, response.Body.String())
			}
		})
	}

	fallback := fixture.request(t, http.MethodOptions, "/v1/games/gomoku/history", "", "")
	if fallback.Code != http.StatusMethodNotAllowed || fallback.Header().Get("Allow") != "GET, HEAD" || responseErrorCode(t, fallback) != "invalid_request" {
		t.Fatalf("method fallback=(%d Allow=%q body=%s), want 405 GET, HEAD/invalid_request", fallback.Code, fallback.Header().Get("Allow"), fallback.Body.String())
	}

	logs := fixture.logs.String()
	for _, secret := range []string{"authorization-secret-marker", "cursor-secret-marker", alice.Session.User.ID} {
		if strings.Contains(logs, secret) {
			t.Fatalf("request input %q leaked into logs: %s", secret, logs)
		}
	}
}

func TestGomokuHistoryInternalFailuresReturnGenericErrorAndOnlyFixedDiagnostics(t *testing.T) {
	t.Run("data integrity", func(t *testing.T) {
		fixture := newAPIFixture(t)
		alice := fixture.register(t, "history-corrupt-a", "Alice")
		bob := fixture.register(t, "history-corrupt-b", "Bob")
		seedHTTPHistoryMatch(t, fixture.db, historyCursorMatchID, alice.Session.User.ID, bob.Session.User.ID, alice.Session.User.ID, "corrupt-result-marker", historyCursorMillis, 0)

		response := fixture.request(t, http.MethodGet, "/v1/games/gomoku/history?cursor="+canonicalHistoryCursor, "", alice.Session.AccessToken)
		assertHistoryInternalFailure(t, fixture, response, "statistics", "data_integrity", []string{
			alice.Session.AccessToken, alice.Session.User.ID, bob.Session.User.ID, "Alice", "Bob", canonicalHistoryCursor, "corrupt-result-marker", "SELECT", "match_players",
		})
	})

	t.Run("version six row outside limited page", func(t *testing.T) {
		fixture := newAPIFixture(t)
		alice := fixture.register(t, "history-v6-a", "Alice")
		bob := fixture.register(t, "history-v6-b", "Bob")
		seedHTTPHistoryMatch(t, fixture.db, historyCursorMatchID, alice.Session.User.ID, bob.Session.User.ID, alice.Session.User.ID, "five", historyCursorMillis, 0)
		v6ID := "11111111-1111-6111-8111-111111111111"
		seedHTTPHistoryMatch(t, fixture.db, v6ID, alice.Session.User.ID, bob.Session.User.ID, alice.Session.User.ID, "five", historyCursorMillis-1_000, 0)

		response := fixture.request(t, http.MethodGet, "/v1/games/gomoku/history?limit=1", "", alice.Session.AccessToken)
		assertHistoryInternalFailure(t, fixture, response, "statistics", "data_integrity", []string{
			alice.Session.AccessToken, alice.Session.User.ID, bob.Session.User.ID, "Alice", "Bob", v6ID, "SELECT", "match_players",
		})
	})

	t.Run("out of range timestamp", func(t *testing.T) {
		fixture := newAPIFixture(t)
		alice := fixture.register(t, "history-time-a", "Alice")
		bob := fixture.register(t, "history-time-b", "Bob")
		corruptMillis := int64(-8_640_000_000_000_001)
		seedHTTPHistoryMatch(t, fixture.db, historyCursorMatchID, alice.Session.User.ID, bob.Session.User.ID, alice.Session.User.ID, "five", corruptMillis, 0)

		response := fixture.request(t, http.MethodGet, "/v1/games/gomoku/history", "", alice.Session.AccessToken)
		assertHistoryInternalFailure(t, fixture, response, "statistics", "data_integrity", []string{
			alice.Session.AccessToken, alice.Session.User.ID, bob.Session.User.ID, "Alice", "Bob", historyCursorMatchID, fmt.Sprint(corruptMillis), "SELECT", "match_players",
		})
	})

	t.Run("database", func(t *testing.T) {
		fixture := newAPIFixture(t)
		alice := fixture.register(t, "history-database", "Alice")
		if _, err := fixture.db.Exec(`DROP TABLE match_players`); err != nil {
			t.Fatalf("drop match_players: %v", err)
		}
		response := fixture.request(t, http.MethodGet, "/v1/games/gomoku/history?cursor="+canonicalHistoryCursor, "", alice.Session.AccessToken)
		assertHistoryInternalFailure(t, fixture, response, "statistics", "database", []string{
			alice.Session.AccessToken, alice.Session.User.ID, "Alice", canonicalHistoryCursor, "no such table", "match_players", "SELECT",
		})
	})
}

func rawHistoryCursor(value string) string {
	return base64.RawURLEncoding.EncodeToString([]byte(value))
}

func seedHTTPHistoryMatch(
	t *testing.T,
	db *sql.DB,
	matchID, currentUserID, opponentUserID, winnerUserID, result string,
	finishedAt int64,
	acceptedMoves int,
) {
	t.Helper()
	if _, err := db.Exec(`
INSERT INTO matches(id,game_id,status,revision,result,winner_user_id,created_at,updated_at,finished_at)
VALUES (?,'gomoku','finished',0,?,?,?,?,?)`, matchID, result, winnerUserID, finishedAt-1_000, finishedAt, finishedAt); err != nil {
		t.Fatalf("insert history match %s: %v", matchID, err)
	}
	if _, err := db.Exec(`INSERT INTO match_players(match_id,user_id,seat,color) VALUES (?,?,0,'black'),(?,?,1,'white')`, matchID, currentUserID, matchID, opponentUserID); err != nil {
		t.Fatalf("insert history players %s: %v", matchID, err)
	}
	for revision := 1; revision <= acceptedMoves; revision++ {
		if _, err := db.Exec(`
INSERT INTO match_events(match_id,revision,event_type,action_id,actor_user_id,payload_json,created_at)
VALUES (?,?,'gomoku.move.accepted',?,?,'{}',?)`, matchID, revision, fmt.Sprintf("action-%d", revision), currentUserID, finishedAt-int64(acceptedMoves-revision)); err != nil {
			t.Fatalf("insert history event %s/%d: %v", matchID, revision, err)
		}
	}
}

func assertHistoryInternalFailure(t *testing.T, fixture apiFixture, response *httptest.ResponseRecorder, phase, category string, forbidden []string) {
	t.Helper()
	if response.Code != http.StatusInternalServerError || responseErrorCode(t, response) != "internal_error" {
		t.Fatalf("internal failure=(%d,%s), want 500/internal_error", response.Code, response.Body.String())
	}
	requestID := response.Header().Get("X-Request-ID")
	wantDiagnostic := fmt.Sprintf("request_id=%s feature=match_history phase=%s category=%s", requestID, phase, category)
	diagnostics := make([]string, 0, 1)
	for line := range strings.SplitSeq(strings.TrimSpace(fixture.logs.String()), "\n") {
		if strings.Contains(line, "feature=match_history") {
			diagnostics = append(diagnostics, line)
		}
	}
	if len(diagnostics) != 1 || diagnostics[0] != wantDiagnostic {
		t.Fatalf("diagnostics=%q, want only %q; all logs=%s", diagnostics, wantDiagnostic, fixture.logs.String())
	}
	combined := fixture.logs.String() + response.Body.String()
	for _, value := range forbidden {
		if value != "" && strings.Contains(combined, value) {
			t.Fatalf("internal failure leaked %q: %s", value, combined)
		}
	}
}
