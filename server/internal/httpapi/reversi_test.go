package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"github.com/coder/websocket"
	"me.zqydev/gamebox/server/internal/games/reversi"
	"me.zqydev/gamebox/server/internal/protocol"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestReversiTwoClientsFullGameResumeAndHistory(t *testing.T) {
	f := newAPIFixture(t)
	a := f.register(t, "reversi-a", "Alice")
	b := f.register(t, "reversi-b", "Bob")
	response := f.request(t, http.MethodPost, "/v1/games/reversi/matches", `{"opponentId":`+quote(b.Session.User.ID)+`}`, a.Session.AccessToken)
	if response.Code != 201 {
		t.Fatal(response.Code, response.Body.String())
	}
	var created struct {
		Match struct {
			ID string `json:"id"`
		} `json:"match"`
	}
	decodeResponse(t, response, &created)
	server := httptest.NewServer(f.handler)
	defer server.Close()
	url := "ws" + strings.TrimPrefix(server.URL, "http") + "/v1/ws"
	connect := func(key, token string, rev int64) (*websocket.Conn, string, protocol.Envelope) {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		ws, _, err := websocket.Dial(ctx, url, nil)
		if err != nil {
			t.Fatal(err)
		}
		writeWS(t, ws, fmt.Sprintf(`{"protocolVersion":1,"type":"platform.connect","payload":{"%s":%s}}`, key, quote(token)))
		connected := readWSEnvelope(t, ws)
		snap := readWSEnvelope(t, ws)
		if connected.Type != protocol.TypePlatformConnected || snap.Type != protocol.TypePlatformSnapshot || *snap.Revision != rev {
			t.Fatal("handshake", connected, snap)
		}
		var p struct {
			ResumeToken string `json:"resumeToken"`
		}
		json.Unmarshal(connected.Payload, &p)
		return ws, p.ResumeToken, snap
	}
	issue := func(user sessionResponse) string {
		response := f.request(t, http.MethodPost, "/v1/matches/"+created.Match.ID+"/launch-ticket", `{}`, user.Session.AccessToken)
		var ticket struct {
			LaunchTicket string `json:"launchTicket"`
		}
		decodeResponse(t, response, &ticket)
		return ticket.LaunchTicket
	}
	aw, ar, snap := connect("launchTicket", issue(a), 0)
	defer func() { aw.CloseNow() }()
	bw, _, other := connect("launchTicket", issue(b), 0)
	defer bw.CloseNow()
	if !bytes.Equal(snap.Payload, other.Payload) {
		t.Fatal("opening differs")
	}
	for rev := int64(0); rev < 60; rev++ {
		var state reversi.State
		json.Unmarshal(snap.Payload, &state)
		if state.Status != "active" {
			break
		}
		mover := aw
		if (state.NextColor == "black" && *state.BlackUserID == b.Session.User.ID) || (state.NextColor == "white" && *state.WhiteUserID == b.Session.User.ID) {
			mover = bw
		}
		p := state.LegalMoves[0]
		message := fmt.Sprintf(`{"protocolVersion":1,"gameId":"reversi","matchId":%s,"expectedRevision":%d,"actionId":"aaaaaaaa-1111-4111-8111-%012d","type":"reversi.move.requested","payload":{"x":%d,"y":%d}}`, quote(created.Match.ID), rev, rev+1, p.X, p.Y)
		writeWS(t, mover, message)
		for _, ws := range []*websocket.Conn{aw, bw} {
			event := readWSEnvelope(t, ws)
			if event.Type != reversi.MoveAccepted || *event.Revision != rev+1 {
				t.Fatal("move", event)
			}
		}
		request := fmt.Sprintf(`{"protocolVersion":1,"gameId":"reversi","matchId":%s,"type":"platform.snapshot.requested","payload":{"currentRevision":%d}}`, quote(created.Match.ID), rev)
		writeWS(t, aw, request)
		snap = readWSEnvelope(t, aw)
		writeWS(t, bw, request)
		other = readWSEnvelope(t, bw)
		if snap.Type != protocol.TypePlatformSnapshot || !bytes.Equal(snap.Payload, other.Payload) {
			t.Fatal("snapshots differ")
		}
		if rev == 9 {
			aw.CloseNow()
			aw, ar, snap = connect("resumeToken", ar, rev+1)
		}
	}
	var final reversi.State
	json.Unmarshal(snap.Payload, &final)
	if final.Status != "finished" || len(final.LegalMoves) != 0 || final.Result == nil {
		t.Fatal("not finished", final)
	}
	for _, user := range []sessionResponse{a, b} {
		status := f.request(t, http.MethodGet, "/v1/games/reversi/status", "", user.Session.AccessToken)
		if status.Code != 200 || !strings.Contains(status.Body.String(), `"idle"`) {
			t.Fatal("active slot", status.Body.String())
		}
		history := f.request(t, http.MethodGet, "/v1/games/reversi/history", "", user.Session.AccessToken)
		if history.Code != 200 || !strings.Contains(history.Body.String(), created.Match.ID) {
			t.Fatal("history", history.Body.String())
		}
	}
}
