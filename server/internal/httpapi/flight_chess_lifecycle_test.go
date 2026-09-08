package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"me.zqydev/gamebox/server/internal/games"
	"me.zqydev/gamebox/server/internal/games/flightchess"
	"me.zqydev/gamebox/server/internal/matches"
	"me.zqydev/gamebox/server/internal/protocol"
)

func TestFlightChessLimitBroadcastsTerminalToBothClients(t *testing.T) {
	fixture := newAPIFixture(t)
	defer fixture.hub.Close(context.Background())
	alice := fixture.register(t, "flight-limit-a", "Alice")
	bob := fixture.register(t, "flight-limit-b", "Bob")
	// Deterministic real rules and SQLite history: 511 rolls of one leave all
	// planes in the hangar. Only entropy and the clock are test-controlled.
	seedService, err := matches.NewService(fixture.db, games.NewRegistry(), fixture.clock, bytes.NewReader(make([]byte, 513)))
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	created, err := seedService.Create(ctx, flightchess.GameID, alice.Session.User.ID, bob.Session.User.ID)
	if err != nil {
		t.Fatal(err)
	}
	for revision := 0; revision < 511; revision++ {
		actor := alice.Session.User.ID
		if revision%2 == 1 {
			actor = bob.Session.User.ID
		}
		_, _, err := seedService.ApplyAction(ctx, matches.ActionRequest{
			MatchID: created.ID, ActorUserID: actor, ActionID: fmt.Sprintf("%08x-1111-4111-8111-%012x", revision+1, revision+1),
			ExpectedRevision: int64(revision), Type: flightchess.RollRequested, Payload: json.RawMessage(`{}`),
		})
		if err != nil {
			t.Fatalf("seed roll %d: %v", revision+1, err)
		}
	}
	server := httptest.NewServer(fixture.handler)
	defer server.Close()
	connect := func(user sessionResponse, countsEnabled bool) *websocket.Conn {
		response := fixture.request(t, http.MethodPost, "/v1/matches/"+created.ID+"/launch-ticket", `{}`, user.Session.AccessToken)
		if response.Code != http.StatusCreated {
			t.Fatalf("ticket: %d %s", response.Code, response.Body.String())
		}
		var ticket struct {
			LaunchTicket string `json:"launchTicket"`
		}
		decodeResponse(t, response, &ticket)
		dialCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
		defer cancel()
		connection, _, err := websocket.Dial(dialCtx, "ws"+strings.TrimPrefix(server.URL, "http")+"/v1/ws", nil)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { connection.CloseNow() })
		capabilities := ""
		if countsEnabled {
			capabilities = `,"capabilities":["flight_chess_capture_counts_v1"]`
		}
		writeWS(t, connection, fmt.Sprintf(`{"protocolVersion":1,"type":"platform.connect","payload":{"launchTicket":%s%s}}`, quote(ticket.LaunchTicket), capabilities))
		connected, snapshot := readWSEnvelope(t, connection), readWSEnvelope(t, connection)
		if connected.Type != protocol.TypePlatformConnected || snapshot.Type != protocol.TypePlatformSnapshot || snapshot.Revision == nil || *snapshot.Revision != 511 || bytes.Contains(snapshot.Payload, []byte(`"captureCounts"`)) != countsEnabled {
			t.Fatalf("connect=(%+v,%+v)", connected, snapshot)
		}
		return connection
	}
	aliceWS, bobWS := connect(alice, true), connect(bob, false)
	// Exercise the public HTTP cancellation boundary while both sockets are live.
	req, err := http.NewRequest(http.MethodDelete, server.URL+"/v1/matches/"+created.ID, nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+alice.Session.AccessToken)
	response, err := server.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusConflict {
		t.Fatalf("cancel after gameplay status=%d", response.StatusCode)
	}
	writeWS(t, bobWS, fmt.Sprintf(`{"protocolVersion":1,"gameId":"flight_chess","matchId":%s,"expectedRevision":511,"type":"flight_chess.move.requested","actionId":"bbbbbbbb-1111-4111-8111-bbbbbbbbbbbb","payload":{"pieceIndex":0}}`, quote(created.ID)))
	rejected := readWSEnvelope(t, bobWS)
	var failure struct {
		Code string `json:"code"`
	}
	if rejected.Type != protocol.TypePlatformError || json.Unmarshal(rejected.Payload, &failure) != nil || failure.Code != "invalid_move" {
		t.Fatalf("wrong phase recovery: %+v", rejected)
	}
	rollMessage := fmt.Sprintf(`{"protocolVersion":1,"gameId":"flight_chess","matchId":%s,"expectedRevision":511,"type":"flight_chess.roll.requested","actionId":"aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa","payload":{}}`, quote(created.ID))
	writeWS(t, bobWS, rollMessage)
	for _, connection := range []*websocket.Conn{aliceWS, bobWS} {
		event := readWSEnvelope(t, connection)
		if event.Type != protocol.TypePlatformMatchAbandoned || event.Revision == nil || *event.Revision != 512 || event.ActionID != "" || string(event.Payload) != `{}` {
			t.Fatalf("terminal event=%+v", event)
		}
		if connection == bobWS {
			// A retry must not enqueue invalid_request or a duplicate terminal
			// event; the following explicit snapshot remains the next message.
			writeWS(t, connection, rollMessage)
		}
		writeWS(t, connection, fmt.Sprintf(`{"protocolVersion":1,"gameId":"flight_chess","matchId":%s,"type":"platform.snapshot.requested","payload":{"currentRevision":512}}`, quote(created.ID)))
		snapshot := readWSEnvelope(t, connection)
		var state struct {
			Status string `json:"status"`
		}
		if snapshot.Type != protocol.TypePlatformSnapshot || snapshot.Revision == nil || *snapshot.Revision != 512 || json.Unmarshal(snapshot.Payload, &state) != nil || state.Status != matches.StatusAbandoned || bytes.Contains(snapshot.Payload, []byte(`"captureCounts"`)) != (connection == aliceWS) {
			t.Fatalf("terminal snapshot=%+v", snapshot)
		}
	}
	for _, table := range []string{"active_game_slots", "launch_tickets", "resume_tokens"} {
		var count int
		if err := fixture.db.QueryRow("SELECT COUNT(*) FROM "+table+" WHERE match_id=?", created.ID).Scan(&count); err != nil || count != 0 {
			t.Fatalf("%s count=%d err=%v", table, count, err)
		}
	}
}
