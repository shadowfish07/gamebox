package httpapi

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"github.com/coder/websocket"
	"me.zqydev/gamebox/server/internal/auth"
	"me.zqydev/gamebox/server/internal/matches"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestDeviceTransferHTTPRevokesLiveConnectionAndPreservesMatch(t *testing.T) {
	f := newAPIFixture(t)
	old := f.register(t, "transfer-a", "Alice")
	other := f.register(t, "transfer-b", "Bob")
	created := f.request(t, "POST", "/v1/games/gomoku/matches", `{"opponentId":`+quote(other.Session.User.ID)+`}`, old.Session.AccessToken)
	var match struct {
		Match struct {
			ID string `json:"id"`
		} `json:"match"`
	}
	decodeResponse(t, created, &match)
	ticketResponse := f.request(t, "POST", "/v1/matches/"+match.Match.ID+"/launch-ticket", `{}`, old.Session.AccessToken)
	var ticket struct {
		LaunchTicket string `json:"launchTicket"`
	}
	decodeResponse(t, ticketResponse, &ticket)
	server := httptest.NewServer(f.handler)
	defer server.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	ws, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(server.URL, "http")+"/v1/ws", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer ws.CloseNow()
	writeWS(t, ws, `{"protocolVersion":1,"type":"platform.connect","payload":{"launchTicket":`+quote(ticket.LaunchTicket)+`}}`)
	connected := readWSEnvelope(t, ws)
	readWSEnvelope(t, ws)
	var resumed struct {
		ResumeToken string `json:"resumeToken"`
	}
	json.Unmarshal(connected.Payload, &resumed)
	// Admin recovery uses precisely the same public redemption route.
	code, err := f.auth.CreateRecovery(ctx, old.Session.User.ID)
	if err != nil {
		t.Fatal(err)
	}
	secret := base64.RawURLEncoding.EncodeToString([]byte(strings.Repeat("x", 32)))
	body, _ := json.Marshal(map[string]string{"code": code.Code, "receiver": secret})
	result := f.request(t, "POST", "/v1/auth/transfer/redeem", string(body), "")
	if result.Code != 200 {
		t.Fatal("redeem status", result.Code)
	}
	var envelope struct {
		Session  sessionPayload `json:"session"`
		Snapshot string         `json:"snapshot"`
	}
	decodeResponse(t, result, &envelope)
	if envelope.Session.User.ID != old.Session.User.ID {
		t.Fatal("new identity")
	}
	if _, _, err = ws.Read(ctx); err == nil {
		t.Fatal("old socket remained open")
	}
	if _, err = f.matches.ConnectCredential(ctx, matches.CredentialRequest{ResumeToken: resumed.ResumeToken}); err == nil {
		t.Fatal("old resume survived")
	}
	if r := f.request(t, http.MethodGet, "/v1/me", "", old.Session.AccessToken); r.Code != 401 {
		t.Fatal("old access survived")
	}
	if r := f.request(t, http.MethodGet, "/v1/games/gomoku/status", "", envelope.Session.AccessToken); r.Code != 200 || !strings.Contains(r.Body.String(), match.Match.ID) {
		t.Fatal("active match not preserved")
	}
	if strings.Contains(f.logs.String(), code.Code) || strings.Contains(f.logs.String(), secret) {
		t.Fatal("credentials logged")
	}
	if _, err = f.auth.Refresh(ctx, old.Session.RefreshToken); err != auth.ErrSessionTransferred {
		t.Fatal("wrong old session result", err)
	}
}
