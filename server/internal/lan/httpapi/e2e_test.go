package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"

	"me.zqydev/gamebox/server/internal/games/gomoku"
	"me.zqydev/gamebox/server/internal/lan/room"
	"me.zqydev/gamebox/server/internal/protocol"
)

type applyBarrierService struct {
	RoomService
	committed   chan struct{}
	release     chan struct{}
	commitOnce  sync.Once
	releaseOnce sync.Once
}

func (service *applyBarrierService) Apply(ctx context.Context, request room.ActionRequest) (room.Event, room.Snapshot, *room.GameResult, error) {
	event, snapshot, result, err := service.RoomService.Apply(ctx, request)
	service.commitOnce.Do(func() { close(service.committed) })
	<-service.release
	return event, snapshot, result, err
}

func (service *applyBarrierService) releaseApply() {
	service.releaseOnce.Do(func() { close(service.release) })
}

func TestWebSocketHandshakeValidatesPairBeforeConsumptionAndOrdersSnapshot(t *testing.T) {
	service := newTestRoom(t, 1_000, 100_000)
	guest, err := service.Join(context.Background(), room.JoinRequest{
		RoomID: testRoomID, Nickname: "Guest", JoinAttemptID: testAttemptID,
		CandidateResumeToken: testGuestResume, RoomKey: testRoomKey,
	})
	if err != nil {
		t.Fatal(err)
	}
	router, err := NewRouter(service)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { closeTestRouter(t, router) })
	server := httptest.NewServer(router)
	t.Cleanup(server.Close)
	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/lan/v1/ws"

	bad := dialWebSocket(t, wsURL)
	writeConnect(t, bad, guest.LaunchTicket.Token, testHostResume)
	badError := readEnvelope(t, bad)
	if badError.Type != protocol.TypePlatformError || errorCode(t, badError) != "resume_invalid" {
		t.Fatalf("bad handshake = %#v", badError)
	}
	_ = bad.CloseNow()

	connection := dialWebSocket(t, wsURL)
	writeConnect(t, connection, guest.LaunchTicket.Token, testGuestResume)
	connected := readEnvelope(t, connection)
	snapshot := readEnvelope(t, connection)
	if connected.Type != protocol.TypePlatformConnected || snapshot.Type != protocol.TypePlatformSnapshot || *connected.Revision != 0 || *snapshot.Revision != 0 {
		t.Fatalf("initial order = %q@%d then %q@%d", connected.Type, *connected.Revision, snapshot.Type, *snapshot.Revision)
	}
	var payload struct {
		UserID          string `json:"userId"`
		ConnectionID    string `json:"connectionId"`
		ResumeToken     string `json:"resumeToken"`
		ResumeExpiresAt int64  `json:"resumeExpiresAt"`
	}
	if json.Unmarshal(connected.Payload, &payload) != nil || payload.UserID != guest.Player.PlayerID || payload.ConnectionID == "" || payload.ResumeToken != testGuestResume || payload.ResumeExpiresAt != nonExpiringLANResumeMS {
		t.Fatalf("connected payload semantics changed")
	}
	_ = connection.CloseNow()

	reused := dialWebSocket(t, wsURL)
	writeConnect(t, reused, guest.LaunchTicket.Token, testGuestResume)
	if envelope := readEnvelope(t, reused); envelope.Type != protocol.TypePlatformError || errorCode(t, envelope) != "ticket_invalid" {
		t.Fatalf("reused ticket response = %#v", envelope)
	}
	_ = reused.CloseNow()
}

func TestWebSocketBroadcastSnapshotResyncAndTerminalReconnectOrdering(t *testing.T) {
	service := newTestRoom(t, 1_000, 100_000)
	guest, err := service.Join(context.Background(), room.JoinRequest{
		RoomID: testRoomID, Nickname: "Guest", JoinAttemptID: testAttemptID,
		CandidateResumeToken: testGuestResume, RoomKey: testRoomKey,
	})
	if err != nil {
		t.Fatal(err)
	}
	hostTicket, err := service.IssueLaunch(context.Background(), testHostID, testHostResume)
	if err != nil {
		t.Fatal(err)
	}
	router, err := NewRouter(service)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { closeTestRouter(t, router) })
	server := httptest.NewServer(router)
	t.Cleanup(server.Close)
	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/lan/v1/ws"

	host := connectAndReadInitial(t, wsURL, hostTicket.Token, testHostResume)
	defer host.connection.CloseNow()
	guestConnection := connectAndReadInitial(t, wsURL, guest.LaunchTicket.Token, testGuestResume)
	defer guestConnection.connection.CloseNow()
	black := playerByColor(t, service.Snapshot(), room.ColorBlack)
	actor := host
	if black.PlayerID == guest.Player.PlayerID {
		actor = guestConnection
	}
	move := protocol.Envelope{
		ProtocolVersion: protocol.Version1, GameID: gomoku.GameID, MatchID: testRoomID,
		ExpectedRevision: int64Pointer(0), Type: gomoku.MoveRequested, ActionID: testMoveID,
		Payload: json.RawMessage(`{"x":1,"y":1}`),
	}
	writeEnvelope(t, actor.connection, move)
	for _, connection := range []*websocket.Conn{host.connection, guestConnection.connection} {
		event := readEnvelope(t, connection)
		if event.Type != gomoku.MoveAccepted || event.Revision == nil || *event.Revision != 1 || event.ActionID != testMoveID {
			t.Fatalf("broadcast event = %#v", event)
		}
	}
	stale := move
	stale.ActionID = "77777777-7777-4777-8777-777777777777"
	writeEnvelope(t, actor.connection, stale)
	staleError := readEnvelope(t, actor.connection)
	staleSnapshot := readEnvelope(t, actor.connection)
	if staleError.Type != protocol.TypePlatformError || errorCode(t, staleError) != "stale_revision" || staleSnapshot.Type != protocol.TypePlatformSnapshot || staleSnapshot.Revision == nil || *staleSnapshot.Revision != 1 {
		t.Fatalf("stale resync = %#v then %#v", staleError, staleSnapshot)
	}

	snapshotRequest := protocol.Envelope{
		ProtocolVersion: protocol.Version1, GameID: gomoku.GameID, MatchID: testRoomID,
		Type: protocol.TypePlatformSnapshotRequested, Payload: json.RawMessage(`{"currentRevision":0}`),
	}
	writeEnvelope(t, guestConnection.connection, snapshotRequest)
	resynced := readEnvelope(t, guestConnection.connection)
	if resynced.Type != protocol.TypePlatformSnapshot || resynced.Revision == nil || *resynced.Revision != 1 {
		t.Fatalf("resync = %#v", resynced)
	}

	resignerID := testHostID
	resignerConnection := host.connection
	if black.PlayerID == testHostID {
		resignerID = guest.Player.PlayerID
		resignerConnection = guestConnection.connection
	}
	resign := protocol.Envelope{
		ProtocolVersion: protocol.Version1, GameID: gomoku.GameID, MatchID: testRoomID,
		ExpectedRevision: int64Pointer(1), Type: protocol.TypeGomokuResignRequested, ActionID: testResignID, Payload: json.RawMessage(`{}`),
	}
	_ = resignerID
	writeEnvelope(t, resignerConnection, resign)
	for _, connection := range []*websocket.Conn{host.connection, guestConnection.connection} {
		event := readEnvelope(t, connection)
		if event.Type != protocol.TypeGomokuResigned || event.Revision == nil || *event.Revision != 2 {
			t.Fatalf("terminal event = %#v", event)
		}
	}

	reconnected := dialWebSocket(t, wsURL)
	writeConnect(t, reconnected, "", testGuestResume)
	if first, second := readEnvelope(t, reconnected), readEnvelope(t, reconnected); first.Type != protocol.TypePlatformConnected || second.Type != protocol.TypePlatformSnapshot || *second.Revision != 2 {
		t.Fatalf(
			"terminal reconnect order = first(type=%q revision=%v payloadBytes=%d payloadPresent=%v) second(type=%q revision=%v payloadBytes=%d payloadPresent=%v)",
			first.Type, first.Revision, len(first.Payload), len(first.Payload) != 0,
			second.Type, second.Revision, len(second.Payload), len(second.Payload) != 0,
		)
	}
	readContext, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	if _, _, err := reconnected.Read(readContext); err == nil {
		t.Fatal("terminal reconnect sent an unapproved third frame")
	}
	_ = reconnected.CloseNow()
}

func TestWebSocketRegistrationSnapshotCannotSkipPendingBroadcast(t *testing.T) {
	service := newTestRoom(t, 1_000, 100_000)
	guest, err := service.Join(context.Background(), room.JoinRequest{
		RoomID: testRoomID, Nickname: "Guest", JoinAttemptID: testAttemptID,
		CandidateResumeToken: testGuestResume, RoomKey: testRoomKey,
	})
	if err != nil {
		t.Fatal(err)
	}
	hostTicket, err := service.IssueLaunch(context.Background(), testHostID, testHostResume)
	if err != nil {
		t.Fatal(err)
	}
	barrier := &applyBarrierService{RoomService: service, committed: make(chan struct{}), release: make(chan struct{})}
	t.Cleanup(barrier.releaseApply)
	router, err := NewRouter(barrier)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { closeTestRouter(t, router) })
	server := httptest.NewServer(router)
	t.Cleanup(server.Close)
	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/lan/v1/ws"

	host := connectAndReadInitial(t, wsURL, hostTicket.Token, testHostResume)
	defer host.connection.CloseNow()
	guestConnection := connectAndReadInitial(t, wsURL, guest.LaunchTicket.Token, testGuestResume)
	defer guestConnection.connection.CloseNow()
	actor, observer := host, guestConnection
	actorResume := testHostResume
	if playerByColor(t, service.Snapshot(), room.ColorBlack).PlayerID == guest.Player.PlayerID {
		actor, observer = guestConnection, host
		actorResume = testGuestResume
	}
	writeEnvelope(t, actor.connection, protocol.Envelope{
		ProtocolVersion: protocol.Version1, GameID: gomoku.GameID, MatchID: testRoomID,
		ExpectedRevision: int64Pointer(0), Type: protocol.TypeGomokuMoveRequested,
		ActionID: testMoveID, Payload: json.RawMessage(`{"x":1,"y":1}`),
	})
	select {
	case <-barrier.committed:
	case <-time.After(2 * time.Second):
		t.Fatal("action did not commit before barrier")
	}

	newActor := connectAndReadInitial(t, wsURL, "", actorResume)
	defer newActor.connection.CloseNow()
	if newActor.snapshot.Revision == nil || *newActor.snapshot.Revision != 1 {
		t.Fatal("new connection did not receive committed revision snapshot")
	}
	barrier.releaseApply()

	oldEvent, err := readEnvelopeWithin(observer.connection, 500*time.Millisecond)
	if err != nil || oldEvent.Type != protocol.TypeGomokuMoveAccepted || oldEvent.Revision == nil || *oldEvent.Revision != 1 {
		t.Fatalf("old connection missed committed revision 1 event: type=%q revision=%v err=%v", oldEvent.Type, oldEvent.Revision, err)
	}
	if duplicate, err := readEnvelopeWithin(newActor.connection, 150*time.Millisecond); err == nil {
		t.Fatalf("new connection received event already covered by snapshot: type=%q revision=%v", duplicate.Type, duplicate.Revision)
	}
}

func TestWebSocketHeartbeatUsesBoundedProtocolPingAndAcceptsPong(t *testing.T) {
	service := newTestRoom(t, 1_000, 100_000)
	hostTicket, err := service.IssueLaunch(context.Background(), testHostID, testHostResume)
	if err != nil {
		t.Fatal(err)
	}
	hub, err := NewHubWithConfig(service, HubConfig{HeartbeatInterval: 10 * time.Millisecond, ActivityTimeout: time.Second})
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(hub)
	t.Cleanup(func() {
		server.Close()
		_ = hub.Close(context.Background())
	})
	connection := connectAndReadInitial(t, "ws"+strings.TrimPrefix(server.URL, "http"), hostTicket.Token, testHostResume)
	defer connection.connection.CloseNow()
	ping := readEnvelope(t, connection.connection)
	if ping.Type != protocol.TypePlatformPing || ping.Revision == nil || *ping.Revision != 0 {
		t.Fatalf("heartbeat = %#v", ping)
	}
	var payload struct {
		Nonce string `json:"nonce"`
	}
	if json.Unmarshal(ping.Payload, &payload) != nil || payload.Nonce == "" {
		t.Fatal("heartbeat nonce missing")
	}
	writeEnvelope(t, connection.connection, protocol.Envelope{
		ProtocolVersion: protocol.Version1, GameID: gomoku.GameID, MatchID: testRoomID,
		Type: protocol.TypePlatformPong, Payload: mustJSONForTest(t, map[string]string{"nonce": payload.Nonce}),
	})
}

func TestWebSocketCredentialHoldersRedactFormattingAndQueueIsBounded(t *testing.T) {
	connection := &hubConnection{send: make(chan []byte, 1), resumeToken: testGuestResume}
	if !connection.enqueue([]byte("first")) || connection.enqueue([]byte("second")) {
		t.Fatal("send queue did not reject a slow client without blocking")
	}
	values := []any{
		lanConnectPayload{LaunchTicket: "private-launch", ResumeToken: testGuestResume},
		connectedPayload{ResumeToken: testGuestResume}, connection,
		joinBody{Nickname: "private-nickname", CandidateResumeToken: testGuestResume, RoomKey: testRoomKey},
		resumeTicketBody{ResumeToken: testGuestResume}, resumeBody{ResumeToken: testGuestResume},
		resultAckBody{ResumeToken: testGuestResume}, launchResponse{LaunchTicket: "private-launch"},
	}
	for _, value := range values {
		formatted := fmt.Sprintf("%+v %#v", value, value)
		for _, secret := range []string{"private-launch", "private-nickname", testRoomKey, testGuestResume} {
			if strings.Contains(formatted, secret) {
				t.Fatalf("formatted %T exposed credential", value)
			}
		}
	}
}

type connectedClient struct {
	connection *websocket.Conn
	connected  protocol.Envelope
	snapshot   protocol.Envelope
}

func connectAndReadInitial(t *testing.T, wsURL, launchTicket, resumeToken string) connectedClient {
	t.Helper()
	connection := dialWebSocket(t, wsURL)
	writeConnect(t, connection, launchTicket, resumeToken)
	return connectedClient{connection: connection, connected: readEnvelope(t, connection), snapshot: readEnvelope(t, connection)}
}

func dialWebSocket(t *testing.T, url string) *websocket.Conn {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	connection, _, err := websocket.Dial(ctx, url, nil)
	if err != nil {
		t.Fatal(err)
	}
	connection.SetReadLimit(protocol.MaxMessageBytes)
	return connection
}

func writeConnect(t *testing.T, connection *websocket.Conn, launchTicket, resumeToken string) {
	t.Helper()
	payload := map[string]string{"resumeToken": resumeToken}
	if launchTicket != "" {
		payload["launchTicket"] = launchTicket
	}
	writeEnvelope(t, connection, protocol.Envelope{ProtocolVersion: protocol.Version1, Type: protocol.TypePlatformConnect, Payload: mustJSONForTest(t, payload)})
}

func writeEnvelope(t *testing.T, connection *websocket.Conn, envelope protocol.Envelope) {
	t.Helper()
	data, err := json.Marshal(envelope)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := connection.Write(ctx, websocket.MessageText, data); err != nil {
		t.Fatal(err)
	}
}

func readEnvelope(t *testing.T, connection *websocket.Conn) protocol.Envelope {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	messageType, data, err := connection.Read(ctx)
	if err != nil || messageType != websocket.MessageText {
		t.Fatalf("read WebSocket frame = (%d, %v)", messageType, err)
	}
	envelope, err := protocol.Decode(data)
	if err != nil {
		t.Fatalf("decode frame: %v", err)
	}
	return envelope
}

func readEnvelopeWithin(connection *websocket.Conn, timeout time.Duration) (protocol.Envelope, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	messageType, data, err := connection.Read(ctx)
	if err != nil {
		return protocol.Envelope{}, err
	}
	if messageType != websocket.MessageText {
		return protocol.Envelope{}, errors.New("non-text WebSocket message")
	}
	return protocol.Decode(data)
}

func errorCode(t *testing.T, envelope protocol.Envelope) string {
	t.Helper()
	var payload struct {
		Code string `json:"code"`
	}
	if json.Unmarshal(envelope.Payload, &payload) != nil {
		t.Fatal("decode error payload")
	}
	return payload.Code
}

func mustJSONForTest(t *testing.T, value any) json.RawMessage {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func int64Pointer(value int64) *int64 { return &value }
