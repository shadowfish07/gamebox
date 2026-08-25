// Package testutil contains real transport helpers shared by server
// integration tests. It deliberately does not bypass HTTP or WebSocket
// serialization boundaries.
package testutil

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/google/uuid"

	"me.zqydev/gamebox/server/internal/games/gomoku"
	"me.zqydev/gamebox/server/internal/protocol"
	"me.zqydev/gamebox/server/internal/users"
)

const maximumTestResponseBytes int64 = 64 * 1024

type User struct {
	ID       string `json:"id"`
	Nickname string `json:"nickname"`
}

type Session struct {
	User             User   `json:"user"`
	AccessToken      string `json:"accessToken"`
	AccessExpiresAt  int64  `json:"accessExpiresAt"`
	RefreshToken     string `json:"refreshToken"`
	RefreshExpiresAt int64  `json:"refreshExpiresAt"`
}

type CreatedMatch struct {
	ID     string `json:"id"`
	GameID string `json:"gameId"`
	State  string `json:"state"`
}

type LaunchTicket struct {
	MatchID      string `json:"matchId"`
	GameID       string `json:"gameId"`
	LaunchTicket string `json:"launchTicket"`
	ExpiresAt    int64  `json:"expiresAt"`
}

type ActiveMatch struct {
	ID       string `json:"id"`
	Opponent User   `json:"opponent"`
	Color    string `json:"color"`
	Revision int64  `json:"revision"`
}

type GomokuStatus struct {
	State string       `json:"state"`
	Match *ActiveMatch `json:"match,omitempty"`
}

// APIError contains only the server's stable public error envelope. Request
// bodies and credentials are intentionally never retained or formatted.
type APIError struct {
	Status  int
	Code    string
	Message string
}

func (failure *APIError) Error() string {
	if failure == nil {
		return "api request failed"
	}
	return fmt.Sprintf("api request failed: status=%d code=%s", failure.Status, failure.Code)
}

type APIClient struct {
	baseURL string
	client  *http.Client
}

func NewAPIClient(baseURL string, transport *http.Client) (*APIClient, error) {
	parsed, err := url.Parse(baseURL)
	if err != nil || parsed.User != nil || parsed.Host == "" || parsed.Path != "" || parsed.RawQuery != "" || parsed.Fragment != "" || (parsed.Scheme != "http" && parsed.Scheme != "https") {
		return nil, errors.New("invalid api base url")
	}
	if transport == nil {
		return nil, errors.New("invalid api transport")
	}
	client := &http.Client{Transport: transport.Transport, CheckRedirect: transport.CheckRedirect, Jar: transport.Jar, Timeout: 10 * time.Second}
	return &APIClient{baseURL: strings.TrimSuffix(baseURL, "/"), client: client}, nil
}

func (client *APIClient) Register(ctx context.Context, inviteCode, nickname string) (Session, error) {
	var response struct {
		Session Session `json:"session"`
	}
	if err := client.doJSON(ctx, http.MethodPost, "/v1/auth/register", "", struct {
		InviteCode string `json:"inviteCode"`
		Nickname   string `json:"nickname"`
	}{InviteCode: inviteCode, Nickname: nickname}, http.StatusCreated, &response); err != nil {
		return Session{}, err
	}
	expectedNickname, _, normalizeErr := users.NormalizeNickname(nickname)
	if normalizeErr != nil || !canonicalUUID(response.Session.User.ID) || response.Session.User.Nickname != expectedNickname || response.Session.AccessToken == "" || response.Session.RefreshToken == "" || response.Session.AccessExpiresAt <= 0 || response.Session.RefreshExpiresAt <= response.Session.AccessExpiresAt {
		return Session{}, errors.New("invalid registration response")
	}
	return response.Session, nil
}

func (client *APIClient) Me(ctx context.Context, accessToken string) (User, error) {
	var response struct {
		User User `json:"user"`
	}
	if err := client.doJSON(ctx, http.MethodGet, "/v1/me", accessToken, nil, http.StatusOK, &response); err != nil {
		return User{}, err
	}
	if !canonicalUUID(response.User.ID) || response.User.Nickname == "" {
		return User{}, errors.New("invalid me response")
	}
	return response.User, nil
}

func (client *APIClient) CreateGomokuMatch(ctx context.Context, accessToken, opponentID string) (CreatedMatch, error) {
	if !canonicalUUID(opponentID) {
		return CreatedMatch{}, errors.New("invalid opponent id")
	}
	var response struct {
		Match CreatedMatch `json:"match"`
	}
	if err := client.doJSON(ctx, http.MethodPost, "/v1/games/gomoku/matches", accessToken, struct {
		OpponentID string `json:"opponentId"`
	}{OpponentID: opponentID}, http.StatusCreated, &response); err != nil {
		return CreatedMatch{}, err
	}
	if !canonicalUUID(response.Match.ID) || response.Match.GameID != gomoku.GameID || response.Match.State != "active" {
		return CreatedMatch{}, errors.New("invalid create match response")
	}
	return response.Match, nil
}

func (client *APIClient) CreateLaunchTicket(ctx context.Context, accessToken, matchID string) (LaunchTicket, error) {
	if !canonicalUUID(matchID) {
		return LaunchTicket{}, errors.New("invalid match id")
	}
	var response LaunchTicket
	if err := client.doJSON(ctx, http.MethodPost, "/v1/matches/"+matchID+"/launch-ticket", accessToken, struct{}{}, http.StatusCreated, &response); err != nil {
		return LaunchTicket{}, err
	}
	if response.MatchID != matchID || response.GameID != gomoku.GameID || !validOpaqueToken(response.LaunchTicket) || response.ExpiresAt <= 0 {
		return LaunchTicket{}, errors.New("invalid launch ticket response")
	}
	return response, nil
}

func (client *APIClient) GomokuStatus(ctx context.Context, accessToken string) (GomokuStatus, error) {
	var response GomokuStatus
	if err := client.doJSON(ctx, http.MethodGet, "/v1/games/gomoku/status", accessToken, nil, http.StatusOK, &response); err != nil {
		return GomokuStatus{}, err
	}
	switch response.State {
	case "idle":
		if response.Match != nil {
			return GomokuStatus{}, errors.New("invalid idle status response")
		}
	case "active":
		if response.Match == nil || !canonicalUUID(response.Match.ID) || !canonicalUUID(response.Match.Opponent.ID) || response.Match.Opponent.Nickname == "" || (response.Match.Color != "black" && response.Match.Color != "white") || response.Match.Revision < 0 {
			return GomokuStatus{}, errors.New("invalid active status response")
		}
	default:
		return GomokuStatus{}, errors.New("invalid status response")
	}
	return response, nil
}

func (client *APIClient) doJSON(ctx context.Context, method, path, accessToken string, requestBody any, wantStatus int, destination any) error {
	if client == nil || client.client == nil || ctx == nil || ctx.Err() != nil || !strings.HasPrefix(path, "/") || strings.ContainsAny(path, "?#") {
		return errors.New("invalid api request")
	}
	var body io.Reader
	if requestBody != nil {
		encoded, err := json.Marshal(requestBody)
		if err != nil || int64(len(encoded)) > maximumTestResponseBytes {
			return errors.New("invalid api request body")
		}
		body = bytes.NewReader(encoded)
	}
	request, err := http.NewRequestWithContext(ctx, method, client.baseURL+path, body)
	if err != nil {
		return errors.New("invalid api request")
	}
	if requestBody != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	if accessToken != "" {
		request.Header.Set("Authorization", "Bearer "+accessToken)
	}
	response, err := client.client.Do(request)
	if err != nil {
		return fmt.Errorf("api transport failed: %w", err)
	}
	defer response.Body.Close()
	data, err := io.ReadAll(io.LimitReader(response.Body, maximumTestResponseBytes+1))
	if err != nil || int64(len(data)) > maximumTestResponseBytes {
		return errors.New("invalid api response")
	}
	if err := validateJSONContentType(response.Header.Get("Content-Type")); err != nil {
		return err
	}
	if response.StatusCode != wantStatus {
		return decodeAPIError(response.StatusCode, data)
	}
	if destination == nil || decodeStrictJSON(data, destination) != nil {
		return errors.New("invalid api response")
	}
	return nil
}

func validateJSONContentType(value string) error {
	mediaType, parameters, err := mime.ParseMediaType(value)
	if err != nil || mediaType != "application/json" || len(parameters) > 1 {
		return errors.New("invalid api response content type")
	}
	if charset, exists := parameters["charset"]; exists && !strings.EqualFold(charset, "utf-8") {
		return errors.New("invalid api response content type")
	}
	return nil
}

func decodeAPIError(status int, data []byte) error {
	var response struct {
		Error struct {
			Code    string         `json:"code"`
			Message string         `json:"message"`
			Details map[string]any `json:"details"`
		} `json:"error"`
	}
	if decodeStrictJSON(data, &response) != nil || response.Error.Code == "" || response.Error.Message == "" || response.Error.Details == nil {
		return errors.New("invalid api error response")
	}
	return &APIError{Status: status, Code: response.Error.Code, Message: response.Error.Message}
}

func decodeStrictJSON(data []byte, destination any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(destination); err != nil {
		return err
	}
	var extra any
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		return errors.New("trailing json data")
	}
	return nil
}

type Connected struct {
	UserID          string           `json:"userId"`
	ConnectionID    string           `json:"connectionId"`
	ResumeToken     string           `json:"resumeToken"`
	ResumeExpiresAt int64            `json:"resumeExpiresAt"`
	Players         []PlayerPresence `json:"players"`
}

type PlayerPresence struct {
	UserID string `json:"userId"`
	Online bool   `json:"online"`
}

type GomokuSnapshot struct {
	GameID       string                                     `json:"gameId"`
	MatchID      string                                     `json:"matchId"`
	Revision     int64                                      `json:"revision"`
	Status       string                                     `json:"status"`
	Board        [gomoku.BoardSize * gomoku.BoardSize]uint8 `json:"board"`
	BoardSize    int                                        `json:"boardSize"`
	BlackUserID  string                                     `json:"blackUserId"`
	WhiteUserID  string                                     `json:"whiteUserId"`
	NextColor    string                                     `json:"nextColor"`
	WinnerUserID *string                                    `json:"winnerUserId"`
	Result       *string                                    `json:"result"`
}

type WebSocketHandshake struct {
	Connected Connected
	Snapshot  GomokuSnapshot
}

type WebSocketError struct {
	Code    string
	Message string
}

func (failure *WebSocketError) Error() string {
	if failure == nil {
		return "websocket request failed"
	}
	return "websocket request failed: code=" + failure.Code
}

type WebSocketClient struct {
	connection       *websocket.Conn
	closeOnce        sync.Once
	abortOnce        sync.Once
	onHandshakeStart func() bool
	onHandshakeDone  func()
	onConnected      func(matchID, userID string)
}

func DialWebSocket(ctx context.Context, serverURL string) (*WebSocketClient, error) {
	if ctx == nil {
		return nil, errors.New("invalid websocket context")
	}
	parsed, err := url.Parse(serverURL)
	if err != nil || parsed.User != nil || parsed.Host == "" || parsed.RawQuery != "" || parsed.Fragment != "" {
		return nil, errors.New("invalid websocket server url")
	}
	switch strings.ToLower(parsed.Scheme) {
	case "http":
		parsed.Scheme = "ws"
	case "https":
		parsed.Scheme = "wss"
	case "ws", "wss":
	default:
		return nil, errors.New("invalid websocket server url")
	}
	parsed.Path = "/v1/ws"
	connection, response, err := websocket.Dial(ctx, parsed.String(), nil)
	if response != nil && response.Body != nil {
		_ = response.Body.Close()
	}
	if err != nil {
		return nil, err
	}
	connection.SetReadLimit(protocol.MaxMessageBytes)
	return &WebSocketClient{connection: connection}, nil
}

func (client *WebSocketClient) ConnectLaunch(ctx context.Context, launchTicket string) (WebSocketHandshake, error) {
	return client.connect(ctx, "launchTicket", launchTicket)
}

func (client *WebSocketClient) ConnectResume(ctx context.Context, resumeToken string) (WebSocketHandshake, error) {
	return client.connect(ctx, "resumeToken", resumeToken)
}

func (client *WebSocketClient) connect(ctx context.Context, credentialName, credential string) (WebSocketHandshake, error) {
	if !validOpaqueToken(credential) || (credentialName != "launchTicket" && credentialName != "resumeToken") {
		return WebSocketHandshake{}, errors.New("invalid websocket credential")
	}
	payload, err := json.Marshal(map[string]any{
		credentialName: credential,
		"capabilities": []string{protocol.CapabilityPlayerPresence},
	})
	if err != nil {
		return WebSocketHandshake{}, errors.New("invalid websocket credential")
	}
	if client.onHandshakeStart != nil && !client.onHandshakeStart() {
		return WebSocketHandshake{}, errors.New("websocket client is closing")
	}
	if client.onHandshakeDone != nil {
		defer client.onHandshakeDone()
	}
	if err := client.WriteEnvelope(ctx, protocol.Envelope{ProtocolVersion: protocol.Version1, Type: protocol.TypePlatformConnect, Payload: payload}); err != nil {
		return WebSocketHandshake{}, err
	}
	first, err := client.ReadEnvelope(ctx)
	if err != nil {
		return WebSocketHandshake{}, err
	}
	if first.Type == protocol.TypePlatformError {
		return WebSocketHandshake{}, decodeWebSocketError(first)
	}
	if first.Type != protocol.TypePlatformConnected || first.Revision == nil || first.GameID != gomoku.GameID || !canonicalUUID(first.MatchID) {
		return WebSocketHandshake{}, errors.New("invalid websocket connected response")
	}
	var connected Connected
	if decodeStrictJSON(first.Payload, &connected) != nil || !canonicalUUID(connected.UserID) || !canonicalUUID(connected.ConnectionID) || !validOpaqueToken(connected.ResumeToken) || connected.ResumeExpiresAt <= 0 || !validPlayerPresences(connected.Players, connected.UserID) {
		return WebSocketHandshake{}, errors.New("invalid websocket connected response")
	}
	snapshotEnvelope, err := client.ReadEnvelope(ctx)
	if err != nil {
		return WebSocketHandshake{}, err
	}
	snapshot, err := DecodeGomokuSnapshot(snapshotEnvelope)
	if err != nil || snapshot.MatchID != first.MatchID || snapshot.Revision != *first.Revision {
		return WebSocketHandshake{}, errors.New("invalid websocket initial snapshot")
	}
	if client.onConnected != nil {
		client.onConnected(snapshot.MatchID, connected.UserID)
	}
	return WebSocketHandshake{Connected: connected, Snapshot: snapshot}, nil
}

func validPlayerPresences(players []PlayerPresence, localUserID string) bool {
	if len(players) == 0 || len(players) > 64 {
		return false
	}
	seen := make(map[string]struct{}, len(players))
	for _, player := range players {
		if !canonicalUUID(player.UserID) {
			return false
		}
		if _, duplicate := seen[player.UserID]; duplicate {
			return false
		}
		seen[player.UserID] = struct{}{}
	}
	_, includesLocal := seen[localUserID]
	return includesLocal
}

func (client *WebSocketClient) WriteEnvelope(ctx context.Context, envelope protocol.Envelope) error {
	if client == nil || client.connection == nil || ctx == nil {
		return errors.New("invalid websocket client")
	}
	data, err := json.Marshal(envelope)
	if err != nil || len(data) > protocol.MaxMessageBytes {
		return errors.New("invalid websocket envelope")
	}
	return client.connection.Write(ctx, websocket.MessageText, data)
}

func (client *WebSocketClient) SendMove(ctx context.Context, matchID, actionID string, expectedRevision int64, x, y int) error {
	if !canonicalUUID(matchID) || !canonicalUUID(actionID) || expectedRevision < 0 {
		return errors.New("invalid gomoku move")
	}
	payload, err := json.Marshal(struct {
		X int `json:"x"`
		Y int `json:"y"`
	}{X: x, Y: y})
	if err != nil {
		return errors.New("invalid gomoku move")
	}
	revision := expectedRevision
	return client.WriteEnvelope(ctx, protocol.Envelope{
		ProtocolVersion: protocol.Version1, GameID: gomoku.GameID, MatchID: matchID,
		ExpectedRevision: &revision, Type: protocol.TypeGomokuMoveRequested, ActionID: actionID, Payload: payload,
	})
}

func (client *WebSocketClient) RequestSnapshot(ctx context.Context, matchID string, currentRevision int64) error {
	if !canonicalUUID(matchID) || currentRevision < 0 {
		return errors.New("invalid snapshot request")
	}
	payload, err := json.Marshal(struct {
		CurrentRevision int64 `json:"currentRevision"`
	}{CurrentRevision: currentRevision})
	if err != nil {
		return errors.New("invalid snapshot request")
	}
	return client.WriteEnvelope(ctx, protocol.Envelope{
		ProtocolVersion: protocol.Version1, GameID: gomoku.GameID, MatchID: matchID,
		Type: protocol.TypePlatformSnapshotRequested, Payload: payload,
	})
}

func (client *WebSocketClient) ReadEnvelope(ctx context.Context) (protocol.Envelope, error) {
	if client == nil || client.connection == nil || ctx == nil {
		return protocol.Envelope{}, errors.New("invalid websocket client")
	}
	messageType, data, err := client.connection.Read(ctx)
	if err != nil {
		return protocol.Envelope{}, err
	}
	if messageType != websocket.MessageText {
		return protocol.Envelope{}, errors.New("unexpected websocket message type")
	}
	return protocol.Decode(data)
}

func (client *WebSocketClient) ReadSnapshot(ctx context.Context) (GomokuSnapshot, error) {
	envelope, err := client.ReadEnvelope(ctx)
	if err != nil {
		return GomokuSnapshot{}, err
	}
	return DecodeGomokuSnapshot(envelope)
}

func DecodeGomokuSnapshot(envelope protocol.Envelope) (GomokuSnapshot, error) {
	if envelope.Type != protocol.TypePlatformSnapshot || envelope.Revision == nil || envelope.GameID != gomoku.GameID || !canonicalUUID(envelope.MatchID) {
		return GomokuSnapshot{}, errors.New("invalid gomoku snapshot envelope")
	}
	snapshot, err := decodeGomokuSnapshotPayload(envelope.Payload)
	if err != nil {
		return GomokuSnapshot{}, errors.New("invalid gomoku snapshot payload")
	}
	snapshot.GameID, snapshot.MatchID, snapshot.Revision = envelope.GameID, envelope.MatchID, *envelope.Revision
	if snapshot.BoardSize != gomoku.BoardSize || !canonicalUUID(snapshot.BlackUserID) || !canonicalUUID(snapshot.WhiteUserID) || snapshot.BlackUserID == snapshot.WhiteUserID || (snapshot.NextColor != "black" && snapshot.NextColor != "white") {
		return GomokuSnapshot{}, errors.New("invalid gomoku snapshot payload")
	}
	for _, cell := range snapshot.Board {
		if cell > 2 {
			return GomokuSnapshot{}, errors.New("invalid gomoku snapshot payload")
		}
	}
	switch snapshot.Status {
	case "active":
		if snapshot.Result != nil || snapshot.WinnerUserID != nil {
			return GomokuSnapshot{}, errors.New("invalid gomoku active snapshot")
		}
	case "finished":
		if snapshot.Result == nil || (*snapshot.Result != "five" && *snapshot.Result != "draw" && *snapshot.Result != "resignation") {
			return GomokuSnapshot{}, errors.New("invalid gomoku terminal snapshot")
		}
		if *snapshot.Result == "draw" && snapshot.WinnerUserID != nil || *snapshot.Result != "draw" && (snapshot.WinnerUserID == nil || (*snapshot.WinnerUserID != snapshot.BlackUserID && *snapshot.WinnerUserID != snapshot.WhiteUserID)) {
			return GomokuSnapshot{}, errors.New("invalid gomoku terminal snapshot")
		}
	default:
		return GomokuSnapshot{}, errors.New("invalid gomoku snapshot status")
	}
	return snapshot, nil
}

func decodeGomokuSnapshotPayload(data []byte) (GomokuSnapshot, error) {
	var payload struct {
		Status       json.RawMessage `json:"status"`
		Board        json.RawMessage `json:"board"`
		BoardSize    json.RawMessage `json:"boardSize"`
		BlackUserID  json.RawMessage `json:"blackUserId"`
		WhiteUserID  json.RawMessage `json:"whiteUserId"`
		NextColor    json.RawMessage `json:"nextColor"`
		WinnerUserID json.RawMessage `json:"winnerUserId"`
		Result       json.RawMessage `json:"result"`
	}
	if decodeStrictJSON(data, &payload) != nil {
		return GomokuSnapshot{}, errors.New("invalid snapshot object")
	}
	for _, required := range []json.RawMessage{
		payload.Status, payload.Board, payload.BoardSize, payload.BlackUserID,
		payload.WhiteUserID, payload.NextColor, payload.WinnerUserID, payload.Result,
	} {
		if len(required) == 0 {
			return GomokuSnapshot{}, errors.New("missing snapshot field")
		}
	}
	var snapshot GomokuSnapshot
	var board []uint8
	if decodeStrictJSON(payload.Status, &snapshot.Status) != nil ||
		decodeStrictJSON(payload.Board, &board) != nil || len(board) != len(snapshot.Board) ||
		decodeStrictJSON(payload.BoardSize, &snapshot.BoardSize) != nil ||
		decodeStrictJSON(payload.BlackUserID, &snapshot.BlackUserID) != nil ||
		decodeStrictJSON(payload.WhiteUserID, &snapshot.WhiteUserID) != nil ||
		decodeStrictJSON(payload.NextColor, &snapshot.NextColor) != nil ||
		decodeStrictJSON(payload.WinnerUserID, &snapshot.WinnerUserID) != nil ||
		decodeStrictJSON(payload.Result, &snapshot.Result) != nil {
		return GomokuSnapshot{}, errors.New("invalid snapshot field")
	}
	copy(snapshot.Board[:], board)
	return snapshot, nil
}

func decodeWebSocketError(envelope protocol.Envelope) error {
	var payload struct {
		Code    string         `json:"code"`
		Message string         `json:"message"`
		Details map[string]any `json:"details"`
	}
	if decodeStrictJSON(envelope.Payload, &payload) != nil || payload.Code == "" || payload.Message == "" || payload.Details == nil {
		return errors.New("invalid websocket error response")
	}
	return &WebSocketError{Code: payload.Code, Message: payload.Message}
}

func (client *WebSocketClient) Close() error {
	if client == nil || client.connection == nil {
		return nil
	}
	var closeErr error
	client.closeOnce.Do(func() {
		closeErr = client.connection.Close(websocket.StatusNormalClosure, "")
	})
	return closeErr
}

func (client *WebSocketClient) closeNow() {
	if client == nil || client.connection == nil {
		return
	}
	client.abortOnce.Do(func() { _ = client.connection.CloseNow() })
}

func canonicalUUID(value string) bool {
	parsed, err := uuid.Parse(value)
	return err == nil && parsed.String() == value && parsed.Variant() == uuid.RFC4122
}

func validOpaqueToken(value string) bool {
	if value == "" || strings.ContainsAny(value, " \t\r\n") {
		return false
	}
	decoded, err := base64.RawURLEncoding.DecodeString(value)
	return err == nil && len(decoded) == 32 && base64.RawURLEncoding.EncodeToString(decoded) == value
}
