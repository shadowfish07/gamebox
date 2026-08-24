package httpapi

import (
	"bufio"
	"bytes"
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"math"
	"net"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/google/uuid"

	"me.zqydev/gamebox/server/internal/auth"
	"me.zqydev/gamebox/server/internal/clock"
	"me.zqydev/gamebox/server/internal/games"
	"me.zqydev/gamebox/server/internal/games/gomoku"
	"me.zqydev/gamebox/server/internal/matches"
	"me.zqydev/gamebox/server/internal/protocol"
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
	hub    *matches.Hub
}

type panickingPublisher struct{ marker string }

func (publisher panickingPublisher) Publish(string, matches.Event) { panic(publisher.marker) }

func (publisher *recordingPublisher) Publish(matchID string, event matches.Event) {
	if publisher.hub != nil {
		publisher.hub.Publish(matchID, event)
	}
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
	logs      *lockedBuffer
	publisher *recordingPublisher
	hub       *matches.Hub
	presence  *matches.Presence
	now       time.Time
}

type lockedBuffer struct {
	mu     sync.Mutex
	buffer bytes.Buffer
}

func (buffer *lockedBuffer) Write(data []byte) (int, error) {
	buffer.mu.Lock()
	defer buffer.mu.Unlock()
	return buffer.buffer.Write(data)
}

func (buffer *lockedBuffer) String() string {
	buffer.mu.Lock()
	defer buffer.mu.Unlock()
	return buffer.buffer.String()
}

func newAPIFixture(t *testing.T) apiFixture {
	return newAPIFixtureWithHubConfig(t, matches.HubConfig{})
}

func newAPIFixtureWithHubConfig(t *testing.T, hubConfig matches.HubConfig) apiFixture {
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
		LaunchTicketRandom: bytes.NewReader(distinctCredentialEntropy(64)),
		TokenPepper:        testTokenPepper,
	})
	if err != nil {
		t.Fatalf("new match service: %v", err)
	}
	logs := &lockedBuffer{}
	presence, err := matches.NewPresence(matchService, testClock)
	if err != nil {
		t.Fatalf("new presence: %v", err)
	}
	hub, err := matches.NewHubWithConfig(matchService, presence, testClock, hubConfig)
	if err != nil {
		t.Fatalf("new hub: %v", err)
	}
	publisher := &recordingPublisher{hub: hub}
	handler, err := NewRouter(RouterConfig{
		Auth:       authService,
		Matches:    matchService,
		Games:      games.NewRegistry(),
		Publisher:  publisher,
		Hub:        hub,
		Logger:     log.New(logs, "", 0),
		RequestIDs: sequentialRequestIDs(),
	})
	if err != nil {
		t.Fatalf("new router: %v", err)
	}
	return apiFixture{db: db, clock: testClock, auth: authService, matches: matchService, handler: handler, logs: logs, publisher: publisher, hub: hub, presence: presence, now: now}
}

func distinctCredentialEntropy(count int) []byte {
	result := make([]byte, 0, 32*count)
	for index := 0; index < count; index++ {
		result = append(result, bytes.Repeat([]byte{byte(index + 1)}, 32)...)
	}
	return result
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

func TestPatchMeUpdatesOnlyNicknameWithStrictContract(t *testing.T) {
	fixture := newAPIFixture(t)
	alice := fixture.register(t, "patch-me-alice", "Alice")
	response := fixture.request(t, http.MethodPatch, "/v1/me", `{"nickname":"新昵称"}`, alice.Session.AccessToken)
	want := `{"user":{"id":` + quote(alice.Session.User.ID) + `,"nickname":"新昵称"}` + "}\n"
	if response.Code != http.StatusOK || response.Body.String() != want {
		t.Fatalf("PATCH /v1/me = (%d,%q), want (200,%q)", response.Code, response.Body.String(), want)
	}
	var envelope map[string]any
	decodeResponse(t, response, &envelope)
	if len(envelope) != 1 {
		t.Fatalf("response keys = %v, want only user", envelope)
	}
	user, ok := envelope["user"].(map[string]any)
	if !ok || len(user) != 2 {
		t.Fatalf("user shape = %#v", envelope["user"])
	}
	if _, ok := user["id"].(string); !ok {
		t.Fatalf("user id type = %T", user["id"])
	}
	if _, ok := user["nickname"].(string); !ok {
		t.Fatalf("nickname type = %T", user["nickname"])
	}
	me := fixture.request(t, http.MethodGet, "/v1/me", "", alice.Session.AccessToken)
	if me.Code != http.StatusOK || me.Body.String() != want {
		t.Fatalf("GET /v1/me after PATCH = (%d,%q), want (200,%q)", me.Code, me.Body.String(), want)
	}
	var refreshRows int
	if err := fixture.db.QueryRow(`SELECT COUNT(*) FROM refresh_tokens WHERE user_id=?`, alice.Session.User.ID).Scan(&refreshRows); err != nil || refreshRows != 1 {
		t.Fatalf("PATCH rotated or revoked session: rows=%d err=%v", refreshRows, err)
	}
}

func TestPatchMeAuthenticationValidationConflictAndUnchangedNickname(t *testing.T) {
	fixture := newAPIFixture(t)
	alice := fixture.register(t, "patch-errors-alice", "Alice")
	fixture.register(t, "patch-errors-bob", "Bob")
	tests := []struct {
		name       string
		body       string
		token      string
		wantStatus int
		wantCode   string
	}{
		{name: "unauthenticated", body: `{"nickname":"Carol"}`, wantStatus: http.StatusUnauthorized, wantCode: "unauthorized"},
		{name: "invalid nickname", body: `{"nickname":"x"}`, token: alice.Session.AccessToken, wantStatus: http.StatusBadRequest, wantCode: "invalid_request"},
		{name: "unknown key", body: `{"nickname":"Carol","extra":true}`, token: alice.Session.AccessToken, wantStatus: http.StatusBadRequest, wantCode: "invalid_request"},
		{name: "wrong type", body: `{"nickname":7}`, token: alice.Session.AccessToken, wantStatus: http.StatusBadRequest, wantCode: "invalid_request"},
		{name: "case insensitive conflict", body: `{"nickname":" bOB "}`, token: alice.Session.AccessToken, wantStatus: http.StatusConflict, wantCode: "nickname_taken"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			response := fixture.request(t, http.MethodPatch, "/v1/me", test.body, test.token)
			if response.Code != test.wantStatus || responseErrorCode(t, response) != test.wantCode {
				t.Fatalf("response = (%d,%s)", response.Code, response.Body.String())
			}
		})
	}
	unchanged := fixture.request(t, http.MethodPatch, "/v1/me", `{"nickname":"Alice"}`, alice.Session.AccessToken)
	want := `{"user":{"id":` + quote(alice.Session.User.ID) + `,"nickname":"Alice"}` + "}\n"
	if unchanged.Code != http.StatusOK || unchanged.Body.String() != want {
		t.Fatalf("unchanged nickname = (%d,%q), want (200,%q)", unchanged.Code, unchanged.Body.String(), want)
	}
}

func TestPatchMeTransactionFailureRollsBackAndReturnsStableError(t *testing.T) {
	fixture := newAPIFixture(t)
	alice := fixture.register(t, "patch-rollback-alice", "Alice")
	if _, err := fixture.db.Exec(`CREATE TRIGGER fail_patch_nickname BEFORE UPDATE OF nickname ON users BEGIN SELECT RAISE(ABORT,'private-patch-marker'); END;`); err != nil {
		t.Fatal(err)
	}
	response := fixture.request(t, http.MethodPatch, "/v1/me", `{"nickname":"Carol"}`, alice.Session.AccessToken)
	if response.Code != http.StatusInternalServerError || responseErrorCode(t, response) != "internal_error" || strings.Contains(response.Body.String(), "private-patch-marker") {
		t.Fatalf("transaction failure = (%d,%s)", response.Code, response.Body.String())
	}
	var nickname, normalized string
	if err := fixture.db.QueryRow(`SELECT nickname,normalized_nickname FROM users WHERE id=?`, alice.Session.User.ID).Scan(&nickname, &normalized); err != nil || nickname != "Alice" || normalized != "alice" {
		t.Fatalf("rollback account = (%q,%q) err=%v", nickname, normalized, err)
	}
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

func TestWebSocketTwoClientsCommitBroadcastStaleAndResume(t *testing.T) {
	fixture := newAPIFixture(t)
	alice := fixture.register(t, "ws-a", "Alice")
	bob := fixture.register(t, "ws-b", "Bob")
	created := fixture.request(t, http.MethodPost, "/v1/games/gomoku/matches", `{"opponentId":`+quote(bob.Session.User.ID)+`}`, alice.Session.AccessToken)
	var matchBody struct {
		Match struct {
			ID string `json:"id"`
		} `json:"match"`
	}
	decodeResponse(t, created, &matchBody)
	issue := func(user sessionResponse) string {
		response := fixture.request(t, http.MethodPost, "/v1/matches/"+matchBody.Match.ID+"/launch-ticket", `{}`, user.Session.AccessToken)
		if response.Code != http.StatusCreated {
			t.Fatalf("issue ticket=(%d,%s)", response.Code, response.Body.String())
		}
		var body struct {
			LaunchTicket string `json:"launchTicket"`
		}
		decodeResponse(t, response, &body)
		return body.LaunchTicket
	}
	aliceTicket, bobTicket := issue(alice), issue(bob)
	server := httptest.NewServer(fixture.handler)
	defer server.Close()
	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/v1/ws"
	connect := func(tokenKey, token string, wantRevision int64) (*websocket.Conn, protocol.Envelope, protocol.Envelope) {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		connection, response, err := websocket.Dial(ctx, wsURL, nil)
		if err != nil {
			t.Fatalf("dial response=%v err=%v", response, err)
		}
		message := fmt.Sprintf(`{"protocolVersion":1,"type":"platform.connect","payload":{"%s":%s}}`, tokenKey, quote(token))
		if err := connection.Write(ctx, websocket.MessageText, []byte(message)); err != nil {
			t.Fatalf("write connect: %v", err)
		}
		connected := readWSEnvelope(t, connection)
		snapshot := readWSEnvelope(t, connection)
		if connected.Type != protocol.TypePlatformConnected || snapshot.Type != protocol.TypePlatformSnapshot || snapshot.Revision == nil || *snapshot.Revision != wantRevision {
			t.Fatalf("initial messages=(%+v,%+v)", connected, snapshot)
		}
		return connection, connected, snapshot
	}
	aliceWS, aliceConnected, aliceSnapshot := connect("launchTicket", aliceTicket, 0)
	defer aliceWS.CloseNow()
	bobWS, _, bobSnapshot := connect("launchTicket", bobTicket, 0)
	defer bobWS.CloseNow()
	if !bytes.Equal(aliceSnapshot.Payload, bobSnapshot.Payload) {
		t.Fatalf("initial snapshots differ: %s / %s", aliceSnapshot.Payload, bobSnapshot.Payload)
	}
	var snapshotPayload struct {
		Board       []int  `json:"board"`
		BlackUserID string `json:"blackUserId"`
		WhiteUserID string `json:"whiteUserId"`
	}
	if err := json.Unmarshal(aliceSnapshot.Payload, &snapshotPayload); err != nil {
		t.Fatal(err)
	}
	if len(snapshotPayload.Board) != gomoku.BoardSize*gomoku.BoardSize ||
		!((snapshotPayload.BlackUserID == alice.Session.User.ID && snapshotPayload.WhiteUserID == bob.Session.User.ID) ||
			(snapshotPayload.BlackUserID == bob.Session.User.ID && snapshotPayload.WhiteUserID == alice.Session.User.ID)) {
		t.Fatalf("snapshot identity/board=%+v", snapshotPayload)
	}
	blackID := snapshotPayload.BlackUserID
	blackWS := aliceWS
	if blackID == bob.Session.User.ID {
		blackWS = bobWS
	}
	actionID := "aaaaaaaa-aaaa-4aaa-8aaa-000000000001"
	move := fmt.Sprintf(`{"protocolVersion":1,"gameId":"gomoku","matchId":%s,"expectedRevision":0,"type":"gomoku.move.requested","actionId":%s,"payload":{"x":7,"y":7}}`, quote(matchBody.Match.ID), quote(actionID))
	writeWS(t, blackWS, move)
	aliceEvent, bobEvent := readWSEnvelope(t, aliceWS), readWSEnvelope(t, bobWS)
	if aliceEvent.Type != protocol.TypeGomokuMoveAccepted || bobEvent.Type != protocol.TypeGomokuMoveAccepted || aliceEvent.Revision == nil || *aliceEvent.Revision != 1 || bobEvent.Revision == nil || *bobEvent.Revision != 1 {
		t.Fatalf("broadcast=(%+v,%+v)", aliceEvent, bobEvent)
	}
	staleActionID := "aaaaaaaa-aaaa-4aaa-8aaa-000000000002"
	stale := fmt.Sprintf(`{"protocolVersion":1,"gameId":"gomoku","matchId":%s,"expectedRevision":0,"type":"gomoku.move.requested","actionId":%s,"payload":{"x":8,"y":8}}`, quote(matchBody.Match.ID), quote(staleActionID))
	writeWS(t, bobWS, stale)
	staleError, latest := readWSEnvelope(t, bobWS), readWSEnvelope(t, bobWS)
	if staleError.Type != protocol.TypePlatformError || latest.Type != protocol.TypePlatformSnapshot || latest.Revision == nil || *latest.Revision != 1 || !bytes.Contains(staleError.Payload, []byte(`"code":"stale_revision"`)) {
		t.Fatalf("stale response=(%+v,%+v)", staleError, latest)
	}
	var connectedPayload struct {
		UserID          string `json:"userId"`
		ConnectionID    string `json:"connectionId"`
		ResumeToken     string `json:"resumeToken"`
		ResumeExpiresAt int64  `json:"resumeExpiresAt"`
	}
	if err := json.Unmarshal(aliceConnected.Payload, &connectedPayload); err != nil || connectedPayload.ResumeToken == "" || connectedPayload.UserID != alice.Session.User.ID || !canonicalRequestID(connectedPayload.ConnectionID) || connectedPayload.ResumeExpiresAt != fixture.clock.Now().UTC().Add(30*time.Minute).UnixMilli() {
		t.Fatalf("connected payload=%s err=%v", aliceConnected.Payload, err)
	}
	oldAliceWS := aliceWS
	aliceWS, _, resumedSnapshot := connect("resumeToken", connectedPayload.ResumeToken, 1)
	defer aliceWS.CloseNow()
	if resumedSnapshot.Revision == nil || *resumedSnapshot.Revision != 1 {
		t.Fatalf("resumed snapshot=%+v", resumedSnapshot)
	}
	oldReadContext, cancelOldRead := context.WithTimeout(context.Background(), time.Second)
	_, _, oldReadErr := oldAliceWS.Read(oldReadContext)
	cancelOldRead()
	if oldReadErr == nil {
		t.Fatal("successful resume left the older connection open")
	}
	var offlineSince sql.NullInt64
	if err := fixture.db.QueryRow(`SELECT both_offline_since FROM matches WHERE id=?`, matchBody.Match.ID).Scan(&offlineSince); err != nil || offlineSince.Valid || !fixture.presence.IsOnline(matchBody.Match.ID, alice.Session.User.ID) {
		t.Fatalf("old close clobbered new presence: offline=%v online=%t err=%v", offlineSince, fixture.presence.IsOnline(matchBody.Match.ID, alice.Session.User.ID), err)
	}
	resignID := "aaaaaaaa-aaaa-4aaa-8aaa-000000000003"
	resign := fmt.Sprintf(`{"protocolVersion":1,"gameId":"gomoku","matchId":%s,"expectedRevision":1,"type":"gomoku.resign.requested","actionId":%s,"payload":{}}`, quote(matchBody.Match.ID), quote(resignID))
	writeWS(t, bobWS, resign)
	for _, event := range []protocol.Envelope{readWSEnvelope(t, aliceWS), readWSEnvelope(t, bobWS)} {
		if event.Type != protocol.TypeGomokuResigned || event.Revision == nil || *event.Revision != 2 {
			t.Fatalf("terminal event=%+v", event)
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	revoked, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		cancel()
		t.Fatal(err)
	}
	writeWS(t, revoked, fmt.Sprintf(`{"protocolVersion":1,"type":"platform.connect","payload":{"resumeToken":%s}}`, quote(connectedPayload.ResumeToken)))
	revokedError := readWSEnvelope(t, revoked)
	if revokedError.Type != protocol.TypePlatformError || !bytes.Contains(revokedError.Payload, []byte(`"code":"resume_expired"`)) || bytes.Contains(revokedError.Payload, []byte(connectedPayload.ResumeToken)) {
		t.Fatalf("terminal resume=%+v", revokedError)
	}
	assertWebSocketClose(t, revoked, websocket.StatusPolicyViolation, "resume_expired")
	_ = revoked.CloseNow()
	cancel()
	if strings.Contains(wsURL, aliceTicket) || strings.Contains(fixture.logs.String(), aliceTicket) || strings.Contains(fixture.logs.String(), connectedPayload.ResumeToken) {
		t.Fatalf("credential leaked url=%q logs=%s", wsURL, fixture.logs.String())
	}
}

func TestWebSocketRejectsInvalidHandshakeCredentialReuseAndCrossOrigin(t *testing.T) {
	fixture := newAPIFixture(t)
	alice := fixture.register(t, "ws-invalid-a", "Alice")
	bob := fixture.register(t, "ws-invalid-b", "Bob")
	created := fixture.request(t, http.MethodPost, "/v1/games/gomoku/matches", `{"opponentId":`+quote(bob.Session.User.ID)+`}`, alice.Session.AccessToken)
	var matchBody struct {
		Match struct {
			ID string `json:"id"`
		} `json:"match"`
	}
	decodeResponse(t, created, &matchBody)
	ticketResponse := fixture.request(t, http.MethodPost, "/v1/matches/"+matchBody.Match.ID+"/launch-ticket", `{}`, alice.Session.AccessToken)
	var ticketBody struct {
		LaunchTicket string `json:"launchTicket"`
	}
	decodeResponse(t, ticketResponse, &ticketBody)

	server := httptest.NewServer(fixture.handler)
	defer server.Close()
	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/v1/ws"

	t.Run("first message must be connect", func(t *testing.T) {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		connection, _, err := websocket.Dial(ctx, wsURL, nil)
		if err != nil {
			t.Fatal(err)
		}
		defer connection.CloseNow()
		writeWS(t, connection, `{"protocolVersion":1,"gameId":"gomoku","matchId":"11111111-1111-4111-8111-111111111111","type":"platform.pong","payload":{"nonce":"00000000-0000-4000-8000-000000000001"}}`)
		errorEnvelope := readWSEnvelope(t, connection)
		if errorEnvelope.Type != protocol.TypePlatformError || errorEnvelope.MatchID != "" || errorEnvelope.Revision != nil || !bytes.Contains(errorEnvelope.Payload, []byte(`"code":"invalid_request"`)) {
			t.Fatalf("handshake error=%+v", errorEnvelope)
		}
		assertWebSocketClose(t, connection, websocket.StatusPolicyViolation, "invalid_request")
	})

	t.Run("ticket is consumed once", func(t *testing.T) {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		connection, _, err := websocket.Dial(ctx, wsURL, nil)
		if err != nil {
			cancel()
			t.Fatal(err)
		}
		writeWS(t, connection, fmt.Sprintf(`{"protocolVersion":1,"type":"platform.connect","payload":{"launchTicket":%s}}`, quote(ticketBody.LaunchTicket)))
		if first, second := readWSEnvelope(t, connection), readWSEnvelope(t, connection); first.Type != protocol.TypePlatformConnected || second.Type != protocol.TypePlatformSnapshot {
			t.Fatalf("connected=(%+v,%+v)", first, second)
		}
		_ = connection.Close(websocket.StatusNormalClosure, "")
		cancel()

		ctx, cancel = context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		reused, _, err := websocket.Dial(ctx, wsURL, nil)
		if err != nil {
			t.Fatal(err)
		}
		defer reused.CloseNow()
		writeWS(t, reused, fmt.Sprintf(`{"protocolVersion":1,"type":"platform.connect","payload":{"launchTicket":%s}}`, quote(ticketBody.LaunchTicket)))
		failure := readWSEnvelope(t, reused)
		if failure.Type != protocol.TypePlatformError || !bytes.Contains(failure.Payload, []byte(`"code":"ticket_invalid"`)) || bytes.Contains(failure.Payload, []byte(ticketBody.LaunchTicket)) {
			t.Fatalf("ticket reuse=%+v", failure)
		}
		assertWebSocketClose(t, reused, websocket.StatusPolicyViolation, "ticket_invalid")
	})

	t.Run("query authorization and cross origin are rejected", func(t *testing.T) {
		response, err := server.Client().Get(server.URL + "/v1/ws?launchTicket=" + ticketBody.LaunchTicket)
		if err != nil {
			t.Fatal(err)
		}
		_ = response.Body.Close()
		if response.StatusCode != http.StatusBadRequest {
			t.Fatalf("query status=%d", response.StatusCode)
		}
		const keyMarker = "upgrade-key-secret-marker"
		malformed, err := http.NewRequest(http.MethodGet, server.URL+"/v1/ws", nil)
		if err != nil {
			t.Fatal(err)
		}
		malformed.Header.Set("Connection", "Upgrade")
		malformed.Header.Set("Upgrade", "websocket")
		malformed.Header.Set("Sec-WebSocket-Version", "13")
		malformed.Header.Set("Sec-WebSocket-Key", keyMarker)
		response, err = server.Client().Do(malformed)
		if err != nil {
			t.Fatal(err)
		}
		body, readErr := io.ReadAll(response.Body)
		_ = response.Body.Close()
		if response.StatusCode != http.StatusBadRequest || readErr != nil || bytes.Contains(body, []byte(keyMarker)) || strings.Contains(fixture.logs.String(), keyMarker) {
			t.Fatalf("upgrade error=(%d,%s,%v) logs=%s", response.StatusCode, body, readErr, fixture.logs.String())
		}
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		const originMarker = "origin-secret-marker.example"
		_, response, err = websocket.Dial(ctx, wsURL, &websocket.DialOptions{HTTPHeader: http.Header{"Origin": []string{"https://" + originMarker}}})
		if err == nil || response == nil || response.StatusCode != http.StatusForbidden {
			t.Fatalf("origin response=%v err=%v", response, err)
		}
		body, readErr = io.ReadAll(response.Body)
		_ = response.Body.Close()
		if readErr != nil || bytes.Contains(body, []byte(originMarker)) || strings.Contains(fixture.logs.String(), originMarker) {
			t.Fatalf("origin error leaked input: body=%s logs=%s err=%v", body, fixture.logs.String(), readErr)
		}
	})

	logged := fixture.logs.String()
	if strings.Contains(logged, ticketBody.LaunchTicket) {
		t.Fatalf("logs leaked ticket: %s", logged)
	}
}

func TestWebSocketReceivesCommittedHTTPCancellation(t *testing.T) {
	fixture := newAPIFixture(t)
	alice := fixture.register(t, "ws-cancel-a", "Alice")
	bob := fixture.register(t, "ws-cancel-b", "Bob")
	created := fixture.request(t, http.MethodPost, "/v1/games/gomoku/matches", `{"opponentId":`+quote(bob.Session.User.ID)+`}`, alice.Session.AccessToken)
	var matchBody struct {
		Match struct {
			ID string `json:"id"`
		} `json:"match"`
	}
	decodeResponse(t, created, &matchBody)
	ticketResponse := fixture.request(t, http.MethodPost, "/v1/matches/"+matchBody.Match.ID+"/launch-ticket", `{}`, alice.Session.AccessToken)
	var ticketBody struct {
		LaunchTicket string `json:"launchTicket"`
	}
	decodeResponse(t, ticketResponse, &ticketBody)
	server := httptest.NewServer(fixture.handler)
	defer server.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	connection, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(server.URL, "http")+"/v1/ws", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.CloseNow()
	writeWS(t, connection, fmt.Sprintf(`{"protocolVersion":1,"type":"platform.connect","payload":{"launchTicket":%s}}`, quote(ticketBody.LaunchTicket)))
	connected, snapshot := readWSEnvelope(t, connection), readWSEnvelope(t, connection)
	if connected.Type != protocol.TypePlatformConnected || snapshot.Type != protocol.TypePlatformSnapshot {
		t.Fatalf("initial=(%+v,%+v)", connected, snapshot)
	}
	cancelled := fixture.request(t, http.MethodDelete, "/v1/matches/"+matchBody.Match.ID, "", bob.Session.AccessToken)
	if cancelled.Code != http.StatusNoContent {
		t.Fatalf("cancel=(%d,%s)", cancelled.Code, cancelled.Body.String())
	}
	event := readWSEnvelope(t, connection)
	if event.Type != protocol.TypePlatformMatchCancelled || event.Revision == nil || *event.Revision != 1 {
		t.Fatalf("cancel event=%+v", event)
	}
}

func TestWebSocketFirstMessageDeadlineUsesFrozenInvalidRequestAndClose(t *testing.T) {
	fixture := newAPIFixtureWithHubConfig(t, matches.HubConfig{
		FirstMessageTimeout: 25 * time.Millisecond,
		HeartbeatInterval:   time.Hour,
		ActivityTimeout:     time.Second,
	})
	server := httptest.NewServer(fixture.handler)
	defer server.Close()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	connection, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(server.URL, "http")+"/v1/ws", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.CloseNow()
	started := time.Now()
	failure := readWSEnvelope(t, connection)
	if failure.Type != protocol.TypePlatformError || !bytes.Contains(failure.Payload, []byte(`"code":"invalid_request"`)) || time.Since(started) > 500*time.Millisecond {
		t.Fatalf("first-message timeout=%+v elapsed=%s", failure, time.Since(started))
	}
	assertWebSocketClose(t, connection, websocket.StatusPolicyViolation, "invalid_request")
}

func TestWebSocketBodyHeadersAreRejectedBeforeWaitingForBody(t *testing.T) {
	fixture := newAPIFixture(t)
	server := httptest.NewServer(fixture.handler)
	defer server.Close()
	address := strings.TrimPrefix(server.URL, "http://")
	tests := []struct {
		name   string
		method string
		path   string
		header string
		want   int
	}{
		{name: "websocket chunked", method: http.MethodGet, path: "/v1/ws", header: "Transfer-Encoding: chunked\r\n", want: http.StatusBadRequest},
		{name: "websocket positive content length", method: http.MethodGet, path: "/v1/ws", header: "Content-Length: 1\r\n", want: http.StatusBadRequest},
		{name: "websocket oversized content length", method: http.MethodGet, path: "/v1/ws", header: "Content-Length: 70000\r\n", want: http.StatusBadRequest},
		{name: "websocket method fallback", method: http.MethodPost, path: "/v1/ws", header: "Transfer-Encoding: chunked\r\n", want: http.StatusBadRequest},
		{name: "health method fallback", method: http.MethodPost, path: "/healthz", header: "Content-Length: 1\r\n", want: http.StatusBadRequest},
		{name: "json route retains cap", method: http.MethodPost, path: "/v1/auth/register", header: "Content-Length: 70000\r\n", want: http.StatusRequestEntityTooLarge},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			connection, err := net.DialTimeout("tcp", address, time.Second)
			if err != nil {
				t.Fatal(err)
			}
			defer connection.Close()
			if err := connection.SetDeadline(time.Now().Add(500 * time.Millisecond)); err != nil {
				t.Fatal(err)
			}
			request := test.method + " " + test.path + " HTTP/1.1\r\nHost: " + address + "\r\n" +
				"Connection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\n" +
				"Sec-WebSocket-Key: AAECAwQFBgcICQoLDA0ODw==\r\n" + test.header + "\r\n"
			if _, err := io.WriteString(connection, request); err != nil {
				t.Fatal(err)
			}
			response, err := http.ReadResponse(bufio.NewReader(connection), &http.Request{Method: test.method})
			if err != nil {
				t.Fatalf("server waited for body: %v", err)
			}
			defer response.Body.Close()
			if response.StatusCode != test.want {
				t.Fatalf("status=%d", response.StatusCode)
			}
		})
	}
	if users, matches := countRows(t, fixture.db, "users"), countRows(t, fixture.db, "matches"); users != 0 || matches != 0 {
		t.Fatalf("slow-body rejection mutated state users=%d matches=%d", users, matches)
	}
}

func TestBodylessRouteAllowsExplicitZeroContentLength(t *testing.T) {
	fixture := newAPIFixture(t)
	request := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	request.ContentLength = 0
	request.Header.Set("Content-Length", "0")
	response := httptest.NewRecorder()
	fixture.handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestWebSocketHeartbeatAndPresenceActivitySemantics(t *testing.T) {
	t.Run("matching pong touches", func(t *testing.T) {
		fixture := newAPIFixtureWithHubConfig(t, matches.HubConfig{
			FirstMessageTimeout: time.Second, HeartbeatInterval: 20 * time.Millisecond, ActivityTimeout: 45 * time.Second,
		})
		client := openFixtureWebSocket(t, fixture, "pong")
		ping := readWSEnvelope(t, client.connection)
		if ping.Type != protocol.TypePlatformPing {
			t.Fatalf("heartbeat=%+v", ping)
		}
		var payload struct {
			Nonce string `json:"nonce"`
		}
		if json.Unmarshal(ping.Payload, &payload) != nil || !canonicalRequestID(payload.Nonce) {
			t.Fatalf("ping payload=%s", ping.Payload)
		}
		fixture.clock.Advance(44 * time.Second)
		writeWS(t, client.connection, fmt.Sprintf(`{"protocolVersion":1,"gameId":"gomoku","matchId":%s,"type":"platform.pong","payload":{"nonce":%s}}`, quote(ping.MatchID), quote(payload.Nonce)))
		writeWS(t, client.connection, fmt.Sprintf(`{"protocolVersion":1,"gameId":"gomoku","matchId":%s,"type":"platform.snapshot.requested","payload":{"currentRevision":0}}`, quote(client.matchID)))
		for attempts := 0; ; attempts++ {
			response := readWSEnvelope(t, client.connection)
			if response.Type == protocol.TypePlatformSnapshot {
				break
			}
			if attempts == 20 || response.Type != protocol.TypePlatformPing {
				t.Fatalf("pong processing barrier=%+v", response)
			}
		}
		fixture.clock.Advance(2 * time.Second)
		if err := fixture.presence.Sweep(context.Background()); err != nil {
			t.Fatal(err)
		}
		if !fixture.presence.IsOnline(client.matchID, client.userID) {
			t.Fatal("matching pong did not refresh Presence")
		}
	})

	t.Run("delayed pong remains valid after a newer ping", func(t *testing.T) {
		fixture := newAPIFixtureWithHubConfig(t, matches.HubConfig{
			FirstMessageTimeout: time.Second, HeartbeatInterval: 20 * time.Millisecond, ActivityTimeout: 45 * time.Second,
		})
		client := openFixtureWebSocket(t, fixture, "delayed-pong")
		firstPing := readWSEnvelope(t, client.connection)
		secondPing := readWSEnvelope(t, client.connection)
		if firstPing.Type != protocol.TypePlatformPing || secondPing.Type != protocol.TypePlatformPing {
			t.Fatalf("heartbeats=(%+v,%+v)", firstPing, secondPing)
		}
		var firstPayload struct {
			Nonce string `json:"nonce"`
		}
		if json.Unmarshal(firstPing.Payload, &firstPayload) != nil || !canonicalRequestID(firstPayload.Nonce) {
			t.Fatalf("first ping payload=%s", firstPing.Payload)
		}
		fixture.clock.Advance(44 * time.Second)
		writeWS(t, client.connection, fmt.Sprintf(`{"protocolVersion":1,"gameId":"gomoku","matchId":%s,"type":"platform.pong","payload":{"nonce":%s}}`, quote(client.matchID), quote(firstPayload.Nonce)))
		writeWS(t, client.connection, fmt.Sprintf(`{"protocolVersion":1,"gameId":"gomoku","matchId":%s,"type":"platform.snapshot.requested","payload":{"currentRevision":0}}`, quote(client.matchID)))
		for attempts := 0; ; attempts++ {
			response := readWSEnvelope(t, client.connection)
			if response.Type == protocol.TypePlatformSnapshot {
				break
			}
			if attempts == 20 || response.Type != protocol.TypePlatformPing {
				t.Fatalf("delayed pong response=%+v", response)
			}
		}
		fixture.clock.Advance(2 * time.Second)
		if err := fixture.presence.Sweep(context.Background()); err != nil || !fixture.presence.IsOnline(client.matchID, client.userID) {
			t.Fatalf("delayed pong presence online=%t err=%v", fixture.presence.IsOnline(client.matchID, client.userID), err)
		}
	})

	t.Run("mismatched pong does not touch", func(t *testing.T) {
		fixture := newAPIFixtureWithHubConfig(t, matches.HubConfig{
			FirstMessageTimeout: time.Second, HeartbeatInterval: 20 * time.Millisecond, ActivityTimeout: 45 * time.Second,
		})
		client := openFixtureWebSocket(t, fixture, "wrong-pong")
		ping := readWSEnvelope(t, client.connection)
		if ping.Type != protocol.TypePlatformPing {
			t.Fatalf("heartbeat=%+v", ping)
		}
		var payload struct {
			Nonce string `json:"nonce"`
		}
		if json.Unmarshal(ping.Payload, &payload) != nil || !canonicalRequestID(payload.Nonce) {
			t.Fatalf("ping payload=%s", ping.Payload)
		}
		wrongNonce := payload.Nonce[:len(payload.Nonce)-1] + "0"
		if wrongNonce == payload.Nonce {
			wrongNonce = payload.Nonce[:len(payload.Nonce)-1] + "1"
		}
		fixture.clock.Advance(44 * time.Second)
		writeWS(t, client.connection, fmt.Sprintf(`{"protocolVersion":1,"gameId":"gomoku","matchId":%s,"type":"platform.pong","payload":{"nonce":%s}}`, quote(client.matchID), quote(wrongNonce)))
		for attempts := 0; ; attempts++ {
			response := readWSEnvelope(t, client.connection)
			if response.Type == protocol.TypePlatformError {
				break
			}
			if attempts == 20 || response.Type != protocol.TypePlatformPing {
				t.Fatalf("mismatched pong response=%+v", response)
			}
		}
		fixture.clock.Advance(2 * time.Second)
		if err := fixture.presence.Sweep(context.Background()); err != nil {
			t.Fatal(err)
		}
		if fixture.presence.IsOnline(client.matchID, client.userID) {
			t.Fatal("mismatched pong refreshed Presence")
		}
	})

	t.Run("other valid message touches", func(t *testing.T) {
		fixture := newAPIFixtureWithHubConfig(t, matches.HubConfig{
			FirstMessageTimeout: time.Second, HeartbeatInterval: time.Hour, ActivityTimeout: time.Second,
		})
		client := openFixtureWebSocket(t, fixture, "snapshot-touch")
		fixture.clock.Advance(44 * time.Second)
		writeWS(t, client.connection, fmt.Sprintf(`{"protocolVersion":1,"gameId":"gomoku","matchId":%s,"type":"platform.snapshot.requested","payload":{"currentRevision":0}}`, quote(client.matchID)))
		if response := readWSEnvelope(t, client.connection); response.Type != protocol.TypePlatformSnapshot {
			t.Fatalf("snapshot response=%+v", response)
		}
		fixture.clock.Advance(2 * time.Second)
		if err := fixture.presence.Sweep(context.Background()); err != nil || !fixture.presence.IsOnline(client.matchID, client.userID) {
			t.Fatalf("valid message presence online=%t err=%v", fixture.presence.IsOnline(client.matchID, client.userID), err)
		}
	})

	t.Run("invalid traffic does not touch", func(t *testing.T) {
		fixture := newAPIFixtureWithHubConfig(t, matches.HubConfig{
			FirstMessageTimeout: time.Second, HeartbeatInterval: time.Hour, ActivityTimeout: time.Second,
		})
		client := openFixtureWebSocket(t, fixture, "invalid-touch")
		fixture.clock.Advance(44 * time.Second)
		writeWS(t, client.connection, `{"protocolVersion":1,"type":"platform.connect","payload":{"launchTicket":"invalid"}}`)
		if response := readWSEnvelope(t, client.connection); response.Type != protocol.TypePlatformError {
			t.Fatalf("invalid response=%+v", response)
		}
		fixture.clock.Advance(2 * time.Second)
		if err := fixture.presence.Sweep(context.Background()); err != nil {
			t.Fatal(err)
		}
		if fixture.presence.IsOnline(client.matchID, client.userID) {
			t.Fatal("invalid traffic refreshed Presence")
		}
	})
}

func TestWebSocketActivityDeadlineClosesAndDeletesPresenceConnection(t *testing.T) {
	fixture := newAPIFixtureWithHubConfig(t, matches.HubConfig{
		FirstMessageTimeout: time.Second, HeartbeatInterval: time.Hour, ActivityTimeout: 30 * time.Millisecond,
	})
	client := openFixtureWebSocket(t, fixture, "activity-close")
	readContext, cancel := context.WithTimeout(context.Background(), time.Second)
	_, _, readErr := client.connection.Read(readContext)
	cancel()
	if readErr == nil {
		t.Fatal("inactive connection remained open")
	}
	deadline := time.Now().Add(time.Second)
	for fixture.presence.IsOnline(client.matchID, client.userID) && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if fixture.presence.IsOnline(client.matchID, client.userID) {
		t.Fatal("inactive connection was not deleted from Presence")
	}
}

type fixtureWebSocket struct {
	connection *websocket.Conn
	matchID    string
	userID     string
}

func openFixtureWebSocket(t *testing.T, fixture apiFixture, suffix string) fixtureWebSocket {
	t.Helper()
	alice := fixture.register(t, "ws-timer-a-"+suffix, "Alice")
	bob := fixture.register(t, "ws-timer-b-"+suffix, "Bob")
	created := fixture.request(t, http.MethodPost, "/v1/games/gomoku/matches", `{"opponentId":`+quote(bob.Session.User.ID)+`}`, alice.Session.AccessToken)
	var matchBody struct {
		Match struct {
			ID string `json:"id"`
		} `json:"match"`
	}
	decodeResponse(t, created, &matchBody)
	ticketResponse := fixture.request(t, http.MethodPost, "/v1/matches/"+matchBody.Match.ID+"/launch-ticket", `{}`, alice.Session.AccessToken)
	var ticketBody struct {
		LaunchTicket string `json:"launchTicket"`
	}
	decodeResponse(t, ticketResponse, &ticketBody)
	server := httptest.NewServer(fixture.handler)
	t.Cleanup(server.Close)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	connection, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(server.URL, "http")+"/v1/ws", nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = connection.CloseNow() })
	writeWS(t, connection, fmt.Sprintf(`{"protocolVersion":1,"type":"platform.connect","payload":{"launchTicket":%s}}`, quote(ticketBody.LaunchTicket)))
	connected, snapshot := readWSEnvelope(t, connection), readWSEnvelope(t, connection)
	if connected.Type != protocol.TypePlatformConnected || snapshot.Type != protocol.TypePlatformSnapshot {
		t.Fatalf("initial=(%+v,%+v)", connected, snapshot)
	}
	var payload struct {
		UserID string `json:"userId"`
	}
	if json.Unmarshal(connected.Payload, &payload) != nil || payload.UserID != alice.Session.User.ID {
		t.Fatalf("connected payload=%s", connected.Payload)
	}
	return fixtureWebSocket{connection: connection, matchID: matchBody.Match.ID, userID: payload.UserID}
}

func writeWS(t *testing.T, connection *websocket.Conn, message string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := connection.Write(ctx, websocket.MessageText, []byte(message)); err != nil {
		t.Fatalf("websocket write: %v", err)
	}
}

func readWSEnvelope(t *testing.T, connection *websocket.Conn) protocol.Envelope {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	typeOfMessage, data, err := connection.Read(ctx)
	if err != nil || typeOfMessage != websocket.MessageText {
		t.Fatalf("websocket read type=%v err=%v", typeOfMessage, err)
	}
	envelope, err := protocol.Decode(data)
	if err != nil {
		t.Fatalf("decode websocket message %s: %v", data, err)
	}
	return envelope
}

func assertWebSocketClose(t *testing.T, connection *websocket.Conn, wantStatus websocket.StatusCode, wantReason string) {
	t.Helper()
	readContext, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	_, _, readErr := connection.Read(readContext)
	var closeErr websocket.CloseError
	if !errors.As(readErr, &closeErr) || closeErr.Code != wantStatus || closeErr.Reason != wantReason {
		t.Fatalf("close=(%v,%q) err=%v want=(%v,%q)", closeErr.Code, closeErr.Reason, readErr, wantStatus, wantReason)
	}
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
		{name: "method mismatch with body", method: http.MethodPost, path: "/healthz", body: `{}`, wantStatus: http.StatusBadRequest, wantCode: "invalid_request"},
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
	handler, err := NewRouter(RouterConfig{Auth: fixture.auth, Matches: matchService, Games: games.NewRegistry(), Publisher: fixture.publisher, Hub: fixture.hub, Logger: log.New(fixture.logs, "", 0), RequestIDs: sequentialRequestIDs()})
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
	if count := tableCount(t, fixture.db, "launch_tickets"); count != 1 {
		t.Fatalf("launch ticket rows=%d", count)
	}
	if _, err := matchService.ConnectCredential(context.Background(), matches.CredentialRequest{LaunchTicket: firstTicket.LaunchTicket}); !errors.Is(err, matches.ErrTicketInvalid) {
		t.Fatalf("replaced launch ticket err=%v", err)
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

func TestCancelPublisherPanicCannotChangeCommittedHTTPOutcome(t *testing.T) {
	fixture := newAPIFixture(t)
	alice := fixture.register(t, "publisher-a", "Alice")
	bob := fixture.register(t, "publisher-b", "Bob")
	created := fixture.request(t, http.MethodPost, "/v1/games/gomoku/matches", `{"opponentId":`+quote(bob.Session.User.ID)+`}`, alice.Session.AccessToken)
	var matchBody struct {
		Match struct {
			ID string `json:"id"`
		} `json:"match"`
	}
	decodeResponse(t, created, &matchBody)
	const panicMarker = "publisher-panic-secret-marker"
	handler, err := NewRouter(RouterConfig{
		Auth: fixture.auth, Matches: fixture.matches, Games: games.NewRegistry(),
		Publisher: panickingPublisher{marker: panicMarker}, Hub: fixture.hub, Logger: log.New(fixture.logs, "", 0), RequestIDs: sequentialRequestIDs(),
	})
	if err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodDelete, "/v1/matches/"+matchBody.Match.ID, nil)
	request.Header.Set("Authorization", "Bearer "+alice.Session.AccessToken)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusNoContent || response.Body.Len() != 0 {
		t.Fatalf("publisher panic changed response=(%d,%s)", response.Code, response.Body.String())
	}
	var status string
	var revision, eventCount, slotCount int
	if err := fixture.db.QueryRow(`SELECT status,revision FROM matches WHERE id=?`, matchBody.Match.ID).Scan(&status, &revision); err != nil {
		t.Fatal(err)
	}
	if err := fixture.db.QueryRow(`SELECT COUNT(*) FROM match_events WHERE match_id=?`, matchBody.Match.ID).Scan(&eventCount); err != nil {
		t.Fatal(err)
	}
	if err := fixture.db.QueryRow(`SELECT COUNT(*) FROM active_game_slots WHERE match_id=?`, matchBody.Match.ID).Scan(&slotCount); err != nil {
		t.Fatal(err)
	}
	if status != matches.StatusCancelled || revision != 1 || eventCount != 1 || slotCount != 0 {
		t.Fatalf("committed cancel=(%s,%d events=%d slots=%d)", status, revision, eventCount, slotCount)
	}
	if strings.Contains(fixture.logs.String(), panicMarker) || strings.Contains(response.Body.String(), panicMarker) {
		t.Fatalf("publisher panic leaked: logs=%s response=%s", fixture.logs.String(), response.Body.String())
	}
}

func TestRegisterEndpointRollsBackUserAndInviteWhenSessionInsertFails(t *testing.T) {
	fixture := newAPIFixture(t)
	fixture.addInvite(t, "atomic-register-invite")
	if _, err := fixture.db.Exec(`
CREATE TRIGGER fail_atomic_registration BEFORE INSERT ON refresh_tokens
BEGIN SELECT RAISE(ABORT,'refresh-insert-secret-marker'); END;`); err != nil {
		t.Fatal(err)
	}
	response := fixture.request(t, http.MethodPost, "/v1/auth/register", `{"inviteCode":"atomic-register-invite","nickname":"Alice"}`, "")
	if response.Code != http.StatusInternalServerError || responseErrorCode(t, response) != "internal_error" {
		t.Fatalf("registration failure=(%d,%s)", response.Code, response.Body.String())
	}
	if countRows(t, fixture.db, "users") != 0 {
		t.Fatal("failed session issuance left a registered user")
	}
	hash, _ := auth.HashToken(testTokenPepper, "atomic-register-invite")
	var consumedBy sql.NullString
	var consumedAt sql.NullInt64
	if err := fixture.db.QueryRow(`SELECT consumed_by,consumed_at FROM invite_codes WHERE code_hash=?`, hash).Scan(&consumedBy, &consumedAt); err != nil || consumedBy.Valid || consumedAt.Valid {
		t.Fatalf("failed session issuance consumed invite=(%v,%v) err=%v", consumedBy, consumedAt, err)
	}
	if strings.Contains(fixture.logs.String(), "atomic-register-invite") || strings.Contains(response.Body.String(), "refresh-insert-secret-marker") {
		t.Fatal("atomic registration failure leaked request or database detail")
	}
}

func TestRequestLoggingNeverUsesAttackerControlledMethod(t *testing.T) {
	fixture := newAPIFixture(t)
	methods := []string{"invite-secret-method", "refresh-secret-method", "launch-secret-method", "eyJhbGciOiJIUzI1NiJ9"}
	for _, method := range methods {
		request := httptest.NewRequest(method, "/healthz", nil)
		response := httptest.NewRecorder()
		fixture.handler.ServeHTTP(response, request)
		if response.Code != http.StatusMethodNotAllowed {
			t.Fatalf("method %q status=%d", method, response.Code)
		}
	}
	logged := fixture.logs.String()
	for _, method := range methods {
		if strings.Contains(logged, method) {
			t.Fatalf("attacker method leaked in log: %s", logged)
		}
	}
	if count := strings.Count(logged, "method=OTHER"); count != len(methods) {
		t.Fatalf("safe method count=%d logs=%s", count, logged)
	}
}

func TestSafeMethodLoggingCoversRequestIDFailureAndPanicBranches(t *testing.T) {
	const methodSecret = "launch-ticket-shaped-secret-method"
	t.Run("request id failure", func(t *testing.T) {
		logs := &bytes.Buffer{}
		handler := requestMiddleware(log.New(logs, "", 0), func() (string, error) {
			return "", errors.New("private request id failure")
		})(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
			t.Fatal("next handler ran after request id failure")
		}))
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, httptest.NewRequest(methodSecret, "/secret-method-path", nil))
		if response.Code != http.StatusInternalServerError || strings.Contains(logs.String(), methodSecret) || !strings.Contains(logs.String(), "method=OTHER") {
			t.Fatalf("request id failure=(%d logs=%s)", response.Code, logs.String())
		}
	})

	t.Run("panic recovery", func(t *testing.T) {
		logs := &bytes.Buffer{}
		handler := requestMiddleware(log.New(logs, "", 0), sequentialRequestIDs())(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
			panic("private panic detail")
		}))
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, httptest.NewRequest(methodSecret, "/secret-method-path", nil))
		if response.Code != http.StatusInternalServerError || strings.Contains(logs.String(), methodSecret) || strings.Contains(logs.String(), "private panic detail") || !strings.Contains(logs.String(), "method=OTHER") || !strings.Contains(logs.String(), "panic=true") {
			t.Fatalf("panic branch=(%d logs=%s)", response.Code, logs.String())
		}
	})
}

func TestBodyLimitsAndBodylessRoutesFailBeforeMutation(t *testing.T) {
	t.Run("bodyless content length is rejected before the global cap", func(t *testing.T) {
		fixture := newAPIFixture(t)
		body := strings.Repeat("x", 65*1024)
		response := fixture.request(t, http.MethodGet, "/healthz", body, "")
		assertInvalidRequest(t, response)
	})

	t.Run("bodyless get and delete", func(t *testing.T) {
		fixture := newAPIFixture(t)
		get := fixture.request(t, http.MethodGet, "/healthz", `{}`, "")
		assertInvalidRequest(t, get)
		alice := fixture.register(t, "body-a", "Alice")
		bob := fixture.register(t, "body-b", "Bob")
		created := fixture.request(t, http.MethodPost, "/v1/games/gomoku/matches", `{"opponentId":`+quote(bob.Session.User.ID)+`}`, alice.Session.AccessToken)
		var matchBody struct {
			Match struct {
				ID string `json:"id"`
			} `json:"match"`
		}
		decodeResponse(t, created, &matchBody)
		deleted := fixture.request(t, http.MethodDelete, "/v1/matches/"+matchBody.Match.ID, `{}`, alice.Session.AccessToken)
		assertInvalidRequest(t, deleted)
		var status string
		if err := fixture.db.QueryRow(`SELECT status FROM matches WHERE id=?`, matchBody.Match.ID).Scan(&status); err != nil || status != matches.StatusActive {
			t.Fatalf("delete body mutated match status=%q err=%v", status, err)
		}
		if len(fixture.publisher.snapshot()) != 0 {
			t.Fatal("delete body published an event")
		}
	})

	t.Run("chunked json overlimit closes real connection", func(t *testing.T) {
		fixture := newAPIFixture(t)
		fixture.addInvite(t, "chunked-overlimit-invite")
		server := httptest.NewServer(fixture.handler)
		defer server.Close()
		large := `{"inviteCode":"chunked-overlimit-invite","nickname":"` + strings.Repeat("x", 65*1024) + `"}`
		request, err := http.NewRequest(http.MethodPost, server.URL+"/v1/auth/register", io.NopCloser(strings.NewReader(large)))
		if err != nil {
			t.Fatal(err)
		}
		request.ContentLength = -1
		request.TransferEncoding = []string{"chunked"}
		request.Header.Set("Content-Type", "application/json")
		response, err := server.Client().Do(request)
		if err != nil {
			t.Fatal(err)
		}
		defer response.Body.Close()
		data, _ := io.ReadAll(response.Body)
		if response.StatusCode != http.StatusRequestEntityTooLarge || !response.Close {
			t.Fatalf("chunked response=(%d close=%t body=%s)", response.StatusCode, response.Close, data)
		}
		if countRows(t, fixture.db, "users") != 0 {
			t.Fatal("overlimit chunked body created user")
		}
	})
}

func TestHTTPSurrogateEscapesAreLossless(t *testing.T) {
	invalid := []string{
		`{"inviteCode":"surrogate-invite","nickname":"A\uD800"}`,
		`{"inviteCode":"surrogate-invite","nickname":"A\uDC00"}`,
		`{"inviteCode":"surrogate-invite","nickname":"A\uD800x"}`,
		`{"inviteCode":"surrogate-invite","nickname":"A\uD800\u0041"}`,
	}
	for index, body := range invalid {
		t.Run(fmt.Sprintf("invalid-%d", index), func(t *testing.T) {
			fixture := newAPIFixture(t)
			fixture.addInvite(t, "surrogate-invite")
			response := fixture.request(t, http.MethodPost, "/v1/auth/register", body, "")
			assertInvalidRequest(t, response)
			if countRows(t, fixture.db, "users") != 0 {
				t.Fatal("isolated surrogate created user")
			}
		})
	}
	for _, test := range []struct {
		name     string
		body     string
		nickname string
	}{
		{name: "valid pair", body: `{"inviteCode":"surrogate-invite","nickname":"A\uD83D\uDE00"}`, nickname: "A😀"},
		{name: "escaped literal", body: `{"inviteCode":"surrogate-invite","nickname":"A\\uD800"}`, nickname: `A\uD800`},
	} {
		t.Run(test.name, func(t *testing.T) {
			fixture := newAPIFixture(t)
			fixture.addInvite(t, "surrogate-invite")
			response := fixture.request(t, http.MethodPost, "/v1/auth/register", test.body, "")
			if response.Code != http.StatusCreated {
				t.Fatalf("valid surrogate path=(%d,%s)", response.Code, response.Body.String())
			}
			var session sessionResponse
			decodeResponse(t, response, &session)
			if session.Session.User.Nickname != test.nickname {
				t.Fatalf("nickname=%q want %q", session.Session.User.Nickname, test.nickname)
			}
		})
	}
}

func TestHTTPSurrogateLexicalScannerCoversKeysAndValues(t *testing.T) {
	for _, document := range []string{
		`{"\uD800":"value"}`,
		`{"\uDC00":"value"}`,
		`{"key":"\uD800"}`,
		`{"key":"\uDC00"}`,
	} {
		if validHTTPJSONSurrogateEscapes([]byte(document)) {
			t.Fatalf("accepted isolated surrogate in %s", document)
		}
	}
	for _, document := range []string{
		`{"\uD83D\uDE00":"value"}`,
		`{"key":"\uD83D\uDE00"}`,
		`{"\\uD800":"literal","key":"\\uDC00"}`,
	} {
		if !validHTTPJSONSurrogateEscapes([]byte(document)) {
			t.Fatalf("rejected lossless surrogate spelling in %s", document)
		}
	}
}

func TestMatchPathRequiresLiteralCanonicalUUIDBeforeMutation(t *testing.T) {
	fixture := newAPIFixture(t)
	alice := fixture.register(t, "path-a", "Alice")
	bob := fixture.register(t, "path-b", "Bob")
	created := fixture.request(t, http.MethodPost, "/v1/games/gomoku/matches", `{"opponentId":`+quote(bob.Session.User.ID)+`}`, alice.Session.AccessToken)
	var matchBody struct {
		Match struct {
			ID string `json:"id"`
		} `json:"match"`
	}
	decodeResponse(t, created, &matchBody)
	escaped := fmt.Sprintf("%%%02X%s", matchBody.Match.ID[0], matchBody.Match.ID[1:])
	paths := []string{strings.ToUpper(matchBody.Match.ID), "{" + matchBody.Match.ID + "}", escaped}
	for _, value := range paths {
		t.Run(value, func(t *testing.T) {
			for _, route := range []struct {
				method string
				path   string
			}{
				{method: http.MethodDelete, path: "/v1/matches/" + value},
				{method: http.MethodPost, path: "/v1/matches/" + value + "/launch-ticket"},
			} {
				response := fixture.request(t, route.method, route.path, "", alice.Session.AccessToken)
				assertInvalidRequest(t, response)
			}
		})
	}
	var status string
	if err := fixture.db.QueryRow(`SELECT status FROM matches WHERE id=?`, matchBody.Match.ID).Scan(&status); err != nil || status != matches.StatusActive {
		t.Fatalf("noncanonical path mutated match=%q err=%v", status, err)
	}
	if tableCount(t, fixture.db, "launch_tickets") != 0 || len(fixture.publisher.snapshot()) != 0 {
		t.Fatal("noncanonical path created ticket or published event")
	}
}

func TestExtremeClocksFailClosedForLobbyAndLaunchTicket(t *testing.T) {
	fixture := newAPIFixture(t)
	alice := fixture.register(t, "clock-a", "Alice")
	bob := fixture.register(t, "clock-b", "Bob")
	created := fixture.request(t, http.MethodPost, "/v1/games/gomoku/matches", `{"opponentId":`+quote(bob.Session.User.ID)+`}`, alice.Session.AccessToken)
	var matchBody struct {
		Match struct {
			ID string `json:"id"`
		} `json:"match"`
	}
	decodeResponse(t, created, &matchBody)
	newService := func(nowMillis int64) *matches.Service {
		service, err := matches.NewServiceWithConfig(fixture.db, games.NewRegistry(), clock.NewFake(time.UnixMilli(nowMillis)), matches.ServiceConfig{
			ColorRandom: bytes.NewReader([]byte{0}), LaunchTicketRandom: bytes.NewReader(bytes.Repeat([]byte{3}, 64)), TokenPepper: testTokenPepper,
		})
		if err != nil {
			t.Fatal(err)
		}
		return service
	}
	if opponents, err := newService(math.MinInt64).ListOpponents(context.Background(), gomoku.GameID, alice.Session.User.ID); !errors.Is(err, matches.ErrInternal) || opponents != nil {
		t.Fatalf("minimum clock opponents=(%+v,%v)", opponents, err)
	}
	if ticket, err := newService(math.MaxInt64).CreateLaunchTicket(context.Background(), matchBody.Match.ID, alice.Session.User.ID); !errors.Is(err, matches.ErrInternal) || ticket.Token != "" {
		t.Fatalf("maximum clock ticket=(%+v,%v)", ticket, err)
	}
	if tableCount(t, fixture.db, "launch_tickets") != 0 {
		t.Fatal("overflow clock persisted launch ticket")
	}
}

func TestGetRoutesAdvertiseAndHonorHEAD(t *testing.T) {
	fixture := newAPIFixture(t)
	alice := fixture.register(t, "head-a", "Alice")
	for _, path := range []string{"/healthz", "/v1/games", "/v1/games/gomoku/status", "/v1/games/gomoku/opponents"} {
		request := httptest.NewRequest(http.MethodOptions, path, nil)
		response := httptest.NewRecorder()
		fixture.handler.ServeHTTP(response, request)
		if response.Code != http.StatusMethodNotAllowed || response.Header().Get("Allow") != "GET, HEAD" {
			t.Fatalf("OPTIONS %s=(%d Allow=%q)", path, response.Code, response.Header().Get("Allow"))
		}
	}
	server := httptest.NewServer(fixture.handler)
	defer server.Close()
	for _, test := range []struct {
		path  string
		token string
	}{{path: "/healthz"}, {path: "/v1/games", token: alice.Session.AccessToken}} {
		request, _ := http.NewRequest(http.MethodHead, server.URL+test.path, nil)
		if test.token != "" {
			request.Header.Set("Authorization", "Bearer "+test.token)
		}
		response, err := server.Client().Do(request)
		if err != nil {
			t.Fatal(err)
		}
		data, _ := io.ReadAll(response.Body)
		_ = response.Body.Close()
		if response.StatusCode != http.StatusOK || len(data) != 0 || response.Header.Get("Content-Type") != "application/json; charset=utf-8" {
			t.Fatalf("HEAD %s=(%d body=%q contentType=%q)", test.path, response.StatusCode, data, response.Header.Get("Content-Type"))
		}
	}
	postFallback := fixture.request(t, http.MethodOptions, "/v1/auth/register", "", "")
	if postFallback.Code != http.StatusMethodNotAllowed || postFallback.Header().Get("Allow") != http.MethodPost {
		t.Fatalf("POST fallback=(%d Allow=%q)", postFallback.Code, postFallback.Header().Get("Allow"))
	}
	meFallback := fixture.request(t, http.MethodOptions, "/v1/me", "", "")
	if meFallback.Code != http.StatusMethodNotAllowed || meFallback.Header().Get("Allow") != "GET, HEAD, PATCH" {
		t.Fatalf("me fallback=(%d Allow=%q)", meFallback.Code, meFallback.Header().Get("Allow"))
	}
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
		{Matches: fixture.matches, Games: games.NewRegistry(), Publisher: fixture.publisher, Hub: fixture.hub, Logger: log.Default(), RequestIDs: sequentialRequestIDs()},
		{Auth: fixture.auth, Games: games.NewRegistry(), Publisher: fixture.publisher, Hub: fixture.hub, Logger: log.Default(), RequestIDs: sequentialRequestIDs()},
		{Auth: fixture.auth, Matches: fixture.matches, Publisher: fixture.publisher, Hub: fixture.hub, Logger: log.Default(), RequestIDs: sequentialRequestIDs()},
		{Auth: fixture.auth, Matches: fixture.matches, Games: games.NewRegistry(), Hub: fixture.hub, Logger: log.Default(), RequestIDs: sequentialRequestIDs()},
		{Auth: fixture.auth, Matches: fixture.matches, Games: games.NewRegistry(), Publisher: fixture.publisher, Logger: log.Default(), RequestIDs: sequentialRequestIDs()},
		{Auth: fixture.auth, Matches: fixture.matches, Games: games.NewRegistry(), Publisher: fixture.publisher, Hub: fixture.hub, RequestIDs: sequentialRequestIDs()},
		{Auth: fixture.auth, Matches: fixture.matches, Games: games.NewRegistry(), Publisher: fixture.publisher, Hub: fixture.hub, Logger: log.Default()},
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
