package matches

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"
	"github.com/google/uuid"

	"me.zqydev/gamebox/server/internal/clock"
	"me.zqydev/gamebox/server/internal/games/gomoku"
	"me.zqydev/gamebox/server/internal/games/rps"
	"me.zqydev/gamebox/server/internal/protocol"
)

const (
	webSocketFirstMessageTimeout = 5 * time.Second
	webSocketHeartbeatInterval   = 15 * time.Second
	webSocketOperationTimeout    = 5 * time.Second
	webSocketSendQueueSize       = 32
	webSocketPendingLimit        = 32
	webSocketMaximumPingNonces   = 4096
)

type Hub struct {
	mu                  sync.Mutex
	matches             map[string]*hubMatch
	service             *Service
	presence            *Presence
	clock               clock.Clock
	firstMessageTimeout time.Duration
	heartbeatInterval   time.Duration
	activityTimeout     time.Duration
	logger              *log.Logger
	closed              bool
	activeHandlers      int
	handlersDone        chan struct{}
	shutdownDone        chan struct{}
}

type HubConfig struct {
	FirstMessageTimeout time.Duration
	HeartbeatInterval   time.Duration
	ActivityTimeout     time.Duration
	Logger              *log.Logger
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

type enqueueStateResult uint8

const (
	enqueueStateQueued enqueueStateResult = iota
	enqueueStateStale
	enqueueStateFull
	enqueueStateInvalid
)

type hubConnection struct {
	hub             *Hub
	transport       *websocket.Conn
	ctx             context.Context
	cancel          context.CancelFunc
	done            chan struct{}
	send            chan []byte
	closeOnce       sync.Once
	matchID         string
	gameID          string
	userID          string
	id              string
	ready           bool
	pending         []queuedMessage
	presence        map[string]bool
	presenceEnabled bool
	revision        atomic.Int64
	outboundMu      sync.Mutex
	pingMu          sync.Mutex
	pings           map[string]time.Time
}

type connectPayload struct {
	LaunchTicket string   `json:"launchTicket"`
	ResumeToken  string   `json:"resumeToken"`
	Capabilities []string `json:"capabilities"`
}

type connectedPayload struct {
	UserID          string                  `json:"userId"`
	ConnectionID    string                  `json:"connectionId"`
	ResumeToken     string                  `json:"resumeToken"`
	ResumeExpiresAt int64                   `json:"resumeExpiresAt"`
	Players         []playerPresencePayload `json:"players,omitempty"`
}

type playerPresencePayload struct {
	UserID string `json:"userId"`
	Online bool   `json:"online"`
}

type pingPayload struct {
	Nonce string `json:"nonce"`
}

type pongPayload struct {
	Nonce string `json:"nonce"`
}

type webSocketReadResult struct {
	messageType websocket.MessageType
	data        []byte
	err         error
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

type rpsPlayerSnapshot struct {
	UserID string  `json:"userId"`
	Score  int     `json:"score"`
	Locked bool    `json:"locked"`
	Choice *string `json:"choice,omitempty"`
}

type rpsSnapshotPayload struct {
	Status       string            `json:"status"`
	Format       string            `json:"format"`
	Round        int               `json:"round"`
	Me           rpsPlayerSnapshot `json:"me"`
	Opponent     rpsPlayerSnapshot `json:"opponent"`
	LastReveal   *rpsRevealPayload `json:"lastReveal"`
	WinnerUserID *string           `json:"winnerUserId"`
	Result       *string           `json:"result"`
}

func NewHub(service *Service, presence *Presence, serviceClock clock.Clock) (*Hub, error) {
	return NewHubWithConfig(service, presence, serviceClock, HubConfig{})
}

func NewHubWithConfig(service *Service, presence *Presence, serviceClock clock.Clock, config HubConfig) (*Hub, error) {
	if service == nil || presence == nil || !service.configured() || nilDependency(service.ticketRandom) || len([]byte(service.tokenPepper)) < minimumTokenPepperBytes || !presence.configured() || nilDependency(serviceClock) {
		return nil, ErrInvalidConfiguration
	}
	if config.FirstMessageTimeout < 0 || config.HeartbeatInterval < 0 || config.ActivityTimeout < 0 {
		return nil, ErrInvalidConfiguration
	}
	if config.FirstMessageTimeout == 0 {
		config.FirstMessageTimeout = webSocketFirstMessageTimeout
	}
	if config.HeartbeatInterval == 0 {
		config.HeartbeatInterval = webSocketHeartbeatInterval
	}
	if config.ActivityTimeout == 0 {
		config.ActivityTimeout = presenceConnectionTimeout
	}
	hub := &Hub{
		matches: make(map[string]*hubMatch), service: service, presence: presence, clock: serviceClock,
		firstMessageTimeout: config.FirstMessageTimeout, heartbeatInterval: config.HeartbeatInterval, activityTimeout: config.ActivityTimeout,
		logger: config.Logger, handlersDone: make(chan struct{}),
	}
	presence.setObserver(hub)
	return hub, nil
}

// ServeHTTP owns a single upgraded connection for its complete lifetime.
// Native apps omit Origin; coder/websocket's default same-host policy rejects
// browser cross-origin handshakes without weakening local development safety.
func (hub *Hub) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	if hub == nil || hub.service == nil || hub.presence == nil || request == nil || !hub.beginServe() {
		http.Error(writer, http.StatusText(http.StatusServiceUnavailable), http.StatusServiceUnavailable)
		return
	}
	defer hub.endServe()
	transport, err := websocket.Accept(writer, request, &websocket.AcceptOptions{
		CompressionMode: websocket.CompressionDisabled,
	})
	if err != nil {
		return
	}
	transport.SetReadLimit(protocol.MaxMessageBytes)
	firstRead := make(chan webSocketReadResult, 1)
	go func() {
		messageType, data, err := transport.Read(context.Background())
		firstRead <- webSocketReadResult{messageType: messageType, data: data, err: err}
	}()
	firstTimer := time.NewTimer(hub.firstMessageTimeout)
	var readResult webSocketReadResult
	select {
	case readResult = <-firstRead:
		if !firstTimer.Stop() {
			select {
			case <-firstTimer.C:
			default:
			}
		}
	case <-firstTimer.C:
		writeHandshakeError(transport, "invalid_request")
		_ = transport.Close(websocket.StatusPolicyViolation, "invalid_request")
		return
	}
	messageType, data, readErr := readResult.messageType, readResult.data, readResult.err
	if readErr != nil || messageType != websocket.MessageText {
		writeHandshakeError(transport, "invalid_request")
		_ = transport.Close(websocket.StatusPolicyViolation, "invalid_request")
		return
	}
	envelope, decodeErr := protocol.DecodeClient(data)
	if decodeErr != nil || envelope.Type != protocol.TypePlatformConnect {
		writeHandshakeError(transport, "invalid_request")
		_ = transport.Close(websocket.StatusPolicyViolation, "invalid_request")
		return
	}
	var payload connectPayload
	if json.Unmarshal(envelope.Payload, &payload) != nil {
		writeHandshakeError(transport, "invalid_request")
		_ = transport.Close(websocket.StatusPolicyViolation, "invalid_request")
		return
	}
	operationContext, cancelOperation := context.WithTimeout(context.Background(), webSocketOperationTimeout)
	credential, credentialErr := hub.service.ConnectCredential(operationContext, CredentialRequest{
		LaunchTicket: payload.LaunchTicket, ResumeToken: payload.ResumeToken,
	})
	cancelOperation()
	if credentialErr != nil {
		code := "internal_error"
		switch {
		case errors.Is(credentialErr, ErrTicketInvalid):
			code = "ticket_invalid"
		case errors.Is(credentialErr, ErrResumeExpired):
			code = "resume_expired"
		case errors.Is(credentialErr, ErrInvalidRequest):
			code = "invalid_request"
		}
		writeHandshakeError(transport, code)
		_ = transport.Close(websocket.StatusPolicyViolation, code)
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
		pending: make([]queuedMessage, 0, 4), presence: make(map[string]bool),
		presenceEnabled: supportsPlayerPresence(payload.Capabilities),
	}
	operationContext, cancelOperation = context.WithTimeout(context.Background(), webSocketOperationTimeout)
	connectErr := hub.presence.Connect(operationContext, connection.matchID, connection.userID, connection.id)
	cancelOperation()
	if connectErr != nil {
		writeHandshakeError(transport, "internal_error")
		_ = transport.Close(websocket.StatusInternalError, "internal error")
		return
	}
	if !hub.register(connection) {
		connection.close()
		return
	}
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
		connection.enqueueError("internal_error", "")
		return
	}
	connectedData := connectedPayload{
		UserID: credential.UserID, ConnectionID: connection.id, ResumeToken: credential.ResumeToken,
		ResumeExpiresAt: credential.ResumeExpiresAt.UnixMilli(),
	}
	if connection.presenceEnabled {
		connectedData.Players = hub.playerPresences(snapshot)
	}
	connected, marshalErr := boundEnvelope(connection.gameID, connection.matchID, snapshot.Match.Revision, protocol.TypePlatformConnected, "", connectedData)
	if marshalErr != nil {
		return
	}
	snapshotMessage, marshalErr := snapshotEnvelope(snapshot, connection.userID)
	if marshalErr != nil || !connection.enqueueInitial(connected, snapshotMessage, snapshot.Match.Revision) {
		return
	}
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
		snapshotMessage, marshalErr = snapshotEnvelope(snapshot, connection.userID)
		if marshalErr != nil || connection.enqueueState(snapshotMessage, snapshot.Match.Revision) != enqueueStateQueued {
			return
		}
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

func (hub *Hub) register(connection *hubConnection) bool {
	hub.mu.Lock()
	if hub.closed {
		hub.mu.Unlock()
		return false
	}
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
	hub.logf("event=websocket_connected connection_id=%s match_id=%s user_id=%s", connection.id, connection.matchID, connection.userID)
	// A successful reconnect supersedes the user's older transport while
	// Presence keeps the player online across their brief overlap.
	for _, existing := range previous {
		existing.close()
	}
	return true
}

// Close stops new WebSocket registrations and closes every transport that is
// currently owned by the hub. It is idempotent and waits only until ctx ends.
func (hub *Hub) Close(ctx context.Context) error {
	if hub == nil {
		return nil
	}
	if ctx == nil {
		return ErrInvalidRequest
	}
	hub.mu.Lock()
	if hub.matches == nil || hub.handlersDone == nil {
		hub.mu.Unlock()
		return ErrInvalidConfiguration
	}
	if hub.closed {
		done := hub.shutdownDone
		hub.mu.Unlock()
		return waitForHubShutdown(ctx, done)
	}
	hub.closed = true
	hub.shutdownDone = make(chan struct{})
	if hub.activeHandlers == 0 {
		close(hub.handlersDone)
	}
	connections := make([]*hubConnection, 0)
	for _, match := range hub.matches {
		for connection := range match.connections {
			connections = append(connections, connection)
		}
	}
	handlersDone := hub.handlersDone
	shutdownDone := hub.shutdownDone
	hub.mu.Unlock()
	hub.logf("event=hub_closed")

	go func() {
		var wait sync.WaitGroup
		wait.Add(len(connections))
		for _, connection := range connections {
			go func() {
				defer wait.Done()
				connection.close()
			}()
		}
		wait.Wait()
		<-handlersDone
		close(shutdownDone)
	}()
	return waitForHubShutdown(ctx, shutdownDone)
}

func waitForHubShutdown(ctx context.Context, done <-chan struct{}) error {
	select {
	case <-done:
		return nil
	default:
	}
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
	hub.activeHandlers++
	return true
}

func (hub *Hub) endServe() {
	hub.mu.Lock()
	defer hub.mu.Unlock()
	if hub.activeHandlers > 0 {
		hub.activeHandlers--
	}
	if hub.closed && hub.activeHandlers == 0 {
		select {
		case <-hub.handlersDone:
		default:
			close(hub.handlersDone)
		}
	}
}

func (hub *Hub) logf(format string, arguments ...any) {
	if hub != nil && hub.logger != nil {
		hub.logger.Printf(format, arguments...)
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
			result := existing.enqueueState(snapshotMessage, snapshotRevision)
			if result == enqueueStateFull || result == enqueueStateInvalid {
				existing.ready = false
				slow = append(slow, existing)
				continue
			}
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
		result := connection.enqueueEvent(pending.data, pending.revision)
		if result == enqueueStateFull || result == enqueueStateInvalid {
			queued = false
			break
		}
	}
	connection.pending = nil
	userIDs := make([]string, 0, len(connection.presence))
	for userID := range connection.presence {
		userIDs = append(userIDs, userID)
	}
	sort.Strings(userIDs)
	for _, userID := range userIDs {
		if !queued || !connection.enqueuePresence(userID, connection.presence[userID]) {
			queued = false
			break
		}
	}
	connection.presence = nil
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

// playerPresenceChanged fans out platform-owned presence without consuming a
// durable game revision. Connections still handshaking retain only the latest
// state per player and receive it after their initial snapshot.
func (hub *Hub) playerPresenceChanged(matchID, userID string, online bool) {
	if hub == nil || matchID == "" || userID == "" {
		return
	}
	slow := make([]*hubConnection, 0)
	hub.mu.Lock()
	if hub.closed {
		hub.mu.Unlock()
		return
	}
	match := hub.matches[matchID]
	if match == nil {
		hub.mu.Unlock()
		return
	}
	for connection := range match.connections {
		if !connection.presenceEnabled {
			continue
		}
		if !connection.ready {
			if connection.presence == nil {
				connection.presence = make(map[string]bool)
			}
			connection.presence[userID] = online
			continue
		}
		if !connection.enqueuePresence(userID, online) {
			connection.ready = false
			slow = append(slow, connection)
		}
	}
	hub.mu.Unlock()
	for _, connection := range slow {
		connection.close()
	}
}

func supportsPlayerPresence(capabilities []string) bool {
	for _, capability := range capabilities {
		if capability == protocol.CapabilityPlayerPresence {
			return true
		}
	}
	return false
}

func (hub *Hub) playerPresences(snapshot Snapshot) []playerPresencePayload {
	players := append([]Player(nil), snapshot.Players...)
	sort.Slice(players, func(left, right int) bool { return players[left].Seat < players[right].Seat })
	userIDs := make([]string, 0, len(players))
	for _, player := range players {
		userIDs = append(userIDs, player.UserID)
	}
	states := hub.presence.onlineStates(snapshot.Match.ID, userIDs)
	payload := make([]playerPresencePayload, 0, len(players))
	for _, player := range players {
		payload = append(payload, playerPresencePayload{UserID: player.UserID, Online: states[player.UserID]})
	}
	return payload
}

// Publish performs only ordered best-effort fan-out. The event is already
// committed and the Hub never invokes game rules or persistence from here.
func (hub *Hub) Publish(matchID string, event Event) {
	if hub == nil || matchID == "" || event.MatchID != matchID || event.Revision <= 0 || event.Revision > maximumMatchEvents {
		return
	}
	var slow []*hubConnection
	hub.mu.Lock()
	if hub.closed {
		hub.mu.Unlock()
		return
	}
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
				result := connection.enqueueEvent(data, nextRevision)
				if result == enqueueStateFull || result == enqueueStateInvalid {
					slow = append(slow, connection)
					continue
				}
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

func (connection *hubConnection) enqueueState(data []byte, revision int64) enqueueStateResult {
	connection.outboundMu.Lock()
	defer connection.outboundMu.Unlock()
	return connection.enqueueStateLocked(data, revision)
}

func (connection *hubConnection) enqueueEvent(data []byte, revision int64) enqueueStateResult {
	connection.outboundMu.Lock()
	defer connection.outboundMu.Unlock()
	if revision <= 0 || len(data) == 0 {
		return enqueueStateInvalid
	}
	if revision <= connection.revision.Load() {
		return enqueueStateStale
	}
	return connection.enqueueStateLocked(data, revision)
}

func (connection *hubConnection) enqueueStateLocked(data []byte, revision int64) enqueueStateResult {
	if revision < 0 || len(data) == 0 {
		return enqueueStateInvalid
	}
	current := connection.revision.Load()
	if revision < current {
		return enqueueStateStale
	}
	if !connection.enqueue(data) {
		return enqueueStateFull
	}
	if revision > current {
		connection.revision.Store(revision)
	}
	return enqueueStateQueued
}

func (connection *hubConnection) enqueueInitial(connected, snapshot []byte, revision int64) bool {
	connection.outboundMu.Lock()
	defer connection.outboundMu.Unlock()
	if revision < 0 || len(connected) == 0 || len(snapshot) == 0 || cap(connection.send)-len(connection.send) < 2 {
		return false
	}
	connection.send <- append([]byte(nil), connected...)
	connection.send <- append([]byte(nil), snapshot...)
	connection.revision.Store(revision)
	return true
}

func (connection *hubConnection) enqueueErrorAndSnapshot(code, actionID string, snapshot Snapshot) enqueueStateResult {
	snapshotMessage, err := snapshotEnvelope(snapshot, connection.userID)
	if err != nil {
		return enqueueStateInvalid
	}
	errorMessage, err := boundEnvelope(connection.gameID, connection.matchID, snapshot.Match.Revision, protocol.TypePlatformError, actionID,
		errorPayload{Code: code, Message: fixedErrorMessage(code), Details: map[string]any{}})
	if err != nil {
		return enqueueStateInvalid
	}
	connection.outboundMu.Lock()
	defer connection.outboundMu.Unlock()
	current := connection.revision.Load()
	if snapshot.Match.Revision < current {
		return enqueueStateStale
	}
	if cap(connection.send)-len(connection.send) < 2 {
		return enqueueStateFull
	}
	connection.send <- append([]byte(nil), errorMessage...)
	connection.send <- append([]byte(nil), snapshotMessage...)
	if snapshot.Match.Revision > current {
		connection.revision.Store(snapshot.Match.Revision)
	}
	return enqueueStateQueued
}

func (connection *hubConnection) enqueuePresence(userID string, online bool) bool {
	connection.outboundMu.Lock()
	defer connection.outboundMu.Unlock()
	message, err := boundEnvelope(connection.gameID, connection.matchID, connection.revision.Load(), protocol.TypePlatformPresenceChanged, "",
		playerPresencePayload{UserID: userID, Online: online})
	if err != nil {
		return false
	}
	return connection.enqueue(message)
}

func (connection *hubConnection) writeLoop() {
	defer close(connection.done)
	ticker := time.NewTicker(connection.hub.heartbeatInterval)
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
			connection.recordPing(nonce.String())
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
		remaining := connection.hub.activityTimeout - time.Since(lastActivity)
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
			connection.enqueueError("invalid_request", "")
			continue
		}
		envelope, decodeErr := protocol.DecodeClient(data)
		if decodeErr != nil || envelope.Type == protocol.TypePlatformConnect || envelope.MatchID != connection.matchID || envelope.GameID != connection.gameID {
			connection.enqueueError("invalid_request", "")
			continue
		}
		if envelope.Type == protocol.TypePlatformPong {
			var payload pongPayload
			if json.Unmarshal(envelope.Payload, &payload) != nil || !connection.validPong(payload.Nonce) {
				connection.enqueueError("invalid_request", "")
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
				connection.enqueueError("invalid_request", "")
				continue
			}
			connection.sendLatestSnapshot()
		case protocol.TypeGomokuMoveRequested, protocol.TypeGomokuResignRequested, protocol.TypeRpsChoiceRequested, protocol.TypeRpsResignRequested:
			connection.applyAction(envelope)
		default:
			connection.enqueueError("invalid_request", envelope.ActionID)
		}
	}
}

func (connection *hubConnection) validPong(nonce string) bool {
	connection.pingMu.Lock()
	defer connection.pingMu.Unlock()
	if nonce == "" {
		return false
	}
	connection.prunePingsLocked(connection.hub.clock.Now().UTC())
	if _, exists := connection.pings[nonce]; !exists {
		return false
	}
	delete(connection.pings, nonce)
	return true
}

func (connection *hubConnection) recordPing(nonce string) {
	connection.pingMu.Lock()
	defer connection.pingMu.Unlock()
	now := connection.hub.clock.Now().UTC()
	if connection.pings == nil {
		connection.pings = make(map[string]time.Time)
	}
	connection.prunePingsLocked(now)
	limit := outstandingPingLimit(connection.hub.activityTimeout, connection.hub.heartbeatInterval)
	for len(connection.pings) >= limit {
		var oldestNonce string
		var oldestTime time.Time
		for candidate, issuedAt := range connection.pings {
			if oldestNonce == "" || issuedAt.Before(oldestTime) || issuedAt.Equal(oldestTime) && candidate < oldestNonce {
				oldestNonce, oldestTime = candidate, issuedAt
			}
		}
		delete(connection.pings, oldestNonce)
	}
	connection.pings[nonce] = now
}

func (connection *hubConnection) prunePingsLocked(now time.Time) {
	for nonce, issuedAt := range connection.pings {
		age := now.Sub(issuedAt)
		if age < 0 || age > connection.hub.activityTimeout {
			delete(connection.pings, nonce)
		}
	}
}

func outstandingPingLimit(activityTimeout, heartbeatInterval time.Duration) int {
	if activityTimeout <= 0 || heartbeatInterval <= 0 {
		return 1
	}
	intervals := activityTimeout / heartbeatInterval
	if activityTimeout%heartbeatInterval != 0 {
		intervals++
	}
	if intervals >= webSocketMaximumPingNonces-1 {
		return webSocketMaximumPingNonces
	}
	return int(intervals) + 1
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
		connection.sendStaleResponse(envelope.ActionID)
		return
	}
	connection.enqueueError(safeActionErrorCode(err), envelope.ActionID)
}

func (connection *hubConnection) sendLatestSnapshot() {
	for attempts := 0; attempts <= maximumMatchEvents; attempts++ {
		operationContext, cancel := context.WithTimeout(connection.ctx, webSocketOperationTimeout)
		snapshot, err := connection.hub.service.Snapshot(operationContext, connection.matchID)
		cancel()
		if err != nil {
			connection.enqueueError("internal_error", "")
			return
		}
		switch connection.enqueueSnapshot(snapshot) {
		case enqueueStateQueued:
			return
		case enqueueStateStale:
			continue
		default:
			connection.close()
			return
		}
	}
	connection.close()
}

func (connection *hubConnection) sendStaleResponse(actionID string) {
	for attempts := 0; attempts <= maximumMatchEvents; attempts++ {
		operationContext, cancel := context.WithTimeout(connection.ctx, webSocketOperationTimeout)
		snapshot, err := connection.hub.service.Snapshot(operationContext, connection.matchID)
		cancel()
		if err != nil {
			connection.enqueueError("internal_error", actionID)
			return
		}
		switch connection.enqueueErrorAndSnapshot("stale_revision", actionID, snapshot) {
		case enqueueStateQueued:
			return
		case enqueueStateStale:
			continue
		default:
			connection.close()
			return
		}
	}
	connection.close()
}

func (connection *hubConnection) enqueueSnapshot(snapshot Snapshot) enqueueStateResult {
	message, err := snapshotEnvelope(snapshot, connection.userID)
	if err != nil {
		return enqueueStateInvalid
	}
	return connection.enqueueState(message, snapshot.Match.Revision)
}

func (connection *hubConnection) enqueueError(code, actionID string) {
	connection.outboundMu.Lock()
	revision := connection.revision.Load()
	message, err := boundEnvelope(connection.gameID, connection.matchID, revision, protocol.TypePlatformError, actionID,
		errorPayload{Code: code, Message: fixedErrorMessage(code), Details: map[string]any{}})
	queued := err == nil && connection.enqueue(message)
	connection.outboundMu.Unlock()
	if !queued {
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
		connection.hub.logf("event=websocket_closed connection_id=%s match_id=%s user_id=%s", connection.id, connection.matchID, connection.userID)
	})
}

func snapshotEnvelope(snapshot Snapshot, viewerIDs ...string) ([]byte, error) {
	if snapshot.Match.GameID == rps.GameID {
		if len(viewerIDs) != 1 {
			return nil, ErrInternal
		}
		return rpsSnapshotEnvelope(snapshot, viewerIDs[0])
	}
	if snapshot.Match.GameID != gomoku.GameID {
		return nil, ErrInternal
	}
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

func rpsSnapshotEnvelope(snapshot Snapshot, viewerID string) ([]byte, error) {
	var full struct {
		Status       string            `json:"status"`
		Format       string            `json:"format"`
		Round        int               `json:"round"`
		Choices      map[string]string `json:"choices"`
		Scores       map[string]int    `json:"scores"`
		LastReveal   *rpsRevealPayload `json:"lastReveal"`
		WinnerUserID *string           `json:"winnerUserId"`
		Result       *string           `json:"result"`
	}
	if json.Unmarshal(snapshot.Game.State, &full) != nil || len(snapshot.Players) != 2 || full.Round < 1 || (full.Format != rps.FormatSingleRound && full.Format != rps.FormatBestOfThree) {
		return nil, ErrInternal
	}
	var opponentID string
	member := false
	for _, player := range snapshot.Players {
		if player.UserID == viewerID {
			member = true
		} else {
			opponentID = player.UserID
		}
	}
	if !member || opponentID == "" {
		return nil, ErrInternal
	}
	payload := rpsSnapshotPayload{
		Status: snapshot.Match.Status, Format: full.Format, Round: full.Round,
		Me:         rpsPlayerSnapshot{UserID: viewerID, Score: full.Scores[viewerID]},
		Opponent:   rpsPlayerSnapshot{UserID: opponentID, Score: full.Scores[opponentID]},
		LastReveal: full.LastReveal, WinnerUserID: cloneStringPointer(snapshot.Match.WinnerUserID), Result: cloneStringPointer(snapshot.Match.Result),
	}
	if choice, ok := full.Choices[viewerID]; ok {
		payload.Me.Locked = true
		payload.Me.Choice = stringPointer(choice)
	}
	if _, ok := full.Choices[opponentID]; ok {
		payload.Opponent.Locked = true
	}
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
	payload := any(json.RawMessage(event.Payload))
	if gameID == rps.GameID && event.Type == rps.ChoiceLocked {
		locked, err := decodeRpsLocked(event.Payload)
		if err != nil {
			return nil, ErrInternal
		}
		payload = struct {
			Round  int    `json:"round"`
			UserID string `json:"userId"`
			Locked bool   `json:"locked"`
		}{Round: locked.Round, UserID: locked.UserID, Locked: true}
	}
	return boundEnvelope(gameID, event.MatchID, event.Revision, event.Type, actionID, payload)
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
	case errors.Is(err, rps.ErrChoiceLocked):
		return "choice_locked"
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
	case "ticket_invalid":
		return "The launch ticket is invalid"
	case "resume_expired":
		return "The resume session has expired"
	case "stale_revision":
		return "The match state is out of date"
	case "action_conflict":
		return "The action id was already used"
	case "not_your_turn":
		return "It is not your turn"
	case "cell_occupied":
		return "The board cell is occupied"
	case "choice_locked":
		return "Your choice is already locked"
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
