package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"
	"github.com/google/uuid"

	"me.zqydev/gamebox/server/internal/games/gomoku"
	"me.zqydev/gamebox/server/internal/lan/room"
	"me.zqydev/gamebox/server/internal/protocol"
)

const (
	defaultFirstMessageTimeout = 5 * time.Second
	defaultHeartbeatInterval   = 15 * time.Second
	defaultActivityTimeout     = 45 * time.Second
	webSocketOperationTimeout  = 5 * time.Second
	webSocketSendQueueSize     = 32
	maximumOutstandingPings    = 64
	nonExpiringLANResumeMS     = int64(9_007_199_254_740_991)
)

type HubConfig struct {
	FirstMessageTimeout time.Duration
	HeartbeatInterval   time.Duration
	ActivityTimeout     time.Duration
}

type Hub struct {
	mu                  sync.Mutex
	service             RoomService
	connections         map[*hubConnection]struct{}
	pending             map[int64]room.Event
	publishedRevision   int64
	firstMessageTimeout time.Duration
	heartbeatInterval   time.Duration
	activityTimeout     time.Duration
	closed              bool
	wait                sync.WaitGroup
}

type hubConnection struct {
	hub          *Hub
	transport    *websocket.Conn
	ctx          context.Context
	cancel       context.CancelFunc
	send         chan []byte
	closeOnce    sync.Once
	playerID     string
	roomID       string
	connectionID string
	resumeToken  string
	revision     atomic.Int64
	outboundMu   sync.Mutex
	pingMu       sync.Mutex
	pings        map[string]struct{}
}

type lanConnectPayload struct {
	LaunchTicket string `json:"launchTicket"`
	ResumeToken  string `json:"resumeToken"`
}

func (lanConnectPayload) String() string {
	return "lanConnectPayload{LaunchTicket:<redacted> ResumeToken:<redacted>}"
}
func (payload lanConnectPayload) GoString() string { return payload.String() }

type connectedPayload struct {
	UserID          string `json:"userId"`
	ConnectionID    string `json:"connectionId"`
	ResumeToken     string `json:"resumeToken"`
	ResumeExpiresAt int64  `json:"resumeExpiresAt"`
}

func (connectedPayload) String() string {
	return "connectedPayload{UserID:<id> ConnectionID:<id> ResumeToken:<redacted> ResumeExpiresAt:<time>}"
}
func (payload connectedPayload) GoString() string { return payload.String() }

func (connection *hubConnection) String() string {
	if connection == nil {
		return "hubConnection<nil>"
	}
	return "hubConnection{transport:<socket> playerID:<id> roomID:<id> resumeToken:<redacted>}"
}
func (connection *hubConnection) GoString() string { return connection.String() }

func (hub *Hub) String() string {
	if hub == nil {
		return "lan.Hub<nil>"
	}
	return "lan.Hub{service:<room> connections:<redacted>}"
}
func (hub *Hub) GoString() string { return hub.String() }

type pingPayload struct {
	Nonce string `json:"nonce"`
}

type protocolErrorPayload struct {
	Code    string         `json:"code"`
	Message string         `json:"message"`
	Details map[string]any `json:"details"`
}

type gomokuSnapshotPayload struct {
	Status       string                                     `json:"status"`
	Board        [gomoku.BoardSize * gomoku.BoardSize]uint8 `json:"board"`
	BoardSize    int                                        `json:"boardSize"`
	BlackUserID  *string                                    `json:"blackUserId"`
	WhiteUserID  *string                                    `json:"whiteUserId"`
	NextColor    string                                     `json:"nextColor"`
	WinnerUserID *string                                    `json:"winnerUserId"`
	Result       *string                                    `json:"result"`
}

func NewHub(service RoomService) (*Hub, error) { return NewHubWithConfig(service, HubConfig{}) }

func NewHubWithConfig(service RoomService, config HubConfig) (*Hub, error) {
	if nilInterface(service) || config.FirstMessageTimeout < 0 || config.HeartbeatInterval < 0 || config.ActivityTimeout < 0 {
		return nil, room.ErrInvalidConfiguration
	}
	if config.FirstMessageTimeout == 0 {
		config.FirstMessageTimeout = defaultFirstMessageTimeout
	}
	if config.HeartbeatInterval == 0 {
		config.HeartbeatInterval = defaultHeartbeatInterval
	}
	if config.ActivityTimeout == 0 {
		config.ActivityTimeout = defaultActivityTimeout
	}
	return &Hub{
		service: service, connections: make(map[*hubConnection]struct{}), pending: make(map[int64]room.Event),
		publishedRevision: service.Snapshot().Revision, firstMessageTimeout: config.FirstMessageTimeout,
		heartbeatInterval: config.HeartbeatInterval, activityTimeout: config.ActivityTimeout,
	}, nil
}

func (hub *Hub) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	if hub == nil || hub.service == nil || request == nil || !hub.beginServe() {
		writeAPIError(writer, http.StatusServiceUnavailable, "internal_error")
		return
	}
	defer hub.wait.Done()
	transport, err := websocket.Accept(writer, request, &websocket.AcceptOptions{CompressionMode: websocket.CompressionDisabled})
	if err != nil {
		return
	}
	transport.SetReadLimit(protocol.MaxMessageBytes)
	firstContext, cancelFirst := context.WithTimeout(context.Background(), hub.firstMessageTimeout)
	messageType, data, readErr := transport.Read(firstContext)
	cancelFirst()
	if readErr != nil || messageType != websocket.MessageText {
		writeHandshakeError(transport, "invalid_request")
		_ = transport.Close(websocket.StatusPolicyViolation, "invalid_request")
		return
	}
	envelope, decodeErr := protocol.DecodeLANClient(data)
	if decodeErr != nil || envelope.Type != protocol.TypePlatformConnect {
		writeHandshakeError(transport, "invalid_request")
		_ = transport.Close(websocket.StatusPolicyViolation, "invalid_request")
		return
	}
	var payload lanConnectPayload
	if json.Unmarshal(envelope.Payload, &payload) != nil {
		writeHandshakeError(transport, "invalid_request")
		_ = transport.Close(websocket.StatusPolicyViolation, "invalid_request")
		return
	}
	operationContext, cancelOperation := context.WithTimeout(context.Background(), webSocketOperationTimeout)
	credential, credentialErr := hub.service.ConnectLAN(operationContext, room.ConnectCredential{LaunchTicket: payload.LaunchTicket, ResumeToken: payload.ResumeToken})
	cancelOperation()
	if credentialErr != nil {
		code := safeRoomErrorCode(credentialErr)
		writeHandshakeError(transport, code)
		_ = transport.Close(websocket.StatusPolicyViolation, code)
		return
	}
	connectionUUID, idErr := uuid.NewRandom()
	if idErr != nil {
		writeHandshakeError(transport, "internal_error")
		_ = transport.Close(websocket.StatusInternalError, "internal_error")
		return
	}
	connectionContext, cancelConnection := context.WithCancel(context.Background())
	connection := &hubConnection{
		hub: hub, transport: transport, ctx: connectionContext, cancel: cancelConnection,
		send: make(chan []byte, webSocketSendQueueSize), playerID: credential.PlayerID, roomID: credential.RoomID,
		connectionID: connectionUUID.String(), resumeToken: payload.ResumeToken, pings: make(map[string]struct{}),
	}
	if !hub.registerWithInitial(connection) {
		connection.close()
		return
	}
	go connection.writeLoop()
	go connection.readLoop()
}

func (hub *Hub) registerWithInitial(connection *hubConnection) bool {
	hub.mu.Lock()
	if hub.closed {
		hub.mu.Unlock()
		return false
	}
	snapshot := hub.service.Snapshot()
	if snapshot.RoomID != connection.roomID {
		hub.mu.Unlock()
		return false
	}
	connected, err := boundEnvelope(snapshot.GameID, snapshot.RoomID, snapshot.Revision, protocol.TypePlatformConnected, "", connectedPayload{
		UserID: connection.playerID, ConnectionID: connection.connectionID, ResumeToken: connection.resumeToken, ResumeExpiresAt: nonExpiringLANResumeMS,
	})
	if err != nil {
		hub.mu.Unlock()
		return false
	}
	snapshotMessage, err := snapshotEnvelope(snapshot)
	if err != nil {
		hub.mu.Unlock()
		return false
	}
	connection.send <- connected
	connection.send <- snapshotMessage
	connection.revision.Store(snapshot.Revision)
	previous := make([]*hubConnection, 0, 1)
	for existing := range hub.connections {
		if existing.playerID == connection.playerID {
			previous = append(previous, existing)
		}
	}
	hub.wait.Add(2)
	hub.connections[connection] = struct{}{}
	if snapshot.Revision > hub.publishedRevision {
		hub.publishedRevision = snapshot.Revision
	}
	for revision := range hub.pending {
		if revision <= hub.publishedRevision {
			delete(hub.pending, revision)
		}
	}
	hub.mu.Unlock()
	for _, old := range previous {
		old.close()
	}
	return true
}

func (hub *Hub) publish(event room.Event) {
	if event.RoomID == "" || event.Revision <= 0 {
		return
	}
	var slow []*hubConnection
	hub.mu.Lock()
	if hub.closed || event.Revision <= hub.publishedRevision {
		hub.mu.Unlock()
		return
	}
	if _, exists := hub.pending[event.Revision]; !exists {
		hub.pending[event.Revision] = event
	}
	for {
		next := hub.publishedRevision + 1
		pending, exists := hub.pending[next]
		if !exists {
			break
		}
		data, err := eventEnvelope(pending)
		if err != nil {
			delete(hub.pending, next)
			break
		}
		delete(hub.pending, next)
		hub.publishedRevision = next
		for connection := range hub.connections {
			if !connection.enqueueRevision(data, next) {
				slow = append(slow, connection)
			}
		}
	}
	hub.mu.Unlock()
	for _, connection := range slow {
		connection.close()
	}
}

func (hub *Hub) Close(ctx context.Context) error {
	if hub == nil {
		return nil
	}
	if ctx == nil {
		return room.ErrInvalidRequest
	}
	hub.mu.Lock()
	hub.closed = true
	connections := make([]*hubConnection, 0, len(hub.connections))
	for connection := range hub.connections {
		connections = append(connections, connection)
	}
	hub.mu.Unlock()
	for _, connection := range connections {
		connection.close()
	}
	done := make(chan struct{})
	go func() { hub.wait.Wait(); close(done) }()
	select {
	case <-done:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (hub *Hub) beginServe() bool {
	hub.mu.Lock()
	defer hub.mu.Unlock()
	if hub.closed {
		return false
	}
	hub.wait.Add(1)
	return true
}

func (connection *hubConnection) writeLoop() {
	defer connection.hub.wait.Done()
	ticker := time.NewTicker(connection.hub.heartbeatInterval)
	defer ticker.Stop()
	for {
		select {
		case <-connection.ctx.Done():
			return
		case data := <-connection.send:
			if !connection.write(data) {
				connection.close()
				return
			}
		case <-ticker.C:
			nonce, err := uuid.NewRandom()
			if err != nil {
				connection.close()
				return
			}
			connection.rememberPing(nonce.String())
			message, err := boundEnvelope(gomoku.GameID, connection.roomID, connection.revision.Load(), protocol.TypePlatformPing, "", pingPayload{Nonce: nonce.String()})
			if err != nil || !connection.write(message) {
				connection.close()
				return
			}
		}
	}
}

func (connection *hubConnection) write(data []byte) bool {
	writeContext, cancel := context.WithTimeout(connection.ctx, webSocketOperationTimeout)
	defer cancel()
	return connection.transport.Write(writeContext, websocket.MessageText, data) == nil
}

func (connection *hubConnection) readLoop() {
	defer connection.hub.wait.Done()
	defer connection.close()
	for {
		readContext, cancel := context.WithTimeout(connection.ctx, connection.hub.activityTimeout)
		messageType, data, err := connection.transport.Read(readContext)
		cancel()
		if err != nil {
			return
		}
		if messageType != websocket.MessageText {
			connection.enqueueError("invalid_request", "")
			continue
		}
		envelope, err := protocol.DecodeClient(data)
		if err != nil || envelope.Type == protocol.TypePlatformConnect || envelope.GameID != gomoku.GameID || envelope.MatchID != connection.roomID {
			connection.enqueueError("invalid_request", "")
			continue
		}
		switch envelope.Type {
		case protocol.TypePlatformPong:
			var payload pingPayload
			if json.Unmarshal(envelope.Payload, &payload) != nil || !connection.consumePing(payload.Nonce) {
				connection.enqueueError("invalid_request", "")
			}
		case protocol.TypePlatformSnapshotRequested:
			connection.enqueueSnapshot()
		case protocol.TypeGomokuMoveRequested, protocol.TypeGomokuResignRequested:
			connection.apply(envelope)
		default:
			connection.enqueueError("invalid_request", envelope.ActionID)
		}
	}
}

func (connection *hubConnection) apply(envelope protocol.Envelope) {
	operationContext, cancel := context.WithTimeout(connection.ctx, webSocketOperationTimeout)
	event, _, _, err := connection.hub.service.Apply(operationContext, room.ActionRequest{
		PlayerID: connection.playerID, ActionID: envelope.ActionID, ExpectedRevision: *envelope.ExpectedRevision,
		Type: envelope.Type, Payload: append(json.RawMessage(nil), envelope.Payload...),
	})
	cancel()
	if err == nil {
		connection.hub.publish(event)
		return
	}
	if errors.Is(err, room.ErrStaleRevision) {
		connection.enqueueErrorAndSnapshot("stale_revision", envelope.ActionID, connection.hub.service.Snapshot())
		return
	}
	connection.enqueueError(safeRoomErrorCode(err), envelope.ActionID)
}

func (connection *hubConnection) enqueueSnapshot() {
	snapshot := connection.hub.service.Snapshot()
	data, err := snapshotEnvelope(snapshot)
	if err != nil || !connection.enqueueRevision(data, snapshot.Revision) {
		connection.close()
	}
}

func (connection *hubConnection) enqueueErrorAndSnapshot(code, actionID string, snapshot room.Snapshot) {
	errorMessage, errorErr := errorEnvelope(connection.roomID, snapshot.Revision, code, actionID)
	snapshotMessage, snapshotErr := snapshotEnvelope(snapshot)
	connection.outboundMu.Lock()
	failed := errorErr != nil || snapshotErr != nil || cap(connection.send)-len(connection.send) < 2
	if !failed {
		connection.send <- errorMessage
		connection.send <- snapshotMessage
		connection.revision.Store(snapshot.Revision)
	}
	connection.outboundMu.Unlock()
	if failed {
		connection.close()
	}
}

func (connection *hubConnection) enqueueError(code, actionID string) {
	message, err := errorEnvelope(connection.roomID, connection.revision.Load(), code, actionID)
	connection.outboundMu.Lock()
	queued := err == nil && connection.enqueue(message)
	connection.outboundMu.Unlock()
	if !queued {
		connection.close()
	}
}

func (connection *hubConnection) enqueueRevision(data []byte, revision int64) bool {
	connection.outboundMu.Lock()
	defer connection.outboundMu.Unlock()
	current := connection.revision.Load()
	if revision < current {
		return true
	}
	if !connection.enqueue(data) {
		return false
	}
	if revision > current {
		connection.revision.Store(revision)
	}
	return true
}

func (connection *hubConnection) enqueue(data []byte) bool {
	select {
	case connection.send <- append([]byte(nil), data...):
		return true
	default:
		return false
	}
}

func (connection *hubConnection) rememberPing(nonce string) {
	connection.pingMu.Lock()
	defer connection.pingMu.Unlock()
	if len(connection.pings) >= maximumOutstandingPings {
		clear(connection.pings)
	}
	connection.pings[nonce] = struct{}{}
}

func (connection *hubConnection) consumePing(nonce string) bool {
	connection.pingMu.Lock()
	defer connection.pingMu.Unlock()
	if _, found := connection.pings[nonce]; !found {
		return false
	}
	delete(connection.pings, nonce)
	return true
}

func (connection *hubConnection) close() {
	connection.closeOnce.Do(func() {
		connection.cancel()
		connection.hub.mu.Lock()
		delete(connection.hub.connections, connection)
		connection.hub.mu.Unlock()
		_ = connection.transport.CloseNow()
	})
}

func snapshotEnvelope(snapshot room.Snapshot) ([]byte, error) {
	var payload gomokuSnapshotPayload
	if json.Unmarshal(snapshot.Game.State, &payload) != nil || snapshot.RoomID == "" || snapshot.GameID != gomoku.GameID || len(snapshot.Players) == 0 || len(snapshot.Players) > 2 {
		return nil, room.ErrInternal
	}
	payload.BlackUserID, payload.WhiteUserID = nil, nil
	for _, player := range snapshot.Players {
		playerID := player.PlayerID
		switch player.Color {
		case room.ColorBlack:
			payload.BlackUserID = &playerID
		case room.ColorWhite:
			payload.WhiteUserID = &playerID
		default:
			return nil, room.ErrInternal
		}
	}
	if snapshot.Status == room.StatusFinished && snapshot.Result != nil {
		payload.Status = room.StatusFinished
		payload.Result = stringPointer(snapshot.Result.Reason)
		payload.WinnerUserID = cloneStringPointer(snapshot.Result.WinnerPlayerID)
	}
	return boundEnvelope(snapshot.GameID, snapshot.RoomID, snapshot.Revision, protocol.TypePlatformSnapshot, "", payload)
}

func eventEnvelope(event room.Event) ([]byte, error) {
	if event.RoomID == "" || event.Revision <= 0 || event.Type == "" {
		return nil, room.ErrInvalidRequest
	}
	return boundEnvelope(gomoku.GameID, event.RoomID, event.Revision, event.Type, event.ActionID, json.RawMessage(event.Payload))
}

func errorEnvelope(roomID string, revision int64, code, actionID string) ([]byte, error) {
	return boundEnvelope(gomoku.GameID, roomID, revision, protocol.TypePlatformError, actionID, protocolErrorPayload{Code: code, Message: fixedProtocolErrorMessage(code), Details: map[string]any{}})
}

func boundEnvelope(gameID, roomID string, revision int64, messageType, actionID string, payload any) ([]byte, error) {
	encodedPayload, err := json.Marshal(payload)
	if err != nil {
		return nil, room.ErrInternal
	}
	revisionCopy := revision
	envelope := protocol.Envelope{ProtocolVersion: protocol.Version1, GameID: gameID, MatchID: roomID, Revision: &revisionCopy, Type: messageType, ActionID: actionID, Payload: encodedPayload}
	data, err := json.Marshal(envelope)
	if err != nil || len(data) > protocol.MaxMessageBytes {
		return nil, room.ErrInternal
	}
	return data, nil
}

func writeHandshakeError(connection *websocket.Conn, code string) {
	data, err := json.Marshal(protocol.Envelope{ProtocolVersion: protocol.Version1, Type: protocol.TypePlatformError, Payload: mustJSON(protocolErrorPayload{Code: code, Message: fixedProtocolErrorMessage(code), Details: map[string]any{}})})
	if err != nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	_ = connection.Write(ctx, websocket.MessageText, data)
}

func safeRoomErrorCode(err error) string {
	switch {
	case errors.Is(err, room.ErrTicketInvalid):
		return "ticket_invalid"
	case errors.Is(err, room.ErrResumeInvalid):
		return "resume_invalid"
	case errors.Is(err, room.ErrStaleRevision):
		return "stale_revision"
	case errors.Is(err, room.ErrActionConflict):
		return "action_conflict"
	case errors.Is(err, gomoku.ErrNotYourTurn):
		return "not_your_turn"
	case errors.Is(err, gomoku.ErrCellOccupied):
		return "cell_occupied"
	case errors.Is(err, room.ErrInvalidRequest):
		return "invalid_request"
	default:
		return "internal_error"
	}
}

func fixedProtocolErrorMessage(code string) string {
	switch code {
	case "ticket_invalid":
		return "The launch ticket is invalid"
	case "resume_invalid":
		return "The resume credential is invalid"
	case "stale_revision":
		return "The match state is out of date"
	case "action_conflict":
		return "The action id was already used"
	case "not_your_turn":
		return "It is not your turn"
	case "cell_occupied":
		return "The board cell is occupied"
	case "internal_error":
		return "An internal error occurred"
	default:
		return "The request is invalid"
	}
}

func mustJSON(value any) json.RawMessage { data, _ := json.Marshal(value); return data }

func stringPointer(value string) *string { return &value }

func cloneStringPointer(value *string) *string {
	if value == nil {
		return nil
	}
	clone := *value
	return &clone
}
