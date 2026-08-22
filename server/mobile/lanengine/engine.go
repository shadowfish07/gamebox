// Package lanengine exposes the Android LAN host boundary to gomobile.
package lanengine

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"

	"me.zqydev/gamebox/server/internal/games/gomoku"
	"me.zqydev/gamebox/server/internal/lan/httpapi"
	"me.zqydev/gamebox/server/internal/lan/room"
	"me.zqydev/gamebox/server/internal/nickname"
	"me.zqydev/gamebox/server/internal/protocol"
)

// NormalizeNickname exposes the single Go nickname implementation through a
// primitive gomobile-safe JSON boundary.
func NormalizeNickname(raw string) string {
	display, normalized, err := nickname.Normalize(raw)
	result := struct {
		Display    string `json:"display"`
		Normalized string `json:"normalized"`
		Valid      bool   `json:"valid"`
	}{Display: display, Normalized: normalized, Valid: err == nil}
	encoded, marshalErr := json.Marshal(result)
	if marshalErr != nil {
		return `{"display":"","normalized":"","valid":false}`
	}
	return string(encoded)
}

var (
	ErrInvalidConfiguration = errors.New("invalid configuration")
	ErrNotRunning           = errors.New("not_running")
	ErrCleanupNotReady      = errors.New("cleanup_not_ready")
	ErrInternal             = errors.New("internal_error")
)

const (
	minimumLANPort   = 49152
	maximumLANPort   = 65535
	maximumJSONBytes = 64 * 1024
	maximumJSONDepth = 32
	shutdownTimeout  = 5 * time.Second
)

// Engine owns one race-safe LAN listener and journal-backed room.
type Engine struct {
	mu              sync.Mutex
	root            string
	service         *room.Service
	router          *httpapi.Router
	server          *http.Server
	listener        net.Listener
	secrets         roomSecrets
	port            int
	endpointChanged bool
	corrupt         bool
}

type roomSecrets struct {
	RoomID          string
	HostPlayerID    string
	TokenPepper     string
	HostResumeToken string
}

func (roomSecrets) String() string {
	return "roomSecrets{RoomID:<id> HostPlayerID:<id> TokenPepper:<redacted> HostResumeToken:<redacted>}"
}
func (secrets roomSecrets) GoString() string { return secrets.String() }

type createRoomRequest struct {
	roomSecrets
	HostNickname  string
	RoomKey       string
	JoinExpiresAt int64
}

func (createRoomRequest) String() string {
	return "createRoomRequest{identifiers:<redacted> nickname:<redacted> roomKey:<redacted> tokenPepper:<redacted> hostResumeToken:<redacted> joinExpiresAt:<time>}"
}
func (request createRoomRequest) GoString() string { return request.String() }

type statusResponse struct {
	SchemaVersion   int    `json:"schemaVersion"`
	State           string `json:"state"`
	RoomID          string `json:"roomId"`
	Port            int    `json:"port"`
	GameRevision    int64  `json:"gameRevision"`
	EndpointChanged bool   `json:"endpointChanged"`
}

type launchResponse struct {
	SchemaVersion int    `json:"schemaVersion"`
	MatchID       string `json:"matchId"`
	GameID        string `json:"gameId"`
	LaunchTicket  string `json:"launchTicket"`
	WSURL         string `json:"wsUrl"`
	ExpiresAt     int64  `json:"expiresAt"`
}

func (launchResponse) String() string {
	return "launchResponse{SchemaVersion:1 MatchID:<id> GameID:gomoku LaunchTicket:<redacted> WSURL:<loopback> ExpiresAt:<time>}"
}
func (response launchResponse) GoString() string { return response.String() }

// NewEngine creates an Engine with its local data root.
func NewEngine(root string) (*Engine, error) {
	if strings.TrimSpace(root) == "" {
		return nil, ErrInvalidConfiguration
	}
	return &Engine{root: filepath.Clean(root)}, nil
}

func (engine *Engine) Start(roomSecretsJSON string) (string, error) {
	secrets, err := decodeStartRequest(roomSecretsJSON)
	if err != nil || engine == nil {
		return "", ErrInvalidConfiguration
	}
	engine.mu.Lock()
	defer engine.mu.Unlock()
	if engine.service != nil || engine.corrupt {
		if !sameSecrets(engine.secrets, secrets) {
			return "", ErrInvalidConfiguration
		}
		return engine.statusLocked(), nil
	}
	preferredPort, preferredValid := readManifestPort(engine.activeRoot(), secrets.RoomID)
	service, openErr := room.Open(room.Config{Root: engine.activeRoot(), TokenPepper: secrets.TokenPepper})
	if openErr != nil {
		if errors.Is(openErr, room.ErrRecoveryCorrupt) {
			engine.secrets, engine.corrupt = secrets, true
			return engine.statusLocked(), nil
		}
		return "", ErrInternal
	}
	snapshot := service.Snapshot()
	if snapshot.RoomID != secrets.RoomID || len(snapshot.Players) == 0 || snapshot.Players[0].PlayerID != secrets.HostPlayerID {
		_ = service.Close()
		return "", ErrInvalidConfiguration
	}
	credential, credentialErr := service.ConnectLAN(context.Background(), room.ConnectCredential{ResumeToken: secrets.HostResumeToken})
	if credentialErr != nil || credential.PlayerID != secrets.HostPlayerID {
		_ = service.Close()
		return "", ErrInvalidConfiguration
	}
	listener, port, endpointChanged, listenErr := reserveForStart(preferredPort, preferredValid)
	if listenErr != nil {
		_ = service.Close()
		return "", ErrInternal
	}
	if err := engine.activateLocked(service, listener, port, endpointChanged, secrets); err != nil {
		_ = listener.Close()
		_ = service.Close()
		return "", err
	}
	return engine.statusLocked(), nil
}

func (engine *Engine) CreateRoom(createJSON string) (string, error) {
	request, err := decodeCreateRequest(createJSON)
	if err != nil || engine == nil {
		return "", ErrInvalidConfiguration
	}
	engine.mu.Lock()
	defer engine.mu.Unlock()
	if engine.service != nil {
		if sameSecrets(engine.secrets, request.roomSecrets) {
			return engine.statusLocked(), nil
		}
		return "", ErrInvalidConfiguration
	}
	if engine.corrupt {
		return "", ErrInvalidConfiguration
	}
	service, openErr := room.Open(room.Config{Root: engine.activeRoot(), TokenPepper: request.TokenPepper})
	if openErr != nil {
		return "", ErrInternal
	}
	snapshot := service.Snapshot()
	newRoom := snapshot.Status == room.StatusEmpty
	var listener net.Listener
	var port int
	var endpointChanged bool
	if newRoom {
		listener, port, err = reserveRandomHighPort()
	} else {
		preferredPort, preferredValid := readManifestPort(engine.activeRoot(), request.RoomID)
		listener, port, endpointChanged, err = reserveForStart(preferredPort, preferredValid)
	}
	if err != nil {
		_ = service.Close()
		return "", ErrInternal
	}
	if newRoom {
		_, err = service.Create(context.Background(), room.CreateRequest{
			RoomID: request.RoomID, HostPlayerID: request.HostPlayerID, HostNickname: request.HostNickname,
			RoomKey: request.RoomKey, TokenPepper: request.TokenPepper, HostResumeToken: request.HostResumeToken,
			JoinExpiresAt: request.JoinExpiresAt,
		})
		endpointChanged = false
	} else {
		if snapshot.RoomID != request.RoomID || len(snapshot.Players) == 0 || snapshot.Players[0].PlayerID != request.HostPlayerID {
			err = ErrInvalidConfiguration
		} else if credential, credentialErr := service.ConnectLAN(context.Background(), room.ConnectCredential{ResumeToken: request.HostResumeToken}); credentialErr != nil || credential.PlayerID != request.HostPlayerID {
			err = ErrInvalidConfiguration
		}
	}
	if err != nil {
		_ = listener.Close()
		_ = service.Close()
		if errors.Is(err, ErrInvalidConfiguration) {
			return "", ErrInvalidConfiguration
		}
		return "", ErrInternal
	}
	if err := engine.activateLocked(service, listener, port, endpointChanged, request.roomSecrets); err != nil {
		_ = listener.Close()
		_ = service.Close()
		return "", err
	}
	return engine.statusLocked(), nil
}

func (engine *Engine) IssueHostLaunch() (string, error) {
	if engine == nil {
		return "", ErrNotRunning
	}
	engine.mu.Lock()
	defer engine.mu.Unlock()
	if engine.service == nil || engine.port == 0 {
		return "", ErrNotRunning
	}
	ticket, err := engine.service.IssueLaunch(context.Background(), engine.secrets.HostPlayerID, engine.secrets.HostResumeToken)
	if err != nil {
		return "", ErrInternal
	}
	return marshalJSON(launchResponse{
		SchemaVersion: 1, MatchID: engine.secrets.RoomID, GameID: gomoku.GameID,
		LaunchTicket: ticket.Token, WSURL: fmt.Sprintf("ws://127.0.0.1:%d/lan/v1/ws", engine.port), ExpiresAt: ticket.ExpiresAt,
	})
}

// CloseRoom durably applies an explicit host close action. Cancel is valid
// only before the first game revision; resign is authenticated with the
// durable host resume credential and goes through the same action journal as
// every other Gomoku action.
func (engine *Engine) CloseRoom(mode string) (string, error) {
	if engine == nil || (mode != "cancel" && mode != "resign") {
		return "", ErrInvalidConfiguration
	}
	engine.mu.Lock()
	defer engine.mu.Unlock()
	if engine.service == nil {
		return "", ErrNotRunning
	}
	snapshot := engine.service.Snapshot()
	switch mode {
	case "cancel":
		if snapshot.Revision != 0 {
			return "", ErrInvalidConfiguration
		}
		event, err := engine.service.Cancel(context.Background(), engine.secrets.HostPlayerID)
		if err != nil {
			if errors.Is(err, room.ErrRoomNotCancellable) {
				return "", ErrInvalidConfiguration
			}
			return "", ErrInternal
		}
		if err := engine.router.PublishCommitted(event); err != nil {
			return "", ErrInternal
		}
	case "resign":
		if snapshot.Status != room.StatusActive || snapshot.Revision <= 0 {
			return "", ErrInvalidConfiguration
		}
		credential, err := engine.service.ConnectLAN(context.Background(), room.ConnectCredential{ResumeToken: engine.secrets.HostResumeToken})
		if err != nil || credential.PlayerID != engine.secrets.HostPlayerID {
			return "", ErrInvalidConfiguration
		}
		actionID, err := uuid.NewRandom()
		if err != nil {
			return "", ErrInternal
		}
		event, _, _, err := engine.service.Apply(context.Background(), room.ActionRequest{
			PlayerID: engine.secrets.HostPlayerID, ActionID: actionID.String(), ExpectedRevision: snapshot.Revision,
			Type: protocol.TypeGomokuResignRequested, Payload: json.RawMessage(`{}`),
		})
		if err != nil {
			if errors.Is(err, room.ErrInvalidRequest) || errors.Is(err, room.ErrStaleRevision) || errors.Is(err, room.ErrActionConflict) {
				return "", ErrInvalidConfiguration
			}
			return "", ErrInternal
		}
		if err := engine.router.PublishCommitted(event); err != nil {
			return "", ErrInternal
		}
	}
	return engine.statusLocked(), nil
}

// PrepareCleanup verifies terminal persistence policy and atomically stops the
// listener plus journal lock. The caller may delete the resolved active-room
// directory only after this method succeeds.
func (engine *Engine) PrepareCleanup(allowMissingGuestAck bool) (string, error) {
	if engine == nil {
		return "", ErrNotRunning
	}
	engine.mu.Lock()
	defer engine.mu.Unlock()
	if engine.service == nil {
		return "", ErrNotRunning
	}
	snapshot := engine.service.Snapshot()
	switch snapshot.Status {
	case room.StatusCancelled:
		// A revision-zero cancellation carries no result to persist.
	case room.StatusFinished:
		if snapshot.Result == nil || !containsPlayerID(snapshot.ResultAcknowledgedPlayerIDs, engine.secrets.HostPlayerID) {
			return "", ErrCleanupNotReady
		}
		if !allowMissingGuestAck {
			for _, player := range snapshot.Players {
				if !containsPlayerID(snapshot.ResultAcknowledgedPlayerIDs, player.PlayerID) {
					return "", ErrCleanupNotReady
				}
			}
		}
	default:
		return "", ErrCleanupNotReady
	}
	status := engine.statusLocked()
	if engine.stopLocked() != nil {
		return "", ErrInternal
	}
	return status, nil
}

func (engine *Engine) Status() string {
	if engine == nil {
		return `{"schemaVersion":1,"state":"empty"}`
	}
	engine.mu.Lock()
	defer engine.mu.Unlock()
	return engine.statusLocked()
}

func (engine *Engine) Stop() error {
	if engine == nil {
		return nil
	}
	engine.mu.Lock()
	defer engine.mu.Unlock()
	return engine.stopLocked()
}

// DeleteActiveRoom removes only the engine's fixed active_room tree after all
// listener, router, HTTP server, and journal-lock owners are stopped. It is
// idempotent when the fixed tree is absent and rejects links or special files.
func (engine *Engine) DeleteActiveRoom() error {
	if engine == nil {
		return ErrInvalidConfiguration
	}
	engine.mu.Lock()
	defer engine.mu.Unlock()
	if engine.service != nil || engine.router != nil || engine.server != nil || engine.listener != nil {
		return ErrCleanupNotReady
	}
	if err := removeActiveRoomTree(engine.root); err != nil {
		return ErrInternal
	}
	return nil
}

func (engine *Engine) stopLocked() error {
	var failed bool
	if engine.server != nil && engine.server.Close() != nil {
		failed = true
	}
	if engine.router != nil {
		ctx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
		if engine.router.Close(ctx) != nil {
			failed = true
		}
		cancel()
	}
	if engine.listener != nil {
		if err := engine.listener.Close(); err != nil && !errors.Is(err, net.ErrClosed) {
			failed = true
		}
	}
	if engine.service != nil && engine.service.Close() != nil {
		failed = true
	}
	engine.service, engine.router, engine.server, engine.listener = nil, nil, nil, nil
	engine.secrets, engine.port, engine.endpointChanged, engine.corrupt = roomSecrets{}, 0, false, false
	if failed {
		return ErrInternal
	}
	return nil
}

func containsPlayerID(playerIDs []string, target string) bool {
	for _, playerID := range playerIDs {
		if playerID == target {
			return true
		}
	}
	return false
}

func (engine *Engine) String() string   { return "lanengine.Engine{root:<path> room:<redacted>}" }
func (engine *Engine) GoString() string { return engine.String() }

func (engine *Engine) activeRoot() string { return filepath.Join(engine.root, "active_room") }

func (engine *Engine) activateLocked(service *room.Service, listener net.Listener, port int, endpointChanged bool, secrets roomSecrets) error {
	router, err := httpapi.NewRouter(service)
	if err != nil {
		return ErrInternal
	}
	if err := service.WriteManifestProjection(fmt.Sprintf("0.0.0.0:%d", port)); err != nil {
		_ = router.Close(context.Background())
		return ErrInternal
	}
	server := &http.Server{
		Handler: router, ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 60 * time.Second,
		MaxHeaderBytes: 8 * 1024, ErrorLog: log.New(io.Discard, "", 0),
	}
	engine.service, engine.router, engine.server, engine.listener = service, router, server, listener
	engine.secrets, engine.port, engine.endpointChanged, engine.corrupt = secrets, port, endpointChanged, false
	go func() { _ = server.Serve(listener) }()
	return nil
}

func (engine *Engine) statusLocked() string {
	if engine.corrupt {
		return mustMarshalStatus(statusResponse{SchemaVersion: 1, State: "corrupt", RoomID: engine.secrets.RoomID})
	}
	if engine.service == nil {
		return `{"schemaVersion":1,"state":"empty"}`
	}
	snapshot := engine.service.Snapshot()
	return mustMarshalStatus(statusResponse{
		SchemaVersion: 1, State: snapshot.Status, RoomID: snapshot.RoomID, Port: engine.port,
		GameRevision: snapshot.Revision, EndpointChanged: engine.endpointChanged,
	})
}

func mustMarshalStatus(status statusResponse) string {
	encoded, err := json.Marshal(status)
	if err != nil {
		return `{"schemaVersion":1,"state":"corrupt","roomId":"","port":0,"gameRevision":0,"endpointChanged":false}`
	}
	return string(encoded)
}

func marshalJSON(value any) (string, error) {
	encoded, err := json.Marshal(value)
	if err != nil {
		return "", ErrInternal
	}
	return string(encoded), nil
}

func reserveForStart(preferredPort int, valid bool) (net.Listener, int, bool, error) {
	if valid {
		listener, err := net.Listen("tcp4", fmt.Sprintf("0.0.0.0:%d", preferredPort))
		if err == nil {
			return listener, preferredPort, false, nil
		}
	}
	listener, port, err := reserveRandomHighPort()
	return listener, port, true, err
}

func reserveRandomHighPort() (net.Listener, int, error) {
	rangeSize := big.NewInt(maximumLANPort - minimumLANPort + 1)
	for attempt := 0; attempt < 256; attempt++ {
		randomOffset, err := rand.Int(rand.Reader, rangeSize)
		if err != nil {
			return nil, 0, err
		}
		port := minimumLANPort + int(randomOffset.Int64())
		listener, err := net.Listen("tcp4", fmt.Sprintf("0.0.0.0:%d", port))
		if err == nil {
			return listener, port, nil
		}
	}
	return nil, 0, ErrInternal
}

func readManifestPort(root, roomID string) (int, bool) {
	data, err := readManifestFile(filepath.Join(root, "manifest.json"))
	if err != nil {
		return 0, false
	}
	fields, err := exactObject(data, []string{"schemaVersion", "roomId", "gameId", "createdAt", "endpoint", "journalFormatVersion", "journalSequence"})
	if err != nil || string(fields["schemaVersion"]) != "1" || string(fields["journalFormatVersion"]) != "1" {
		return 0, false
	}
	if _, err := canonicalPositiveInteger(fields["createdAt"]); err != nil {
		return 0, false
	}
	if _, err := canonicalPositiveInteger(fields["journalSequence"]); err != nil {
		return 0, false
	}
	var manifestRoomID, gameID, endpoint string
	if json.Unmarshal(fields["roomId"], &manifestRoomID) != nil || manifestRoomID != roomID || json.Unmarshal(fields["gameId"], &gameID) != nil || gameID != gomoku.GameID || json.Unmarshal(fields["endpoint"], &endpoint) != nil {
		return 0, false
	}
	_, portText, err := net.SplitHostPort(endpoint)
	if err != nil {
		return 0, false
	}
	port, err := strconv.Atoi(portText)
	return port, err == nil && port >= minimumLANPort && port <= maximumLANPort
}

func decodeStartRequest(data string) (roomSecrets, error) {
	fields, err := exactObject([]byte(data), []string{"schemaVersion", "roomId", "hostPlayerId", "tokenPepper", "hostResumeToken"})
	if err != nil || string(fields["schemaVersion"]) != "1" {
		return roomSecrets{}, ErrInvalidConfiguration
	}
	var result roomSecrets
	if !decodeString(fields["roomId"], &result.RoomID) || !decodeString(fields["hostPlayerId"], &result.HostPlayerID) || !decodeString(fields["tokenPepper"], &result.TokenPepper) || !decodeString(fields["hostResumeToken"], &result.HostResumeToken) {
		return roomSecrets{}, ErrInvalidConfiguration
	}
	return result, nil
}

func decodeCreateRequest(data string) (createRoomRequest, error) {
	fields, err := exactObject([]byte(data), []string{"schemaVersion", "roomId", "hostPlayerId", "hostNickname", "roomKey", "tokenPepper", "hostResumeToken", "joinExpiresAt"})
	if err != nil || string(fields["schemaVersion"]) != "1" {
		return createRoomRequest{}, ErrInvalidConfiguration
	}
	var result createRoomRequest
	if !decodeString(fields["roomId"], &result.RoomID) || !decodeString(fields["hostPlayerId"], &result.HostPlayerID) || !decodeString(fields["hostNickname"], &result.HostNickname) || !decodeString(fields["roomKey"], &result.RoomKey) || !decodeString(fields["tokenPepper"], &result.TokenPepper) || !decodeString(fields["hostResumeToken"], &result.HostResumeToken) {
		return createRoomRequest{}, ErrInvalidConfiguration
	}
	joinExpiresAt, err := canonicalPositiveInteger(fields["joinExpiresAt"])
	if err != nil {
		return createRoomRequest{}, ErrInvalidConfiguration
	}
	result.JoinExpiresAt = joinExpiresAt
	return result, nil
}

func exactObject(data []byte, expected []string) (map[string]json.RawMessage, error) {
	if len(data) == 0 || len(data) > maximumJSONBytes || !utf8.Valid(data) || !boundedJSON(data) {
		return nil, ErrInvalidConfiguration
	}
	allowed := make(map[string]struct{}, len(expected))
	for _, key := range expected {
		allowed[key] = struct{}{}
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	opening, err := decoder.Token()
	if err != nil || opening != json.Delim('{') {
		return nil, ErrInvalidConfiguration
	}
	fields := make(map[string]json.RawMessage, len(expected))
	for decoder.More() {
		token, err := decoder.Token()
		key, ok := token.(string)
		if err != nil || !ok {
			return nil, ErrInvalidConfiguration
		}
		if _, ok := allowed[key]; !ok {
			return nil, ErrInvalidConfiguration
		}
		if _, duplicate := fields[key]; duplicate {
			return nil, ErrInvalidConfiguration
		}
		var raw json.RawMessage
		if decoder.Decode(&raw) != nil {
			return nil, ErrInvalidConfiguration
		}
		fields[key] = raw
	}
	closing, err := decoder.Token()
	if err != nil || closing != json.Delim('}') || len(fields) != len(expected) {
		return nil, ErrInvalidConfiguration
	}
	var trailing any
	if decoder.Decode(&trailing) != io.EOF {
		return nil, ErrInvalidConfiguration
	}
	return fields, nil
}

func boundedJSON(data []byte) bool {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	depth := 0
	for {
		token, err := decoder.Token()
		if err == io.EOF {
			return depth == 0
		}
		if err != nil {
			return false
		}
		if delimiter, ok := token.(json.Delim); ok {
			switch delimiter {
			case '{', '[':
				depth++
				if depth > maximumJSONDepth {
					return false
				}
			case '}', ']':
				depth--
				if depth < 0 {
					return false
				}
			}
		}
	}
}

func decodeString(raw json.RawMessage, target *string) bool {
	return json.Unmarshal(raw, target) == nil && *target != "" && len(*target) <= 4096 && utf8.ValidString(*target)
}

func canonicalPositiveInteger(raw json.RawMessage) (int64, error) {
	if len(raw) == 0 || len(raw) > 16 || raw[0] == '0' {
		return 0, ErrInvalidConfiguration
	}
	for _, character := range raw {
		if character < '0' || character > '9' {
			return 0, ErrInvalidConfiguration
		}
	}
	value, err := strconv.ParseInt(string(raw), 10, 64)
	if err != nil || value <= 0 || value > 9_007_199_254_740_991 {
		return 0, ErrInvalidConfiguration
	}
	return value, nil
}

func sameSecrets(left, right roomSecrets) bool {
	return left.RoomID == right.RoomID && left.HostPlayerID == right.HostPlayerID && secretEqual(left.TokenPepper, right.TokenPepper) && secretEqual(left.HostResumeToken, right.HostResumeToken)
}

func secretEqual(left, right string) bool {
	leftHash, rightHash := sha256.Sum256([]byte(left)), sha256.Sum256([]byte(right))
	return hmac.Equal(leftHash[:], rightHash[:])
}
