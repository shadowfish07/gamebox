package matches

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

	"me.zqydev/gamebox/server/internal/clock"
	"me.zqydev/gamebox/server/internal/games/gomoku"
	"me.zqydev/gamebox/server/internal/protocol"
)

const (
	webSocketFirstMessageTimeout = 5 * time.Second
	webSocketHeartbeatInterval   = 15 * time.Second
	webSocketOperationTimeout    = 5 * time.Second
	webSocketSendQueueSize       = 32
	webSocketPendingLimit        = 32
)

type Hub struct {
	mu       sync.Mutex
	matches  map[string]*hubMatch
	service  *Service
	presence *Presence
	clock    clock.Clock
}

type hubMatch struct {
	connections       map[*hubConnection]struct{}
	publishedRevision int64
	pendingEvents     map[int64][]byte
	gameID            string
}

type queuedMessage struct {
	data     []byte
	revision int64
}

type hubConnection struct {
	hub        *Hub
	transport  *websocket.Conn
	ctx        context.Context
	cancel     context.CancelFunc
	done       chan struct{}
	send       chan []byte
	closeOnce  sync.Once
	matchID    string
	gameID     string
	userID     string
	id         string
	ready      bool
	pending    []queuedMessage
	revision   atomic.Int64
	pingMu     sync.Mutex
	latestPing string
}

type connectPayload struct {
	LaunchTicket string `json:"launchTicket"`
	ResumeToken  string `json:"resumeToken"`
}

type connectedPayload struct {
	UserID          string `json:"userId"`
	ConnectionID    string `json:"connectionId"`
	ResumeToken     string `json:"resumeToken"`
	ResumeExpiresAt int64  `json:"resumeExpiresAt"`
}

type pingPayload struct {
	Nonce string `json:"nonce"`
}

type pongPayload struct {
	Nonce string `json:"nonce"`
}

type snapshotRequestPayload struct {
	CurrentRevision int64 `json:"currentRevision"`
}

type errorPayload struct {
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

func NewHub(service *Service, presence *Presence, serviceClock clock.Clock) (*Hub, error) {
	if service == nil || presence == nil || !service.configured() || nilDependency(service.ticketRandom) || len([]byte(service.tokenPepper)) < minimumTokenPepperBytes || !presence.configured() || nilDependency(serviceClock) {
		return nil, ErrInvalidConfiguration
	}
	return &Hub{matches: make(map[string]*hubMatch), service: service, presence: presence, clock: serviceClock}, nil
}

// ServeHTTP owns a single upgraded connection for its complete lifetime.
// Native apps omit Origin; coder/websocket's default same-host policy rejects
// browser cross-origin handshakes without weakening local development safety.
func (hub *Hub) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	if hub == nil || hub.service == nil || hub.presence == nil || request == nil {
		http.Error(writer, http.StatusText(http.StatusServiceUnavailable), http.StatusServiceUnavailable)
		return
	}
	transport, err := websocket.Accept(writer, request, &websocket.AcceptOptions{
		CompressionMode: websocket.CompressionDisabled,
	})
	if err != nil {
		return
	}
	transport.SetReadLimit(protocol.MaxMessageBytes)
	firstContext, cancelFirst := context.WithTimeout(context.Background(), webSocketFirstMessageTimeout)
	messageType, data, readErr := transport.Read(firstContext)
	cancelFirst()
	if readErr != nil || messageType != websocket.MessageText {
		writeHandshakeError(transport, "invalid_connect")
		_ = transport.Close(websocket.StatusPolicyViolation, "invalid connect")
		return
	}
	envelope, decodeErr := protocol.DecodeClient(data)
	if decodeErr != nil || envelope.Type != protocol.TypePlatformConnect {
		writeHandshakeError(transport, "invalid_connect")
		_ = transport.Close(websocket.StatusPolicyViolation, "invalid connect")
		return
	}
	var payload connectPayload
	if json.Unmarshal(envelope.Payload, &payload) != nil {
		writeHandshakeError(transport, "invalid_connect")
		_ = transport.Close(websocket.StatusPolicyViolation, "invalid connect")
		return
	}
	operationContext, cancelOperation := context.WithTimeout(context.Background(), webSocketOperationTimeout)
	credential, credentialErr := hub.service.ConnectCredential(operationContext, CredentialRequest{
		LaunchTicket: payload.LaunchTicket, ResumeToken: payload.ResumeToken,
	})
	cancelOperation()
	if credentialErr != nil {
		writeHandshakeError(transport, "credential_invalid")
		_ = transport.Close(websocket.StatusPolicyViolation, "credential invalid")
		return
	}
	connectionID, idErr := uuid.NewRandom()
	if idErr != nil {
		writeHandshakeError(transport, "internal_error")
		_ = transport.Close(websocket.StatusInternalError, "internal error")
		return
	}
	connectionContext, cancelConnection := context.WithCancel(context.Background())
	connection := &hubConnection{
		hub: hub, transport: transport, ctx: connectionContext, cancel: cancelConnection,
		done: make(chan struct{}), send: make(chan []byte, webSocketSendQueueSize),
		matchID: credential.MatchID, gameID: credential.GameID, userID: credential.UserID, id: connectionID.String(),
		pending: make([]queuedMessage, 0, 4),
	}
	operationContext, cancelOperation = context.WithTimeout(context.Background(), webSocketOperationTimeout)
	connectErr := hub.presence.Connect(operationContext, connection.matchID, connection.userID, connection.id)
	cancelOperation()
	if connectErr != nil {
		writeHandshakeError(transport, "internal_error")
		_ = transport.Close(websocket.StatusInternalError, "internal error")
		return
	}
	hub.register(connection)
	go connection.writeLoop()
	defer func() {
		connection.close()
		select {
		case <-connection.done:
		case <-time.After(time.Second):
		}
	}()

	operationContext, cancelOperation = context.WithTimeout(connection.ctx, webSocketOperationTimeout)
	snapshot, snapshotErr := hub.service.Snapshot(operationContext, connection.matchID)
	cancelOperation()
	if snapshotErr != nil {
		connection.enqueueError("internal_error", "", connection.revision.Load())
		return
	}
	connected, marshalErr := boundEnvelope(connection.gameID, connection.matchID, snapshot.Match.Revision, protocol.TypePlatformConnected, "", connectedPayload{
		UserID: credential.UserID, ConnectionID: connection.id, ResumeToken: credential.ResumeToken,
		ResumeExpiresAt: credential.ResumeExpiresAt.UnixMilli(),
	})
	if marshalErr != nil || !connection.enqueue(connected) {
		return
	}
	snapshotMessage, marshalErr := snapshotEnvelope(snapshot)
	if marshalErr != nil || !connection.enqueue(snapshotMessage) {
		return
	}
	connection.revision.Store(snapshot.Match.Revision)
	for attempts := 0; attempts <= maximumMatchEvents; attempts++ {
		ready, stale := hub.markReady(connection, snapshot.Match.Revision, snapshotMessage)
		if ready {
			connection.readLoop()
			return
		}
		if !stale {
			return
		}
		operationContext, cancelOperation = context.WithTimeout(connection.ctx, webSocketOperationTimeout)
		snapshot, snapshotErr = hub.service.Snapshot(operationContext, connection.matchID)
		cancelOperation()
		if snapshotErr != nil {
			return
		}
		snapshotMessage, marshalErr = snapshotEnvelope(snapshot)
		if marshalErr != nil || !connection.enqueue(snapshotMessage) {
			return
		}
		connection.revision.Store(snapshot.Match.Revision)
	}
}

func writeHandshakeError(connection *websocket.Conn, code string) {
	message, err := json.Marshal(protocol.Envelope{
		ProtocolVersion: protocol.Version1, Type: protocol.TypePlatformError,
		Payload: mustJSON(errorPayload{Code: code, Message: fixedErrorMessage(code), Details: map[string]any{}}),
	})
	if err != nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	_ = connection.Write(ctx, websocket.MessageText, message)
}

func (hub *Hub) register(connection *hubConnection) {
	hub.mu.Lock()
	match := hub.matches[connection.matchID]
	if match == nil {
		match = &hubMatch{connections: make(map[*hubConnection]struct{}), pendingEvents: make(map[int64][]byte), gameID: connection.gameID}
		hub.matches[connection.matchID] = match
	}
	previous := make([]*hubConnection, 0, 1)
	for existing := range match.connections {
		if existing.userID == connection.userID {
			previous = append(previous, existing)
		}
	}
	match.connections[connection] = struct{}{}
	hub.mu.Unlock()
	// A successful reconnect supersedes the user's older transport while
	// Presence keeps the player online across their brief overlap.
	for _, existing := range previous {
		existing.close()
	}
}

func (hub *Hub) markReady(connection *hubConnection, snapshotRevision int64, snapshotMessage []byte) (ready bool, stale bool) {
	hub.mu.Lock()
	match := hub.matches[connection.matchID]
	if match == nil {
		hub.mu.Unlock()
		return false, false
	}
	if snapshotRevision < match.publishedRevision {
		hub.mu.Unlock()
		return false, true
	}
	slow := make([]*hubConnection, 0)
	if snapshotRevision > match.publishedRevision {
		// A snapshot can observe committed events whose publishing goroutine has
		// not run yet. Existing ready peers are explicitly resnapshotted before
		// the shared publication watermark advances, so no one is left behind.
		for existing := range match.connections {
			if existing == connection || !existing.ready || existing.revision.Load() >= snapshotRevision {
				continue
			}
			if !existing.enqueue(snapshotMessage) {
				existing.ready = false
				slow = append(slow, existing)
				continue
			}
			existing.revision.Store(snapshotRevision)
		}
		match.publishedRevision = snapshotRevision
	}
	for revision := range match.pendingEvents {
		if revision <= snapshotRevision {
			delete(match.pendingEvents, revision)
		}
	}
	slow = append(slow, hub.flushPublishedLocked(match)...)
	queued := true
	for _, pending := range connection.pending {
		if pending.revision <= snapshotRevision {
			continue
		}
		if !connection.enqueue(pending.data) {
			queued = false
			break
		}
		connection.revision.Store(pending.revision)
	}
	connection.pending = nil
	connection.ready = queued
	hub.mu.Unlock()
	for _, slowConnection := range slow {
		slowConnection.close()
	}
	if !queued {
		connection.close()
	}
	return queued, false
}

// Publish performs only ordered best-effort fan-out. The event is already
// committed and the Hub never invokes game rules or persistence from here.
func (hub *Hub) Publish(matchID string, event Event) {
	if hub == nil || matchID == "" || event.MatchID != matchID || event.Revision <= 0 || event.Revision > maximumMatchEvents {
		return
	}
	var slow []*hubConnection
	hub.mu.Lock()
	match := hub.matches[matchID]
	if match == nil {
		hub.mu.Unlock()
		return
	}
	data, err := eventEnvelope(match.gameID, event)
	if err != nil {
		hub.mu.Unlock()
		return
	}
	if event.Revision <= match.publishedRevision {
		hub.mu.Unlock()
		return
	}
	if _, duplicate := match.pendingEvents[event.Revision]; !duplicate {
		match.pendingEvents[event.Revision] = append([]byte(nil), data...)
	}
	slow = append(slow, hub.flushPublishedLocked(match)...)
	hub.mu.Unlock()
	for _, connection := range slow {
		connection.close()
	}
}

func (hub *Hub) flushPublishedLocked(match *hubMatch) []*hubConnection {
	slow := make([]*hubConnection, 0)
	for {
		nextRevision := match.publishedRevision + 1
		data, exists := match.pendingEvents[nextRevision]
		if !exists {
			return slow
		}
		delete(match.pendingEvents, nextRevision)
		match.publishedRevision = nextRevision
		for connection := range match.connections {
			if connection.ready {
				if !connection.enqueue(data) {
					slow = append(slow, connection)
					continue
				}
				connection.revision.Store(nextRevision)
				continue
			}
			if len(connection.pending) >= webSocketPendingLimit {
				slow = append(slow, connection)
				continue
			}
			connection.pending = append(connection.pending, queuedMessage{data: append([]byte(nil), data...), revision: nextRevision})
		}
	}
}

func (connection *hubConnection) enqueue(data []byte) bool {
	select {
	case connection.send <- append([]byte(nil), data...):
		return true
	default:
		return false
	}
}

func (connection *hubConnection) writeLoop() {
	defer close(connection.done)
	ticker := time.NewTicker(webSocketHeartbeatInterval)
	defer ticker.Stop()
	for {
		select {
		case <-connection.ctx.Done():
			return
		case data := <-connection.send:
			writeContext, cancel := context.WithTimeout(connection.ctx, webSocketOperationTimeout)
			err := connection.transport.Write(writeContext, websocket.MessageText, data)
			cancel()
			if err != nil {
				connection.close()
				return
			}
		case <-ticker.C:
			nonce, err := uuid.NewRandom()
			if err != nil {
				connection.close()
				return
			}
			connection.pingMu.Lock()
			connection.latestPing = nonce.String()
			connection.pingMu.Unlock()
			message, err := boundEnvelope(connection.gameID, connection.matchID, connection.revision.Load(), protocol.TypePlatformPing, "", pingPayload{Nonce: nonce.String()})
			if err != nil {
				connection.close()
				return
			}
			writeContext, cancel := context.WithTimeout(connection.ctx, webSocketOperationTimeout)
			err = connection.transport.Write(writeContext, websocket.MessageText, message)
			cancel()
			if err != nil {
				connection.close()
				return
			}
		}
	}
}

func (connection *hubConnection) readLoop() {
	lastActivity := time.Now()
	for {
		remaining := presenceConnectionTimeout - time.Since(lastActivity)
		if remaining <= 0 {
			return
		}
		readContext, cancel := context.WithTimeout(connection.ctx, remaining)
		messageType, data, err := connection.transport.Read(readContext)
		cancel()
		if err != nil {
			return
		}
		if messageType != websocket.MessageText {
			connection.enqueueError("invalid_request", "", connection.revision.Load())
			continue
		}
		envelope, decodeErr := protocol.DecodeClient(data)
		if decodeErr != nil || envelope.Type == protocol.TypePlatformConnect || envelope.MatchID != connection.matchID || envelope.GameID != connection.gameID {
			connection.enqueueError("invalid_request", "", connection.revision.Load())
			continue
		}
		if envelope.Type == protocol.TypePlatformPong {
			var payload pongPayload
			if json.Unmarshal(envelope.Payload, &payload) != nil || !connection.validPong(payload.Nonce) {
				connection.enqueueError("invalid_request", "", connection.revision.Load())
				continue
			}
			if !connection.hub.presence.Touch(connection.matchID, connection.userID, connection.id) {
				return
			}
			lastActivity = time.Now()
			continue
		}
		if !connection.hub.presence.Touch(connection.matchID, connection.userID, connection.id) {
			return
		}
		lastActivity = time.Now()
		switch envelope.Type {
		case protocol.TypePlatformSnapshotRequested:
			var payload snapshotRequestPayload
			if json.Unmarshal(envelope.Payload, &payload) != nil {
				connection.enqueueError("invalid_request", "", connection.revision.Load())
				continue
			}
			connection.sendLatestSnapshot()
		case protocol.TypeGomokuMoveRequested, protocol.TypeGomokuResignRequested:
			connection.applyAction(envelope)
		default:
			connection.enqueueError("invalid_request", envelope.ActionID, connection.revision.Load())
		}
	}
}

func (connection *hubConnection) validPong(nonce string) bool {
	connection.pingMu.Lock()
	defer connection.pingMu.Unlock()
	if nonce == "" || nonce != connection.latestPing {
		return false
	}
	connection.latestPing = ""
	return true
}

func (connection *hubConnection) applyAction(envelope protocol.Envelope) {
	operationContext, cancel := context.WithTimeout(connection.ctx, webSocketOperationTimeout)
	event, _, err := connection.hub.service.ApplyAction(operationContext, ActionRequest{
		MatchID: connection.matchID, ActorUserID: connection.userID, ActionID: envelope.ActionID,
		ExpectedRevision: *envelope.ExpectedRevision, Type: envelope.Type, Payload: append(json.RawMessage(nil), envelope.Payload...),
	})
	cancel()
	if err == nil {
		connection.hub.Publish(connection.matchID, event)
		return
	}
	if errors.Is(err, ErrStaleRevision) {
		operationContext, cancel = context.WithTimeout(connection.ctx, webSocketOperationTimeout)
		snapshot, snapshotErr := connection.hub.service.Snapshot(operationContext, connection.matchID)
		cancel()
		if snapshotErr != nil {
			connection.enqueueError("internal_error", envelope.ActionID, connection.revision.Load())
			return
		}
		connection.enqueueError("stale_revision", envelope.ActionID, snapshot.Match.Revision)
		connection.enqueueSnapshot(snapshot)
		return
	}
	connection.enqueueError(safeActionErrorCode(err), envelope.ActionID, connection.revision.Load())
}

func (connection *hubConnection) sendLatestSnapshot() {
	operationContext, cancel := context.WithTimeout(connection.ctx, webSocketOperationTimeout)
	snapshot, err := connection.hub.service.Snapshot(operationContext, connection.matchID)
	cancel()
	if err != nil {
		connection.enqueueError("internal_error", "", connection.revision.Load())
		return
	}
	connection.enqueueSnapshot(snapshot)
}

func (connection *hubConnection) enqueueSnapshot(snapshot Snapshot) {
	message, err := snapshotEnvelope(snapshot)
	if err != nil || !connection.enqueue(message) {
		connection.close()
		return
	}
	connection.revision.Store(snapshot.Match.Revision)
}

func (connection *hubConnection) enqueueError(code, actionID string, revision int64) {
	message, err := boundEnvelope(connection.gameID, connection.matchID, revision, protocol.TypePlatformError, actionID,
		errorPayload{Code: code, Message: fixedErrorMessage(code), Details: map[string]any{}})
	if err != nil || !connection.enqueue(message) {
		connection.close()
	}
}

func (connection *hubConnection) close() {
	connection.closeOnce.Do(func() {
		connection.cancel()
		connection.hub.mu.Lock()
		if match := connection.hub.matches[connection.matchID]; match != nil {
			delete(match.connections, connection)
			if len(match.connections) == 0 {
				delete(connection.hub.matches, connection.matchID)
			}
		}
		connection.hub.mu.Unlock()
		_ = connection.transport.CloseNow()
		ctx, cancel := context.WithTimeout(context.Background(), webSocketOperationTimeout)
		defer cancel()
		_ = connection.hub.presence.Disconnect(ctx, connection.matchID, connection.userID, connection.id)
	})
}

func snapshotEnvelope(snapshot Snapshot) ([]byte, error) {
	var payload gomokuSnapshotPayload
	if json.Unmarshal(snapshot.Game.State, &payload) != nil || len(snapshot.Players) != 2 {
		return nil, ErrInternal
	}
	var blackID, whiteID string
	for _, player := range snapshot.Players {
		switch player.Color {
		case ColorBlack:
			blackID = player.UserID
		case ColorWhite:
			whiteID = player.UserID
		default:
			return nil, ErrInternal
		}
	}
	if blackID == "" || whiteID == "" {
		return nil, ErrInternal
	}
	payload.BlackUserID, payload.WhiteUserID = &blackID, &whiteID
	payload.Status = snapshot.Match.Status
	payload.WinnerUserID = cloneStringPointer(snapshot.Match.WinnerUserID)
	payload.Result = cloneStringPointer(snapshot.Match.Result)
	return boundEnvelope(snapshot.Match.GameID, snapshot.Match.ID, snapshot.Match.Revision, protocol.TypePlatformSnapshot, "", payload)
}

func eventEnvelope(gameID string, event Event) ([]byte, error) {
	if gameID == "" || event.MatchID == "" || event.Revision <= 0 || event.Type == "" {
		return nil, ErrInvalidRequest
	}
	var actionID string
	if event.ActionID != nil {
		actionID = *event.ActionID
	}
	return boundEnvelope(gameID, event.MatchID, event.Revision, event.Type, actionID, json.RawMessage(event.Payload))
}

func boundEnvelope(gameID, matchID string, revision int64, messageType, actionID string, payload any) ([]byte, error) {
	encodedPayload, err := json.Marshal(payload)
	if err != nil {
		return nil, ErrInternal
	}
	revisionCopy := revision
	envelope := protocol.Envelope{
		ProtocolVersion: protocol.Version1, GameID: gameID, MatchID: matchID,
		Revision: &revisionCopy, Type: messageType, ActionID: actionID, Payload: encodedPayload,
	}
	data, err := json.Marshal(envelope)
	if err != nil || len(data) > protocol.MaxMessageBytes {
		return nil, ErrInternal
	}
	return data, nil
}

func safeActionErrorCode(err error) string {
	switch {
	case errors.Is(err, ErrActionConflict):
		return "action_conflict"
	case errors.Is(err, gomoku.ErrNotYourTurn):
		return "not_your_turn"
	case errors.Is(err, gomoku.ErrCellOccupied):
		return "cell_occupied"
	case errors.Is(err, ErrInvalidRequest):
		return "invalid_request"
	case errors.Is(err, ErrMatchNotFound):
		return "match_not_found"
	default:
		return "internal_error"
	}
}

func fixedErrorMessage(code string) string {
	switch code {
	case "invalid_connect":
		return "The first message is invalid"
	case "credential_invalid":
		return "The connection credential is invalid"
	case "stale_revision":
		return "The match state is out of date"
	case "action_conflict":
		return "The action id was already used"
	case "not_your_turn":
		return "It is not your turn"
	case "cell_occupied":
		return "The board cell is occupied"
	case "match_not_found":
		return "The match was not found"
	case "internal_error":
		return "An internal error occurred"
	default:
		return "The request is invalid"
	}
}

func mustJSON(value any) json.RawMessage {
	data, _ := json.Marshal(value)
	return data
}
