package httpapi

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"

	"me.zqydev/gamebox/server/internal/auth"
	"me.zqydev/gamebox/server/internal/clock"
	"me.zqydev/gamebox/server/internal/games"
	"me.zqydev/gamebox/server/internal/games/gomoku"
	"me.zqydev/gamebox/server/internal/matches"
	"me.zqydev/gamebox/server/internal/store"
)

const (
	testJWTSecret   = "http-api-test-jwt-secret-at-least-thirty-two-bytes"
	testTokenPepper = "http-api-test-token-pepper-at-least-thirty-two-bytes"
)

type recordedPublication struct {
	matchID string
	event   matches.Event
}

type recordingPublisher struct {
	mu     sync.Mutex
	events []recordedPublication
}

func (publisher *recordingPublisher) Publish(matchID string, event matches.Event) {
	publisher.mu.Lock()
	defer publisher.mu.Unlock()
	publisher.events = append(publisher.events, recordedPublication{matchID: matchID, event: event})
}

func (publisher *recordingPublisher) snapshot() []recordedPublication {
	publisher.mu.Lock()
	defer publisher.mu.Unlock()
	return append([]recordedPublication(nil), publisher.events...)
}

type apiFixture struct {
	db        *sql.DB
	clock     *clock.Fake
	auth      *auth.Service
	matches   *matches.Service
	handler   http.Handler
	logs      *bytes.Buffer
	publisher *recordingPublisher
	now       time.Time
}

func newAPIFixture(t *testing.T) apiFixture {
	t.Helper()
	db, err := store.Open(context.Background(), filepath.Join(t.TempDir(), "gamebox.sqlite"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() {
		if err := db.Close(); err != nil {
			t.Errorf("close store: %v", err)
		}
	})
	now := time.Date(2026, time.August, 20, 12, 34, 56, 789123456, time.FixedZone("fixture", 8*60*60))
	testClock := clock.NewFake(now)
	authService, err := auth.NewService(db, testClock, auth.ServiceConfig{
		JWTSecret:   []byte(testJWTSecret),
		TokenPepper: testTokenPepper,
	})
	if err != nil {
		t.Fatalf("new auth service: %v", err)
	}
	matchService, err := matches.NewServiceWithConfig(db, games.NewRegistry(), testClock, matches.ServiceConfig{
		ColorRandom:        bytes.NewReader(bytes.Repeat([]byte{0}, 64)),
		LaunchTicketRandom: bytes.NewReader(bytes.Repeat([]byte{1}, 32*64)),
		TokenPepper:        testTokenPepper,
	})
	if err != nil {
		t.Fatalf("new match service: %v", err)
	}
	logs := &bytes.Buffer{}
	publisher := &recordingPublisher{}
	handler, err := NewRouter(RouterConfig{
		Auth:       authService,
		Matches:    matchService,
		Games:      games.NewRegistry(),
		Publisher:  publisher,
		Logger:     log.New(logs, "", 0),
		RequestIDs: sequentialRequestIDs(),
	})
	if err != nil {
		t.Fatalf("new router: %v", err)
	}
	return apiFixture{db: db, clock: testClock, auth: authService, matches: matchService, handler: handler, logs: logs, publisher: publisher, now: now}
}

func sequentialRequestIDs() func() (string, error) {
	var mu sync.Mutex
	var next uint64 = 1
	return func() (string, error) {
		mu.Lock()
		defer mu.Unlock()
		id := fmt.Sprintf("00000000-0000-4000-8000-%012x", next)
		next++
		return id, nil
	}
}

func (fixture apiFixture) addInvite(t *testing.T, plaintext string) {
	t.Helper()
	hash, err := auth.HashToken(testTokenPepper, plaintext)
	if err != nil {
		t.Fatalf("hash invite: %v", err)
	}
	if _, err := fixture.db.Exec(`INSERT INTO invite_codes(code_hash,created_at) VALUES (?,?)`, hash, fixture.now.Add(-time.Hour).UnixMilli()); err != nil {
		t.Fatalf("insert invite: %v", err)
	}
}

type sessionResponse struct {
	Session struct {
		User struct {
			ID       string `json:"id"`
			Nickname string `json:"nickname"`
		} `json:"user"`
		AccessToken      string `json:"accessToken"`
		AccessExpiresAt  int64  `json:"accessExpiresAt"`
		RefreshToken     string `json:"refreshToken"`
		RefreshExpiresAt int64  `json:"refreshExpiresAt"`
	} `json:"session"`
}

func (fixture apiFixture) register(t *testing.T, invite, nickname string) sessionResponse {
	t.Helper()
	fixture.addInvite(t, invite)
	response := fixture.request(t, http.MethodPost, "/v1/auth/register", `{"inviteCode":`+quote(invite)+`,"nickname":`+quote(nickname)+`}`, "")
	if response.Code != http.StatusCreated {
		t.Fatalf("register %q status=%d body=%s", nickname, response.Code, response.Body.String())
	}
	var result sessionResponse
	decodeResponse(t, response, &result)
	if _, err := uuid.Parse(result.Session.User.ID); err != nil || result.Session.User.Nickname != nickname || result.Session.AccessToken == "" || result.Session.RefreshToken == "" {
		t.Fatalf("register response=%+v parseErr=%v", result, err)
	}
	return result
}

func quote(value string) string {
	encoded, _ := json.Marshal(value)
	return string(encoded)
}

func (fixture apiFixture) request(t *testing.T, method, path, body, accessToken string) *httptest.ResponseRecorder {
	t.Helper()
	request := httptest.NewRequest(method, path, strings.NewReader(body))
	if body != "" {
		request.Header.Set("Content-Type", "application/json")
	}
	if accessToken != "" {
		request.Header.Set("Authorization", "Bearer "+accessToken)
	}
	response := httptest.NewRecorder()
	fixture.handler.ServeHTTP(response, request)
	return response
}

func decodeResponse(t *testing.T, response *httptest.ResponseRecorder, destination any) {
	t.Helper()
	if response.Header().Get("Content-Type") != "application/json; charset=utf-8" {
		t.Fatalf("Content-Type=%q", response.Header().Get("Content-Type"))
	}
	if err := json.Unmarshal(response.Body.Bytes(), destination); err != nil {
		t.Fatalf("decode response %q: %v", response.Body.String(), err)
	}
}

func responseErrorCode(t *testing.T, response *httptest.ResponseRecorder) string {
	t.Helper()
	var result struct {
		Error struct {
			Code    string         `json:"code"`
			Message string         `json:"message"`
			Details map[string]any `json:"details"`
		} `json:"error"`
	}
	decodeResponse(t, response, &result)
	if result.Error.Code == "" || result.Error.Message == "" || result.Error.Details == nil {
		t.Fatalf("malformed error response: %+v", result)
	}
	return result.Error.Code
}

func TestRouterHappyPathAuthLobbyMatchTicketAndCancel(t *testing.T) {
	fixture := newAPIFixture(t)

	health := fixture.request(t, http.MethodGet, "/healthz", "", "")
	if health.Code != http.StatusOK || health.Body.String() != "{\"status\":\"ok\"}\n" {
		t.Fatalf("health=(%d,%q)", health.Code, health.Body.String())
	}
	if health.Header().Get("X-Request-ID") != "00000000-0000-4000-8000-000000000001" {
		t.Fatalf("request id=%q", health.Header().Get("X-Request-ID"))
	}

	alice := fixture.register(t, "invite-alice-secret", "Alice")
	bob := fixture.register(t, "invite-bob-secret", "Bob")
	issuedAt := fixture.now.UTC().Truncate(time.Second)
	if alice.Session.AccessExpiresAt != issuedAt.Add(15*time.Minute).UnixMilli() ||
		alice.Session.RefreshExpiresAt != issuedAt.Add(30*24*time.Hour).UnixMilli() {
		t.Fatalf("session expiry=(%d,%d)", alice.Session.AccessExpiresAt, alice.Session.RefreshExpiresAt)
	}

	me := fixture.request(t, http.MethodGet, "/v1/me", "", alice.Session.AccessToken)
	if me.Code != http.StatusOK {
		t.Fatalf("me status=%d body=%s", me.Code, me.Body.String())
	}
	var meBody map[string]any
	decodeResponse(t, me, &meBody)
	if fmt.Sprint(meBody["user"].(map[string]any)["id"]) != alice.Session.User.ID {
		t.Fatalf("me=%v", meBody)
	}
	var aliceLastSeen int64
	if err := fixture.db.QueryRow(`SELECT last_seen_at FROM users WHERE id=?`, alice.Session.User.ID).Scan(&aliceLastSeen); err != nil || aliceLastSeen != fixture.now.UTC().UnixMilli() {
		t.Fatalf("last_seen_at=(%d,%v)", aliceLastSeen, err)
	}

	gamesResponse := fixture.request(t, http.MethodGet, "/v1/games", "", alice.Session.AccessToken)
	if gamesResponse.Code != http.StatusOK || gamesResponse.Body.String() != "{\"games\":[{\"id\":\"gomoku\",\"title\":\"五子棋\",\"playerCount\":2}]}\n" {
		t.Fatalf("games=(%d,%q)", gamesResponse.Code, gamesResponse.Body.String())
	}

	opponents := fixture.request(t, http.MethodGet, "/v1/games/gomoku/opponents", "", alice.Session.AccessToken)
	if opponents.Code != http.StatusOK {
		t.Fatalf("opponents status=%d body=%s", opponents.Code, opponents.Body.String())
	}
	var opponentsBody struct {
		Opponents []struct {
			ID           string `json:"id"`
			Nickname     string `json:"nickname"`
			Availability string `json:"availability"`
			Presence     string `json:"presence"`
		} `json:"opponents"`
	}
	decodeResponse(t, opponents, &opponentsBody)
	if len(opponentsBody.Opponents) != 1 || opponentsBody.Opponents[0].ID != bob.Session.User.ID || opponentsBody.Opponents[0].Availability != "idle" || opponentsBody.Opponents[0].Presence != "offline" {
		t.Fatalf("opponents=%+v", opponentsBody.Opponents)
	}
	if response := fixture.request(t, http.MethodGet, "/v1/me", "", bob.Session.AccessToken); response.Code != http.StatusOK {
		t.Fatalf("bob me status=%d", response.Code)
	}
	opponents = fixture.request(t, http.MethodGet, "/v1/games/gomoku/opponents", "", alice.Session.AccessToken)
	decodeResponse(t, opponents, &opponentsBody)
	if opponentsBody.Opponents[0].Presence != "online" {
		t.Fatalf("presence=%q", opponentsBody.Opponents[0].Presence)
	}

	idle := fixture.request(t, http.MethodGet, "/v1/games/gomoku/status", "", alice.Session.AccessToken)
	if idle.Code != http.StatusOK || idle.Body.String() != "{\"state\":\"idle\"}\n" {
		t.Fatalf("idle=(%d,%q)", idle.Code, idle.Body.String())
	}

	created := fixture.request(t, http.MethodPost, "/v1/games/gomoku/matches", `{"opponentId":`+quote(bob.Session.User.ID)+`}`, alice.Session.AccessToken)
	if created.Code != http.StatusCreated {
		t.Fatalf("create status=%d body=%s", created.Code, created.Body.String())
	}
	var createdBody struct {
		Match struct {
			ID     string `json:"id"`
			GameID string `json:"gameId"`
			State  string `json:"state"`
		} `json:"match"`
	}
	decodeResponse(t, created, &createdBody)
	if _, err := uuid.Parse(createdBody.Match.ID); err != nil || createdBody.Match.GameID != gomoku.GameID || createdBody.Match.State != "active" {
		t.Fatalf("create=%+v err=%v", createdBody, err)
	}

	active := fixture.request(t, http.MethodGet, "/v1/games/gomoku/status", "", alice.Session.AccessToken)
	if active.Code != http.StatusOK {
		t.Fatalf("active status=%d body=%s", active.Code, active.Body.String())
	}
	var activeBody struct {
		State string `json:"state"`
		Match struct {
			ID       string `json:"id"`
			Color    string `json:"color"`
			Revision int64  `json:"revision"`
			Opponent struct {
				ID       string `json:"id"`
				Nickname string `json:"nickname"`
			} `json:"opponent"`
		} `json:"match"`
	}
	decodeResponse(t, active, &activeBody)
	if activeBody.State != "active" || activeBody.Match.ID != createdBody.Match.ID || activeBody.Match.Opponent.ID != bob.Session.User.ID || activeBody.Match.Opponent.Nickname != "Bob" || activeBody.Match.Color != "black" || activeBody.Match.Revision != 0 {
		t.Fatalf("active=%+v", activeBody)
	}

	ticketResponse := fixture.request(t, http.MethodPost, "/v1/matches/"+createdBody.Match.ID+"/launch-ticket", `{}`, alice.Session.AccessToken)
	if ticketResponse.Code != http.StatusCreated || ticketResponse.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("ticket status=%d headers=%v body=%s", ticketResponse.Code, ticketResponse.Header(), ticketResponse.Body.String())
	}
	var ticketBody struct {
		MatchID      string `json:"matchId"`
		GameID       string `json:"gameId"`
		LaunchTicket string `json:"launchTicket"`
		ExpiresAt    int64  `json:"expiresAt"`
	}
	decodeResponse(t, ticketResponse, &ticketBody)
	decodedTicket, err := authTokenBytes(ticketBody.LaunchTicket)
	if err != nil || len(decodedTicket) != 32 || ticketBody.MatchID != createdBody.Match.ID || ticketBody.GameID != gomoku.GameID || ticketBody.ExpiresAt != fixture.now.UTC().Add(60*time.Second).UnixMilli() {
		t.Fatalf("ticket=%+v bytes=%d err=%v", ticketBody, len(decodedTicket), err)
	}
	var storedHash, storedMatchID, storedUserID, storedGameID string
	var expiresAt, createdAt int64
	if err := fixture.db.QueryRow(`SELECT token_hash,match_id,user_id,game_id,expires_at,created_at FROM launch_tickets`).Scan(&storedHash, &storedMatchID, &storedUserID, &storedGameID, &expiresAt, &createdAt); err != nil {
		t.Fatalf("read launch ticket: %v", err)
	}
	inviteDomainHash, _ := auth.HashToken(testTokenPepper, ticketBody.LaunchTicket)
	if storedHash == ticketBody.LaunchTicket || storedHash == inviteDomainHash || storedMatchID != createdBody.Match.ID || storedUserID != alice.Session.User.ID || storedGameID != gomoku.GameID || expiresAt != ticketBody.ExpiresAt || createdAt != fixture.now.UTC().UnixMilli() {
		t.Fatalf("stored ticket=(%q,%q,%q,%q,%d,%d)", storedHash, storedMatchID, storedUserID, storedGameID, expiresAt, createdAt)
	}

	cancelled := fixture.request(t, http.MethodDelete, "/v1/matches/"+createdBody.Match.ID, "", alice.Session.AccessToken)
	if cancelled.Code != http.StatusNoContent || cancelled.Body.Len() != 0 || cancelled.Header().Get("Content-Type") != "" {
		t.Fatalf("cancel=(%d,%q,%v)", cancelled.Code, cancelled.Body.String(), cancelled.Header())
	}
	publications := fixture.publisher.snapshot()
	if len(publications) != 1 || publications[0].matchID != createdBody.Match.ID || publications[0].event.MatchID != createdBody.Match.ID || publications[0].event.Revision != 1 {
		t.Fatalf("publications=%+v", publications)
	}
	if after := fixture.request(t, http.MethodGet, "/v1/games/gomoku/status", "", alice.Session.AccessToken); after.Code != http.StatusOK || after.Body.String() != "{\"state\":\"idle\"}\n" {
		t.Fatalf("status after cancel=(%d,%q)", after.Code, after.Body.String())
	}

	refreshed := fixture.request(t, http.MethodPost, "/v1/auth/refresh", `{"refreshToken":`+quote(alice.Session.RefreshToken)+`}`, "")
	if refreshed.Code != http.StatusOK || refreshed.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("refresh=(%d,%v,%s)", refreshed.Code, refreshed.Header(), refreshed.Body.String())
	}
	var refreshedBody sessionResponse
	decodeResponse(t, refreshed, &refreshedBody)
	if refreshedBody.Session.User.ID != alice.Session.User.ID || refreshedBody.Session.RefreshToken == alice.Session.RefreshToken {
		t.Fatalf("refreshed=%+v", refreshedBody)
	}

	logged := fixture.logs.String()
	for _, secret := range []string{"invite-alice-secret", "invite-bob-secret", alice.Session.AccessToken, alice.Session.RefreshToken, ticketBody.LaunchTicket, refreshedBody.Session.RefreshToken} {
		if strings.Contains(logged, secret) {
			t.Fatalf("request log leaked secret %q: %s", secret, logged)
		}
	}
	if !strings.Contains(logged, "request_id=00000000-0000-4000-8000-000000000001 method=GET path=/healthz status=200") {
		t.Fatalf("missing safe request log: %s", logged)
	}
}

func authTokenBytes(token string) ([]byte, error) {
	return base64.RawURLEncoding.DecodeString(token)
}

func TestRouterStrictJSONAuthenticationAndRoutingErrors(t *testing.T) {
	fixture := newAPIFixture(t)
	fixture.addInvite(t, "valid-invite-secret")

	tests := []struct {
		name        string
		method      string
		path        string
		body        string
		contentType *string
		authority   string
		wantStatus  int
		wantCode    string
	}{
		{name: "missing media type", method: http.MethodPost, path: "/v1/auth/register", body: `{"inviteCode":"valid-invite-secret","nickname":"Alice"}`, contentType: stringPointer(""), wantStatus: http.StatusUnsupportedMediaType, wantCode: "invalid_request"},
		{name: "wrong media type", method: http.MethodPost, path: "/v1/auth/register", body: `{}`, contentType: stringPointer("text/plain"), wantStatus: http.StatusUnsupportedMediaType, wantCode: "invalid_request"},
		{name: "unknown media parameter", method: http.MethodPost, path: "/v1/auth/register", body: `{}`, contentType: stringPointer("application/json; profile=test"), wantStatus: http.StatusUnsupportedMediaType, wantCode: "invalid_request"},
		{name: "empty body", method: http.MethodPost, path: "/v1/auth/register", body: "", contentType: stringPointer("application/json"), wantStatus: http.StatusBadRequest, wantCode: "invalid_request"},
		{name: "null body", method: http.MethodPost, path: "/v1/auth/register", body: `null`, wantStatus: http.StatusBadRequest, wantCode: "invalid_request"},
		{name: "bad json", method: http.MethodPost, path: "/v1/auth/register", body: `{"inviteCode":`, wantStatus: http.StatusBadRequest, wantCode: "invalid_request"},
		{name: "trailing json", method: http.MethodPost, path: "/v1/auth/register", body: `{"inviteCode":"x","nickname":"Alice"}{}`, wantStatus: http.StatusBadRequest, wantCode: "invalid_request"},
		{name: "unknown field", method: http.MethodPost, path: "/v1/auth/register", body: `{"inviteCode":"x","nickname":"Alice","secretMarker":"do-not-log"}`, wantStatus: http.StatusBadRequest, wantCode: "invalid_request"},
		{name: "duplicate field", method: http.MethodPost, path: "/v1/auth/register", body: `{"inviteCode":"x","inviteCode":"valid-invite-secret","nickname":"Alice"}`, wantStatus: http.StatusBadRequest, wantCode: "invalid_request"},
		{name: "excessive json depth", method: http.MethodPost, path: "/v1/auth/register", body: `{"inviteCode":"x","nickname":"Alice","nested":` + strings.Repeat("[", 33) + `0` + strings.Repeat("]", 33) + `}`, wantStatus: http.StatusBadRequest, wantCode: "invalid_request"},
		{name: "unauthenticated", method: http.MethodGet, path: "/v1/me", wantStatus: http.StatusUnauthorized, wantCode: "unauthorized"},
		{name: "malformed bearer", method: http.MethodGet, path: "/v1/me", authority: "Basic secret-marker", wantStatus: http.StatusUnauthorized, wantCode: "unauthorized"},
		{name: "unknown path", method: http.MethodGet, path: "/v1/missing", wantStatus: http.StatusNotFound, wantCode: "invalid_request"},
		{name: "method mismatch", method: http.MethodPost, path: "/healthz", body: `{}`, wantStatus: http.StatusMethodNotAllowed, wantCode: "invalid_request"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			request := httptest.NewRequest(test.method, test.path, strings.NewReader(test.body))
			if test.contentType == nil && test.body != "" {
				request.Header.Set("Content-Type", "application/json")
			} else if test.contentType != nil && *test.contentType != "" {
				request.Header.Set("Content-Type", *test.contentType)
			}
			if test.authority != "" {
				request.Header.Set("Authorization", test.authority)
			}
			response := httptest.NewRecorder()
			fixture.handler.ServeHTTP(response, request)
			if response.Code != test.wantStatus || responseErrorCode(t, response) != test.wantCode {
				t.Fatalf("response=(%d,%s), want %d/%s", response.Code, response.Body.String(), test.wantStatus, test.wantCode)
			}
			if _, err := uuid.Parse(response.Header().Get("X-Request-ID")); err != nil {
				t.Fatalf("request id=%q err=%v", response.Header().Get("X-Request-ID"), err)
			}
		})
	}

	large := `{"inviteCode":"valid-invite-secret","nickname":"` + strings.Repeat("x", 65*1024) + `"}`
	response := fixture.request(t, http.MethodPost, "/v1/auth/register", large, "")
	if response.Code != http.StatusRequestEntityTooLarge || responseErrorCode(t, response) != "invalid_request" {
		t.Fatalf("large response=(%d,%s)", response.Code, response.Body.String())
	}
	for _, marker := range []string{"valid-invite-secret", "do-not-log", "secret-marker", strings.Repeat("x", 128)} {
		if strings.Contains(fixture.logs.String(), marker) {
			t.Fatalf("logs leaked request value %q: %s", marker, fixture.logs.String())
		}
	}
	invalidUTF8 := httptest.NewRequest(http.MethodPost, "/v1/auth/register", bytes.NewReader(append([]byte(`{"inviteCode":"x","nickname":"`), append([]byte{0xff}, []byte(`"}`)...)...)))
	invalidUTF8.Header.Set("Content-Type", "application/json")
	invalidUTF8Response := httptest.NewRecorder()
	fixture.handler.ServeHTTP(invalidUTF8Response, invalidUTF8)
	if invalidUTF8Response.Code != http.StatusBadRequest || responseErrorCode(t, invalidUTF8Response) != "invalid_request" {
		t.Fatalf("invalid utf8=(%d,%s)", invalidUTF8Response.Code, invalidUTF8Response.Body.String())
	}
}

func TestRequestDTOKeysRequireExactCanonicalDecodedSpelling(t *testing.T) {
	registerCases := []struct {
		name string
		body string
	}{
		{name: "invite case fold", body: `{"InviteCode":"key-invite","nickname":"Alice"}`},
		{name: "invite escaped case fold", body: `{"\u0049nviteCode":"key-invite","nickname":"Alice"}`},
		{name: "nickname case fold", body: `{"inviteCode":"key-invite","Nickname":"Alice"}`},
		{name: "nickname escaped case fold", body: `{"inviteCode":"key-invite","\u004eickname":"Alice"}`},
		{name: "nickname unicode fold", body: `{"inviteCode":"key-invite","nic\u212Aname":"Alice"}`},
		{name: "invite canonical then variant", body: `{"inviteCode":"invalid","InviteCode":"key-invite","nickname":"Alice"}`},
		{name: "invite variant then canonical", body: `{"InviteCode":"invalid","inviteCode":"key-invite","nickname":"Alice"}`},
		{name: "nickname canonical then variant", body: `{"inviteCode":"key-invite","nickname":"Alice","Nickname":"Bob"}`},
		{name: "nickname variant then canonical", body: `{"inviteCode":"key-invite","Nickname":"Bob","nickname":"Alice"}`},
	}
	for _, test := range registerCases {
		t.Run("register "+test.name, func(t *testing.T) {
			fixture := newAPIFixture(t)
			fixture.addInvite(t, "key-invite")
			response := fixture.request(t, http.MethodPost, "/v1/auth/register", test.body, "")
			assertInvalidRequest(t, response)
			if count := countRows(t, fixture.db, "users"); count != 0 {
				t.Fatalf("noncanonical register wrote %d users", count)
			}
		})
	}

	refreshCases := []struct {
		name string
		body func(valid string) string
	}{
		{name: "case fold", body: func(valid string) string { return `{"RefreshToken":` + quote(valid) + `}` }},
		{name: "escaped case fold", body: func(valid string) string { return `{"\u0052efreshToken":` + quote(valid) + `}` }},
		{name: "unicode fold", body: func(valid string) string { return `{"refre\u017FhToken":` + quote(valid) + `}` }},
		{name: "exact unknown field", body: func(valid string) string { return `{"refreshToken":` + quote(valid) + `,"unknown":true}` }},
		{name: "canonical then variant", body: func(valid string) string { return `{"refreshToken":"invalid","RefreshToken":` + quote(valid) + `}` }},
		{name: "variant then canonical", body: func(valid string) string { return `{"RefreshToken":"invalid","refreshToken":` + quote(valid) + `}` }},
	}
	for _, test := range refreshCases {
		t.Run("refresh "+test.name, func(t *testing.T) {
			fixture := newAPIFixture(t)
			alice := fixture.register(t, "refresh-key-invite", "Alice")
			response := fixture.request(t, http.MethodPost, "/v1/auth/refresh", test.body(alice.Session.RefreshToken), "")
			assertInvalidRequest(t, response)
			var revoked sql.NullInt64
			if err := fixture.db.QueryRow(`SELECT revoked_at FROM refresh_tokens`).Scan(&revoked); err != nil || revoked.Valid {
				t.Fatalf("noncanonical refresh consumed token: revoked=%v err=%v", revoked, err)
			}
		})
	}

	opponentCases := []struct {
		name string
		body func(valid, other string) string
	}{
		{name: "case fold", body: func(valid, _ string) string { return `{"OpponentId":` + quote(valid) + `}` }},
		{name: "escaped case fold", body: func(valid, _ string) string { return `{"\u004fpponentId":` + quote(valid) + `}` }},
		{name: "exact unknown field", body: func(valid, _ string) string { return `{"opponentId":` + quote(valid) + `,"unknown":true}` }},
		{name: "canonical then variant", body: func(valid, other string) string {
			return `{"opponentId":` + quote(other) + `,"OpponentId":` + quote(valid) + `}`
		}},
		{name: "variant then canonical", body: func(valid, other string) string {
			return `{"OpponentId":` + quote(other) + `,"opponentId":` + quote(valid) + `}`
		}},
	}
	for _, test := range opponentCases {
		t.Run("opponent "+test.name, func(t *testing.T) {
			fixture := newAPIFixture(t)
			alice := fixture.register(t, "opponent-key-a", "Alice")
			bob := fixture.register(t, "opponent-key-b", "Bob")
			carol := fixture.register(t, "opponent-key-c", "Carol")
			response := fixture.request(t, http.MethodPost, "/v1/games/gomoku/matches", test.body(bob.Session.User.ID, carol.Session.User.ID), alice.Session.AccessToken)
			assertInvalidRequest(t, response)
			if count := countRows(t, fixture.db, "matches"); count != 0 {
				t.Fatalf("noncanonical opponent key wrote %d matches", count)
			}
		})
	}

	t.Run("launch ticket exact unknown field", func(t *testing.T) {
		fixture := newAPIFixture(t)
		alice := fixture.register(t, "launch-key-a", "Alice")
		bob := fixture.register(t, "launch-key-b", "Bob")
		created := fixture.request(t, http.MethodPost, "/v1/games/gomoku/matches", `{"opponentId":`+quote(bob.Session.User.ID)+`}`, alice.Session.AccessToken)
		var matchBody struct {
			Match struct {
				ID string `json:"id"`
			} `json:"match"`
		}
		decodeResponse(t, created, &matchBody)
		response := fixture.request(t, http.MethodPost, "/v1/matches/"+matchBody.Match.ID+"/launch-ticket", `{"unknown":true}`, alice.Session.AccessToken)
		assertInvalidRequest(t, response)
		if count := tableCount(t, fixture.db, "launch_tickets"); count != 0 {
			t.Fatalf("unknown launch-ticket field wrote %d tickets", count)
		}
	})
}

func assertInvalidRequest(t *testing.T, response *httptest.ResponseRecorder) {
	t.Helper()
	if response.Code != http.StatusBadRequest || responseErrorCode(t, response) != "invalid_request" {
		t.Fatalf("response=(%d,%s), want 400/invalid_request", response.Code, response.Body.String())
	}
}

func countRows(t *testing.T, db *sql.DB, table string) int {
	t.Helper()
	allowed := map[string]bool{"users": true, "matches": true}
	if !allowed[table] {
		t.Fatalf("unsafe table %q", table)
	}
	var count int
	if err := db.QueryRow(`SELECT COUNT(*) FROM ` + table).Scan(&count); err != nil {
		t.Fatal(err)
	}
	return count
}

func TestAuthenticationRejectsDisabledUserAndMultipleCredentials(t *testing.T) {
	fixture := newAPIFixture(t)
	alice := fixture.register(t, "disabled-a", "Alice")
	if _, err := fixture.db.Exec(`UPDATE users SET enabled=0,last_seen_at=NULL WHERE id=?`, alice.Session.User.ID); err != nil {
		t.Fatal(err)
	}
	disabled := fixture.request(t, http.MethodGet, "/v1/me", "", alice.Session.AccessToken)
	if disabled.Code != http.StatusUnauthorized || responseErrorCode(t, disabled) != "unauthorized" {
		t.Fatalf("disabled=(%d,%s)", disabled.Code, disabled.Body.String())
	}
	var lastSeen sql.NullInt64
	if err := fixture.db.QueryRow(`SELECT last_seen_at FROM users WHERE id=?`, alice.Session.User.ID).Scan(&lastSeen); err != nil || lastSeen.Valid {
		t.Fatalf("disabled user last seen=%v err=%v", lastSeen, err)
	}

	request := httptest.NewRequest(http.MethodGet, "/v1/me", nil)
	request.Header.Add("Authorization", "Bearer "+alice.Session.AccessToken)
	request.Header.Add("Authorization", "Bearer another-secret-credential")
	response := httptest.NewRecorder()
	fixture.handler.ServeHTTP(response, request)
	if response.Code != http.StatusUnauthorized || responseErrorCode(t, response) != "unauthorized" || strings.Contains(fixture.logs.String(), "another-secret-credential") {
		t.Fatalf("multiple credentials=(%d,%s) logs=%s", response.Code, response.Body.String(), fixture.logs.String())
	}

	secretPath := "/v1/missing/path-secret-marker?launchTicket=query-secret-marker"
	unknown := fixture.request(t, http.MethodGet, secretPath, "", "")
	if unknown.Code != http.StatusNotFound || strings.Contains(fixture.logs.String(), "path-secret-marker") || strings.Contains(fixture.logs.String(), "query-secret-marker") {
		t.Fatalf("unknown path logging=(%d,%s) logs=%s", unknown.Code, unknown.Body.String(), fixture.logs.String())
	}
}

func TestRouterMapsRegistrationAndBusyConflicts(t *testing.T) {
	fixture := newAPIFixture(t)
	alice := fixture.register(t, "invite-a", "Alice")
	bob := fixture.register(t, "invite-b", "Bob")
	carol := fixture.register(t, "invite-c", "Carol")

	fixture.addInvite(t, "invite-conflict")
	nicknameConflict := fixture.request(t, http.MethodPost, "/v1/auth/register", `{"inviteCode":"invite-conflict","nickname":" alice "}`, "")
	if nicknameConflict.Code != http.StatusConflict || responseErrorCode(t, nicknameConflict) != "nickname_taken" {
		t.Fatalf("nickname conflict=(%d,%s)", nicknameConflict.Code, nicknameConflict.Body.String())
	}
	hash, _ := auth.HashToken(testTokenPepper, "invite-conflict")
	var consumedAt sql.NullInt64
	if err := fixture.db.QueryRow(`SELECT consumed_at FROM invite_codes WHERE code_hash=?`, hash).Scan(&consumedAt); err != nil || consumedAt.Valid {
		t.Fatalf("nickname conflict consumed invite: %v err=%v", consumedAt, err)
	}

	invalidInvite := fixture.request(t, http.MethodPost, "/v1/auth/register", `{"inviteCode":"invalid-invite-marker","nickname":"Delta"}`, "")
	if invalidInvite.Code != http.StatusUnprocessableEntity || responseErrorCode(t, invalidInvite) != "invite_invalid" {
		t.Fatalf("invalid invite=(%d,%s)", invalidInvite.Code, invalidInvite.Body.String())
	}

	first := fixture.request(t, http.MethodPost, "/v1/games/gomoku/matches", `{"opponentId":`+quote(bob.Session.User.ID)+`}`, alice.Session.AccessToken)
	if first.Code != http.StatusCreated {
		t.Fatalf("first create=(%d,%s)", first.Code, first.Body.String())
	}
	busyOpponent := fixture.request(t, http.MethodPost, "/v1/games/gomoku/matches", `{"opponentId":`+quote(bob.Session.User.ID)+`}`, carol.Session.AccessToken)
	if busyOpponent.Code != http.StatusConflict || responseErrorCode(t, busyOpponent) != "opponent_busy" {
		t.Fatalf("busy opponent=(%d,%s)", busyOpponent.Code, busyOpponent.Body.String())
	}
	activeCaller := fixture.request(t, http.MethodPost, "/v1/games/gomoku/matches", `{"opponentId":`+quote(carol.Session.User.ID)+`}`, alice.Session.AccessToken)
	if activeCaller.Code != http.StatusConflict || responseErrorCode(t, activeCaller) != "active_match_exists" {
		t.Fatalf("active caller=(%d,%s)", activeCaller.Code, activeCaller.Body.String())
	}

	opponents := fixture.request(t, http.MethodGet, "/v1/games/gomoku/opponents", "", carol.Session.AccessToken)
	var body struct {
		Opponents []struct {
			ID           string `json:"id"`
			Availability string `json:"availability"`
		} `json:"opponents"`
	}
	decodeResponse(t, opponents, &body)
	if len(body.Opponents) != 2 || body.Opponents[0].ID != alice.Session.User.ID || body.Opponents[1].ID != bob.Session.User.ID || body.Opponents[0].Availability != "busy" || body.Opponents[1].Availability != "busy" {
		t.Fatalf("ordered opponents=%+v", body.Opponents)
	}
	if strings.Contains(fixture.logs.String(), "invalid-invite-marker") {
		t.Fatal("request log leaked invalid invite")
	}
}

func TestLaunchTicketRequiresActiveParticipantAndRetriesHashCollision(t *testing.T) {
	fixture := newAPIFixture(t)
	alice := fixture.register(t, "ticket-a", "Alice")
	bob := fixture.register(t, "ticket-b", "Bob")
	carol := fixture.register(t, "ticket-c", "Carol")
	created := fixture.request(t, http.MethodPost, "/v1/games/gomoku/matches", `{"opponentId":`+quote(bob.Session.User.ID)+`}`, alice.Session.AccessToken)
	var matchBody struct {
		Match struct {
			ID string `json:"id"`
		} `json:"match"`
	}
	decodeResponse(t, created, &matchBody)

	nonParticipant := fixture.request(t, http.MethodPost, "/v1/matches/"+matchBody.Match.ID+"/launch-ticket", `{}`, carol.Session.AccessToken)
	if nonParticipant.Code != http.StatusNotFound || responseErrorCode(t, nonParticipant) != "match_not_found" {
		t.Fatalf("non-participant=(%d,%s)", nonParticipant.Code, nonParticipant.Body.String())
	}

	first := fixture.request(t, http.MethodPost, "/v1/matches/"+matchBody.Match.ID+"/launch-ticket", `{}`, alice.Session.AccessToken)
	var firstTicket struct {
		LaunchTicket string `json:"launchTicket"`
	}
	decodeResponse(t, first, &firstTicket)
	firstBytes, err := authTokenBytes(firstTicket.LaunchTicket)
	if err != nil {
		t.Fatal(err)
	}
	secondBytes := bytes.Repeat([]byte{2}, 32)
	matchService, err := matches.NewServiceWithConfig(fixture.db, games.NewRegistry(), fixture.clock, matches.ServiceConfig{
		ColorRandom:        bytes.NewReader([]byte{0}),
		LaunchTicketRandom: bytes.NewReader(append(append([]byte(nil), firstBytes...), secondBytes...)),
		TokenPepper:        testTokenPepper,
	})
	if err != nil {
		t.Fatal(err)
	}
	handler, err := NewRouter(RouterConfig{Auth: fixture.auth, Matches: matchService, Games: games.NewRegistry(), Publisher: fixture.publisher, Logger: log.New(fixture.logs, "", 0), RequestIDs: sequentialRequestIDs()})
	if err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodPost, "/v1/matches/"+matchBody.Match.ID+"/launch-ticket", strings.NewReader(`{}`))
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Authorization", "Bearer "+alice.Session.AccessToken)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusCreated {
		t.Fatalf("collision retry=(%d,%s)", response.Code, response.Body.String())
	}
	var secondTicket struct {
		LaunchTicket string `json:"launchTicket"`
	}
	decodeResponse(t, response, &secondTicket)
	if secondTicket.LaunchTicket == firstTicket.LaunchTicket {
		t.Fatal("launch ticket collision was returned instead of retried")
	}
	if count := tableCount(t, fixture.db, "launch_tickets"); count != 2 {
		t.Fatalf("launch ticket rows=%d", count)
	}

	cancel := fixture.request(t, http.MethodDelete, "/v1/matches/"+matchBody.Match.ID, "", bob.Session.AccessToken)
	if cancel.Code != http.StatusNoContent {
		t.Fatalf("cancel=(%d,%s)", cancel.Code, cancel.Body.String())
	}
	inactive := fixture.request(t, http.MethodPost, "/v1/matches/"+matchBody.Match.ID+"/launch-ticket", `{}`, alice.Session.AccessToken)
	if inactive.Code != http.StatusNotFound || responseErrorCode(t, inactive) != "match_not_found" {
		t.Fatalf("inactive=(%d,%s)", inactive.Code, inactive.Body.String())
	}
}

func TestLaunchTicketCommitFailureBusyAndCancellationNeverReturnCredential(t *testing.T) {
	t.Run("deferred commit failure", func(t *testing.T) {
		fixture := newAPIFixture(t)
		alice := fixture.register(t, "commit-a", "Alice")
		bob := fixture.register(t, "commit-b", "Bob")
		created := fixture.request(t, http.MethodPost, "/v1/games/gomoku/matches", `{"opponentId":`+quote(bob.Session.User.ID)+`}`, alice.Session.AccessToken)
		var matchBody struct {
			Match struct {
				ID string `json:"id"`
			} `json:"match"`
		}
		decodeResponse(t, created, &matchBody)
		if _, err := fixture.db.Exec(`
CREATE TABLE launch_ticket_commit_guard (
  marker TEXT PRIMARY KEY,
  missing_user_id TEXT NOT NULL REFERENCES users(id) DEFERRABLE INITIALLY DEFERRED
);
CREATE TRIGGER fail_launch_ticket_at_commit AFTER INSERT ON launch_tickets
BEGIN
  INSERT INTO launch_ticket_commit_guard(marker,missing_user_id)
  VALUES (NEW.token_hash,'ffffffff-ffff-4fff-8fff-ffffffffffff');
END;`); err != nil {
			t.Fatalf("install deferred failure: %v", err)
		}
		response := fixture.request(t, http.MethodPost, "/v1/matches/"+matchBody.Match.ID+"/launch-ticket", `{}`, alice.Session.AccessToken)
		if response.Code != http.StatusInternalServerError || responseErrorCode(t, response) != "internal_error" || strings.Contains(response.Body.String(), "AQEBAQ") {
			t.Fatalf("commit failure=(%d,%s)", response.Code, response.Body.String())
		}
		if count := tableCount(t, fixture.db, "launch_tickets"); count != 0 {
			t.Fatalf("ticket rows after failed commit=%d", count)
		}
	})

	t.Run("busy context deadline rolls back", func(t *testing.T) {
		fixture := newAPIFixture(t)
		alice := fixture.register(t, "busy-a", "Alice")
		bob := fixture.register(t, "busy-b", "Bob")
		created := fixture.request(t, http.MethodPost, "/v1/games/gomoku/matches", `{"opponentId":`+quote(bob.Session.User.ID)+`}`, alice.Session.AccessToken)
		var matchBody struct {
			Match struct {
				ID string `json:"id"`
			} `json:"match"`
		}
		decodeResponse(t, created, &matchBody)
		blocking, err := fixture.db.BeginTx(context.Background(), nil)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := blocking.Exec(`UPDATE users SET updated_at=updated_at WHERE id=?`, alice.Session.User.ID); err != nil {
			_ = blocking.Rollback()
			t.Fatal(err)
		}
		ctx, cancel := context.WithTimeout(context.Background(), 40*time.Millisecond)
		defer cancel()
		ticket, issueErr := fixture.matches.CreateLaunchTicket(ctx, matchBody.Match.ID, alice.Session.User.ID)
		if rollbackErr := blocking.Rollback(); rollbackErr != nil {
			t.Fatal(rollbackErr)
		}
		if !errors.Is(issueErr, context.DeadlineExceeded) || ticket.Token != "" {
			t.Fatalf("busy issue=(%+v,%v)", ticket, issueErr)
		}
		if count := tableCount(t, fixture.db, "launch_tickets"); count != 0 {
			t.Fatalf("ticket rows after busy deadline=%d", count)
		}

		cancelled, cancelNow := context.WithCancel(context.Background())
		cancelNow()
		ticket, issueErr = fixture.matches.CreateLaunchTicket(cancelled, matchBody.Match.ID, alice.Session.User.ID)
		if !errors.Is(issueErr, context.Canceled) || ticket.Token != "" || tableCount(t, fixture.db, "launch_tickets") != 0 {
			t.Fatalf("cancelled issue=(%+v,%v)", ticket, issueErr)
		}
	})
}

func TestOpponentPresenceBoundaryAndOfflineIdleSelection(t *testing.T) {
	fixture := newAPIFixture(t)
	alice := fixture.register(t, "presence-a", "Alice")
	bob := fixture.register(t, "presence-b", "Bob")
	carol := fixture.register(t, "presence-c", "Carol")
	cutoff := fixture.now.UTC().Add(-90 * time.Second).UnixMilli()
	if _, err := fixture.db.Exec(`UPDATE users SET last_seen_at=? WHERE id=?`, cutoff, bob.Session.User.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := fixture.db.Exec(`UPDATE users SET last_seen_at=? WHERE id=?`, cutoff-1, carol.Session.User.ID); err != nil {
		t.Fatal(err)
	}
	response := fixture.request(t, http.MethodGet, "/v1/games/gomoku/opponents", "", alice.Session.AccessToken)
	var body struct {
		Opponents []struct {
			ID           string `json:"id"`
			Availability string `json:"availability"`
			Presence     string `json:"presence"`
		} `json:"opponents"`
	}
	decodeResponse(t, response, &body)
	if len(body.Opponents) != 2 || body.Opponents[0].ID != bob.Session.User.ID || body.Opponents[0].Availability != "idle" || body.Opponents[0].Presence != "online" || body.Opponents[1].ID != carol.Session.User.ID || body.Opponents[1].Availability != "idle" || body.Opponents[1].Presence != "offline" {
		t.Fatalf("presence boundary=%+v", body.Opponents)
	}
	created := fixture.request(t, http.MethodPost, "/v1/games/gomoku/matches", `{"opponentId":`+quote(carol.Session.User.ID)+`}`, alice.Session.AccessToken)
	if created.Code != http.StatusCreated {
		t.Fatalf("offline idle opponent was not selectable: (%d,%s)", created.Code, created.Body.String())
	}
}

func TestRequestMiddlewareRecoversPanicWithFixedErrorAndSafeLog(t *testing.T) {
	logs := &bytes.Buffer{}
	handler := requestMiddleware(log.New(logs, "", 0), sequentialRequestIDs())(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		panic("panic-secret-marker")
	}))
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/panic-safe-path", nil))
	if response.Code != http.StatusInternalServerError || responseErrorCode(t, response) != "internal_error" {
		t.Fatalf("panic response=(%d,%s)", response.Code, response.Body.String())
	}
	if strings.Contains(response.Body.String(), "panic-secret-marker") || strings.Contains(logs.String(), "panic-secret-marker") {
		t.Fatalf("panic leaked: response=%s logs=%s", response.Body.String(), logs.String())
	}
	if !strings.Contains(logs.String(), "panic=true") {
		t.Fatalf("panic not safely logged: %s", logs.String())
	}
}

func TestNewRouterRejectsInvalidDependenciesWithoutSecretFormatting(t *testing.T) {
	fixture := newAPIFixture(t)
	tests := []RouterConfig{
		{},
		{Matches: fixture.matches, Games: games.NewRegistry(), Publisher: fixture.publisher, Logger: log.Default(), RequestIDs: sequentialRequestIDs()},
		{Auth: fixture.auth, Games: games.NewRegistry(), Publisher: fixture.publisher, Logger: log.Default(), RequestIDs: sequentialRequestIDs()},
		{Auth: fixture.auth, Matches: fixture.matches, Publisher: fixture.publisher, Logger: log.Default(), RequestIDs: sequentialRequestIDs()},
		{Auth: fixture.auth, Matches: fixture.matches, Games: games.NewRegistry(), Logger: log.Default(), RequestIDs: sequentialRequestIDs()},
		{Auth: fixture.auth, Matches: fixture.matches, Games: games.NewRegistry(), Publisher: fixture.publisher, RequestIDs: sequentialRequestIDs()},
		{Auth: fixture.auth, Matches: fixture.matches, Games: games.NewRegistry(), Publisher: fixture.publisher, Logger: log.Default()},
	}
	for _, config := range tests {
		handler, err := NewRouter(config)
		if handler != nil || !errors.Is(err, ErrInvalidConfiguration) || err.Error() != ErrInvalidConfiguration.Error() {
			t.Fatalf("NewRouter=(%v,%v)", handler, err)
		}
	}
}

func stringPointer(value string) *string { return &value }

func tableCount(t *testing.T, db *sql.DB, table string) int {
	t.Helper()
	if table != "launch_tickets" {
		t.Fatalf("unsafe table %q", table)
	}
	var count int
	if err := db.QueryRow(`SELECT COUNT(*) FROM launch_tickets`).Scan(&count); err != nil {
		t.Fatal(err)
	}
	return count
}
