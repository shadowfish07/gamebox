package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"me.zqydev/gamebox/server/internal/games/gomoku"
	"me.zqydev/gamebox/server/internal/lan/room"
	"me.zqydev/gamebox/server/internal/protocol"
)

const (
	testRoomID      = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
	testHostID      = "11111111-1111-4111-8111-111111111111"
	testAttemptID   = "33333333-3333-4333-8333-333333333333"
	testMoveID      = "55555555-5555-4555-8555-555555555555"
	testResignID    = "66666666-6666-4666-8666-666666666666"
	testPepper      = "http-test-token-pepper-at-least-thirty-two-bytes"
	testRoomKey     = "http-room-key-private-canary"
	testHostResume  = "http-host-resume-private-canary"
	testGuestResume = "http-guest-resume-private-canary"
)

func TestJoinResumeAndResultHTTPContracts(t *testing.T) {
	service := newTestRoom(t, 1_000, 100_000)
	router, err := NewRouter(service)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = router.Close(context.Background()) })

	joinBody := `{"roomId":"` + testRoomID + `","nickname":" Guest ","joinAttemptId":"` + testAttemptID + `","candidateResumeToken":"` + testGuestResume + `","roomKey":"` + testRoomKey + `"}`
	wrongKeyBody := strings.Replace(joinBody, testRoomKey, testRoomKey+"-wrong", 1)
	assertAPIError(t, performJSON(t, router, http.MethodPost, "/lan/v1/rooms/"+testRoomID+"/join", wrongKeyBody), http.StatusForbidden, "room_key_invalid")

	first := performJSON(t, router, http.MethodPost, "/lan/v1/rooms/"+testRoomID+"/join", joinBody)
	assertStatusAndType(t, first, http.StatusOK)
	var joined launchResponse
	decodeResponse(t, first, &joined)
	if joined.SchemaVersion != 1 || joined.MatchID != testRoomID || joined.GameID != gomoku.GameID || joined.PlayerID == "" || joined.LaunchTicket == "" || joined.ExpiresAt != 61_000 {
		t.Fatalf("join response = %#v", joined)
	}

	retry := performJSON(t, router, http.MethodPost, "/lan/v1/rooms/"+testRoomID+"/join", joinBody)
	assertStatusAndType(t, retry, http.StatusOK)
	var retried launchResponse
	decodeResponse(t, retry, &retried)
	if retried.PlayerID != joined.PlayerID || retried.LaunchTicket == joined.LaunchTicket {
		t.Fatalf("retry response = %#v, first = %#v", retried, joined)
	}

	lockedBody := strings.Replace(joinBody, testAttemptID, "44444444-4444-4444-8444-444444444444", 1)
	assertAPIError(t, performJSON(t, router, http.MethodPost, "/lan/v1/rooms/"+testRoomID+"/join", lockedBody), http.StatusConflict, "room_locked")

	resumeBody := `{"roomId":"` + testRoomID + `","playerId":"` + joined.PlayerID + `","resumeToken":"` + testGuestResume + `"}`
	resumed := performJSON(t, router, http.MethodPost, "/lan/v1/rooms/"+testRoomID+"/resume-ticket", resumeBody)
	assertStatusAndType(t, resumed, http.StatusOK)
	var resumeLaunch launchResponse
	decodeResponse(t, resumed, &resumeLaunch)
	if resumeLaunch.PlayerID != joined.PlayerID || resumeLaunch.LaunchTicket == "" {
		t.Fatalf("resume response = %#v", resumeLaunch)
	}
	badResume := strings.Replace(resumeBody, testGuestResume, testGuestResume+"-wrong", 1)
	assertAPIError(t, performJSON(t, router, http.MethodPost, "/lan/v1/rooms/"+testRoomID+"/resume-ticket", badResume), http.StatusUnauthorized, "resume_invalid")

	resultPath := "/lan/v1/rooms/" + testRoomID + "/result"
	assertAPIError(t, performJSON(t, router, http.MethodGet, resultPath, `{"resumeToken":"`+testGuestResume+`"}`), http.StatusConflict, "match_not_finished")

	black := playerByColor(t, service.Snapshot(), room.ColorBlack)
	if _, _, _, err := service.Apply(context.Background(), room.ActionRequest{PlayerID: black.PlayerID, ActionID: testMoveID, ExpectedRevision: 0, Type: gomoku.MoveRequested, Payload: json.RawMessage(`{"x":1,"y":1}`)}); err != nil {
		t.Fatal(err)
	}
	resigner := joined.PlayerID
	if resigner == black.PlayerID {
		resigner = testHostID
	}
	if _, _, _, err := service.Apply(context.Background(), room.ActionRequest{PlayerID: resigner, ActionID: testResignID, ExpectedRevision: 1, Type: protocol.TypeGomokuResignRequested, Payload: json.RawMessage(`{}`)}); err != nil {
		t.Fatal(err)
	}

	resultHTTP := performJSON(t, router, http.MethodGet, resultPath, `{"resumeToken":"`+testGuestResume+`"}`)
	assertStatusAndType(t, resultHTTP, http.StatusOK)
	var result resultResponse
	decodeResponse(t, resultHTTP, &result)
	if result.SchemaVersion != 1 || len(result.ResultHash) != 64 || string(result.Result) != "null" {
		t.Fatalf("result response = %#v", result)
	}
	ackBody := `{"resumeToken":"` + testGuestResume + `","resultHash":"` + result.ResultHash + `"}`
	for attempt := 0; attempt < 2; attempt++ {
		ack := performJSON(t, router, http.MethodPost, "/lan/v1/rooms/"+testRoomID+"/result-ack", ackBody)
		assertStatusAndType(t, ack, http.StatusOK)
		if strings.TrimSpace(ack.Body.String()) != `{"schemaVersion":1,"acknowledged":true}` {
			t.Fatalf("ack body = %q", ack.Body.String())
		}
	}
	badHash := strings.Replace(ackBody, result.ResultHash, strings.Repeat("0", 64), 1)
	assertAPIError(t, performJSON(t, router, http.MethodPost, "/lan/v1/rooms/"+testRoomID+"/result-ack", badHash), http.StatusConflict, "result_hash_mismatch")
}

func TestWebSocketRouteRejectsCredentialHeadersBeforeUpgrade(t *testing.T) {
	service := newTestRoom(t, 1_000, 100_000)
	router, err := NewRouter(service)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = router.Close(context.Background()) })
	request := httptest.NewRequest(http.MethodGet, "/lan/v1/ws", nil)
	request.Header.Set("Authorization", "Bearer "+testGuestResume)
	response := httptest.NewRecorder()
	router.ServeHTTP(response, request)
	assertAPIError(t, response, http.StatusBadRequest, "invalid_request")
	if strings.Contains(response.Body.String(), testGuestResume) {
		t.Fatal("response exposed credential header")
	}
}

func TestHTTPBodiesAreExactBoundedSingleJSONDocuments(t *testing.T) {
	service := newTestRoom(t, 1_000, 100_000)
	router, err := NewRouter(service)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = router.Close(context.Background()) })
	path := "/lan/v1/rooms/" + testRoomID + "/join"
	valid := `{"roomId":"` + testRoomID + `","nickname":"Guest","joinAttemptId":"` + testAttemptID + `","candidateResumeToken":"` + testGuestResume + `","roomKey":"` + testRoomKey + `"}`
	tests := map[string]string{
		"unknown field":   strings.Replace(valid, `"nickname":`, `"extra":true,"nickname":`, 1),
		"duplicate field": strings.Replace(valid, `"nickname":"Guest"`, `"nickname":"Guest","nickname":"Other"`, 1),
		"trailing json":   valid + `{}`,
		"path mismatch":   strings.Replace(valid, testRoomID, "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", 1),
		"nested too deep": strings.Replace(valid, `"nickname":"Guest"`, `"nickname":"`+strings.Repeat("x", 2)+`","roomKeyNested":`+strings.Repeat("[", 33)+`0`+strings.Repeat("]", 33), 1),
	}
	for name, body := range tests {
		t.Run(name, func(t *testing.T) {
			assertAPIError(t, performJSON(t, router, http.MethodPost, path, body), http.StatusBadRequest, "invalid_request")
		})
	}

	request := httptest.NewRequest(http.MethodPost, path, strings.NewReader(valid))
	request.Header.Set("Content-Type", "application/json; charset=utf-8")
	response := httptest.NewRecorder()
	router.ServeHTTP(response, request)
	assertAPIError(t, response, http.StatusBadRequest, "invalid_request")

	oversized := `{"roomId":"` + strings.Repeat("x", 70*1024) + `"}`
	over := performJSON(t, router, http.MethodPost, path, oversized)
	assertAPIError(t, over, http.StatusRequestEntityTooLarge, "invalid_request")
}

func TestRoutesRejectUnknownMethodsQueriesAndRedirectShapes(t *testing.T) {
	service := newTestRoom(t, 1_000, 100_000)
	router, err := NewRouter(service)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = router.Close(context.Background()) })
	tests := []struct {
		method, path, allow string
	}{
		{http.MethodGet, "/lan/v1/rooms/" + testRoomID + "/join", http.MethodPost},
		{http.MethodPut, "/lan/v1/rooms/" + testRoomID + "/resume-ticket", http.MethodPost},
		{http.MethodHead, "/lan/v1/rooms/" + testRoomID + "/result", http.MethodGet},
		{http.MethodDelete, "/lan/v1/rooms/" + testRoomID + "/result-ack", http.MethodPost},
		{http.MethodPost, "/lan/v1/ws", http.MethodGet},
	}
	for _, test := range tests {
		t.Run(test.method+" "+test.path, func(t *testing.T) {
			response := performJSON(t, router, test.method, test.path, "")
			assertAPIError(t, response, http.StatusMethodNotAllowed, "method_not_allowed")
			if response.Header().Get("Allow") != test.allow {
				t.Fatalf("%s %s Allow = %q", test.method, test.path, response.Header().Get("Allow"))
			}
		})
	}
	for _, path := range []string{
		"/lan/v1/rooms/" + testRoomID + "/join/",
		"/lan//v1/rooms/" + testRoomID + "/join",
		"/lan/v1/rooms/" + testRoomID + "/result?resumeToken=" + testGuestResume,
	} {
		response := performJSON(t, router, http.MethodGet, path, "")
		if response.Code != http.StatusBadRequest && response.Code != http.StatusNotFound {
			t.Fatalf("path %q status = %d", path, response.Code)
		}
		if response.Code >= 300 && response.Code < 400 {
			t.Fatalf("path %q redirected", path)
		}
	}
}

func TestExpiredJoinAndRoomKeyErrorsNeverReflectSecrets(t *testing.T) {
	service := newTestRoom(t, 10_000, 5_000)
	router, err := NewRouter(service)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = router.Close(context.Background()) })
	body := `{"roomId":"` + testRoomID + `","nickname":"Guest","joinAttemptId":"` + testAttemptID + `","candidateResumeToken":"` + testGuestResume + `","roomKey":"` + testRoomKey + `"}`
	response := performJSON(t, router, http.MethodPost, "/lan/v1/rooms/"+testRoomID+"/join", body)
	assertAPIError(t, response, http.StatusGone, "join_expired")
	for _, secret := range []string{testRoomKey, testGuestResume} {
		if strings.Contains(response.Body.String(), secret) || strings.Contains(response.Header().Get("Location"), secret) {
			t.Fatal("response exposed credential")
		}
	}
}

type resultResponse struct {
	SchemaVersion int             `json:"schemaVersion"`
	ResultHash    string          `json:"resultHash"`
	Result        json.RawMessage `json:"result"`
}

func newTestRoom(t *testing.T, now, expires int64) *room.Service {
	t.Helper()
	clockNow := int64(1_000)
	credentialEntropy := make([]byte, 0, 32*32)
	for value := byte(1); value <= 32; value++ {
		credentialEntropy = append(credentialEntropy, bytes.Repeat([]byte{value}, 32)...)
	}
	service, err := room.Open(room.Config{
		Root: t.TempDir(), Clock: func() time.Time { return time.UnixMilli(clockNow) },
		ColorRandom: bytes.NewReader([]byte{0}), PlayerRandom: bytes.NewReader(bytes.Repeat([]byte{0x22}, 128)),
		CredentialRandom: bytes.NewReader(credentialEntropy), TokenPepper: testPepper,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = service.Close() })
	_, err = service.Create(context.Background(), room.CreateRequest{
		RoomID: testRoomID, HostPlayerID: testHostID, HostNickname: "Host", RoomKey: testRoomKey,
		TokenPepper: testPepper, HostResumeToken: testHostResume, JoinExpiresAt: expires,
	})
	if err != nil {
		t.Fatal(err)
	}
	clockNow = now
	return service
}

func performJSON(t *testing.T, handler http.Handler, method, path, body string) *httptest.ResponseRecorder {
	t.Helper()
	request := httptest.NewRequest(method, path, strings.NewReader(body))
	if body != "" {
		request.Header.Set("Content-Type", "application/json")
	}
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	return response
}

func decodeResponse(t *testing.T, response *httptest.ResponseRecorder, target any) {
	t.Helper()
	decoder := json.NewDecoder(response.Body)
	if err := decoder.Decode(target); err != nil {
		t.Fatal(err)
	}
	if _, err := decoder.Token(); err != io.EOF {
		t.Fatalf("response has trailing JSON: %v", err)
	}
}

func assertStatusAndType(t *testing.T, response *httptest.ResponseRecorder, status int) {
	t.Helper()
	if response.Code != status {
		t.Fatalf("status = %d, body = %s", response.Code, response.Body.String())
	}
	if response.Header().Get("Content-Type") != "application/json; charset=utf-8" {
		t.Fatalf("Content-Type = %q", response.Header().Get("Content-Type"))
	}
}

func assertAPIError(t *testing.T, response *httptest.ResponseRecorder, status int, code string) {
	t.Helper()
	assertStatusAndType(t, response, status)
	var payload struct {
		Error struct {
			Code    string         `json:"code"`
			Message string         `json:"message"`
			Details map[string]any `json:"details"`
		} `json:"error"`
	}
	decodeResponse(t, response, &payload)
	if payload.Error.Code != code || payload.Error.Message == "" || len(payload.Error.Details) != 0 {
		t.Fatalf("error payload = %#v", payload)
	}
}

func playerByColor(t *testing.T, snapshot room.Snapshot, color room.Color) room.Player {
	t.Helper()
	for _, player := range snapshot.Players {
		if player.Color == color {
			return player
		}
	}
	t.Fatal("player color not found")
	return room.Player{}
}
