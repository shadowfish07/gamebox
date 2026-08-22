package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"mime"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/coder/websocket"
	"github.com/google/uuid"

	"me.zqydev/gamebox/server/internal/protocol"
)

const maximumSmokeJSONBytes = 64 * 1024

type smokeInput struct {
	RoomID               string `json:"roomId"`
	Nickname             string `json:"nickname"`
	JoinAttemptID        string `json:"joinAttemptId"`
	CandidateResumeToken string `json:"candidateResumeToken"`
	RoomKey              string `json:"roomKey"`
}

func (smokeInput) String() string {
	return "smokeInput{RoomID:<id> Nickname:<redacted> JoinAttemptID:<id> CandidateResumeToken:<redacted> RoomKey:<redacted>}"
}
func (input smokeInput) GoString() string { return input.String() }

type joinResponse struct {
	SchemaVersion int    `json:"schemaVersion"`
	MatchID       string `json:"matchId"`
	GameID        string `json:"gameId"`
	PlayerID      string `json:"playerId"`
	LaunchTicket  string `json:"launchTicket"`
	ExpiresAt     int64  `json:"expiresAt"`
}

func (joinResponse) String() string {
	return "joinResponse{SchemaVersion:1 MatchID:<id> GameID:gomoku PlayerID:<id> LaunchTicket:<redacted> ExpiresAt:<time>}"
}
func (response joinResponse) GoString() string { return response.String() }

func main() {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := run(ctx, os.Args[1:], os.Stdin, os.Stdout); err != nil {
		_, _ = fmt.Fprintln(os.Stderr, "lan-smoke failed:", err.Error())
		os.Exit(1)
	}
}

func run(ctx context.Context, arguments []string, stdin io.Reader, stdout io.Writer) error {
	flags := flag.NewFlagSet("lan-smoke", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	endpoint := flags.String("endpoint", "", "")
	if flags.Parse(arguments) != nil || flags.NArg() != 0 || !validEndpoint(*endpoint) {
		return errors.New("invalid arguments")
	}
	input, err := readInput(stdin)
	if err != nil {
		return errors.New("invalid input")
	}
	client := &http.Client{
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	joined, err := join(ctx, client, *endpoint, input)
	if err != nil {
		return errors.New("join failed")
	}
	websocketClient := &http.Client{
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	connection, _, err := websocket.Dial(ctx, "ws://"+*endpoint+"/lan/v1/ws", &websocket.DialOptions{HTTPClient: websocketClient})
	if err != nil {
		return errors.New("connect failed")
	}
	defer connection.CloseNow()
	connection.SetReadLimit(protocol.MaxMessageBytes)
	connect := protocol.Envelope{
		ProtocolVersion: protocol.Version1,
		Type:            protocol.TypePlatformConnect,
		Payload: mustJSON(map[string]string{
			"launchTicket": joined.LaunchTicket,
			"resumeToken":  input.CandidateResumeToken,
		}),
	}
	if err := writeEnvelope(ctx, connection, connect); err != nil {
		return errors.New("connect failed")
	}
	connected, err := readEnvelope(ctx, connection)
	if err != nil || connected.Type != protocol.TypePlatformConnected || connected.MatchID != input.RoomID || connected.GameID != "gomoku" {
		return errors.New("invalid connected response")
	}
	snapshot, err := readEnvelope(ctx, connection)
	if err != nil || snapshot.Type != protocol.TypePlatformSnapshot || snapshot.MatchID != input.RoomID || snapshot.GameID != "gomoku" || snapshot.Revision == nil || *snapshot.Revision != 0 {
		return errors.New("invalid snapshot response")
	}
	var payload struct {
		Status string `json:"status"`
	}
	if json.Unmarshal(snapshot.Payload, &payload) != nil || payload.Status != "active" {
		return errors.New("invalid snapshot response")
	}
	return json.NewEncoder(stdout).Encode(struct {
		SchemaVersion int    `json:"schemaVersion"`
		RoomID        string `json:"roomId"`
		Revision      int64  `json:"revision"`
		State         string `json:"state"`
	}{SchemaVersion: 1, RoomID: input.RoomID, Revision: 0, State: payload.Status})
}

func readInput(reader io.Reader) (smokeInput, error) {
	data, err := io.ReadAll(io.LimitReader(reader, maximumSmokeJSONBytes+1))
	if err != nil || len(data) == 0 || len(data) > maximumSmokeJSONBytes || !utf8.Valid(data) {
		return smokeInput{}, errors.New("invalid input")
	}
	fields, err := exactObject(data, []string{"roomId", "nickname", "joinAttemptId", "candidateResumeToken", "roomKey"})
	if err != nil {
		return smokeInput{}, err
	}
	_ = fields
	var input smokeInput
	if json.Unmarshal(data, &input) != nil || !canonicalUUID(input.RoomID) || !canonicalUUID(input.JoinAttemptID) ||
		strings.TrimSpace(input.Nickname) == "" || len(input.Nickname) > 128 ||
		!canonicalToken(input.CandidateResumeToken) || !canonicalToken(input.RoomKey) {
		return smokeInput{}, errors.New("invalid input")
	}
	return input, nil
}

func join(ctx context.Context, client *http.Client, endpoint string, input smokeInput) (joinResponse, error) {
	body, err := json.Marshal(input)
	if err != nil {
		return joinResponse{}, err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, "http://"+endpoint+"/lan/v1/rooms/"+input.RoomID+"/join", bytes.NewReader(body))
	if err != nil {
		return joinResponse{}, err
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := client.Do(request)
	if err != nil {
		return joinResponse{}, err
	}
	defer response.Body.Close()
	mediaType, parameters, mediaErr := mime.ParseMediaType(response.Header.Get("Content-Type"))
	if response.StatusCode != http.StatusOK || mediaErr != nil || mediaType != "application/json" ||
		len(parameters) != 1 || strings.ToLower(parameters["charset"]) != "utf-8" {
		return joinResponse{}, errors.New("join failed")
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, maximumSmokeJSONBytes+1))
	if err != nil || len(data) == 0 || len(data) > maximumSmokeJSONBytes {
		return joinResponse{}, errors.New("join failed")
	}
	if _, err := exactObject(data, []string{"schemaVersion", "matchId", "gameId", "playerId", "launchTicket", "expiresAt"}); err != nil {
		return joinResponse{}, errors.New("join failed")
	}
	var joined joinResponse
	if json.Unmarshal(data, &joined) != nil || joined.SchemaVersion != 1 || joined.MatchID != input.RoomID || joined.GameID != "gomoku" ||
		!canonicalUUID(joined.PlayerID) || !canonicalToken(joined.LaunchTicket) || joined.ExpiresAt <= 0 {
		return joinResponse{}, errors.New("join failed")
	}
	return joined, nil
}

func exactObject(data []byte, expected []string) (map[string]json.RawMessage, error) {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	token, err := decoder.Token()
	if err != nil || token != json.Delim('{') {
		return nil, errors.New("invalid json")
	}
	allowed := make(map[string]struct{}, len(expected))
	for _, field := range expected {
		allowed[field] = struct{}{}
	}
	fields := make(map[string]json.RawMessage, len(expected))
	for decoder.More() {
		keyToken, err := decoder.Token()
		key, ok := keyToken.(string)
		if err != nil || !ok {
			return nil, errors.New("invalid json")
		}
		if _, ok := allowed[key]; !ok {
			return nil, errors.New("invalid json")
		}
		if _, duplicate := fields[key]; duplicate {
			return nil, errors.New("invalid json")
		}
		var raw json.RawMessage
		if decoder.Decode(&raw) != nil {
			return nil, errors.New("invalid json")
		}
		fields[key] = raw
	}
	closing, err := decoder.Token()
	if err != nil || closing != json.Delim('}') || len(fields) != len(expected) {
		return nil, errors.New("invalid json")
	}
	var trailing any
	if decoder.Decode(&trailing) != io.EOF {
		return nil, errors.New("invalid json")
	}
	return fields, nil
}

func validEndpoint(endpoint string) bool {
	host, rawPort, err := net.SplitHostPort(endpoint)
	if err != nil || host != "127.0.0.1" {
		return false
	}
	port, err := strconv.Atoi(rawPort)
	return err == nil && port >= 1 && port <= 65535 && endpoint == "127.0.0.1:"+strconv.Itoa(port)
}

func canonicalUUID(value string) bool {
	parsed, err := uuid.Parse(value)
	return err == nil && parsed.String() == value && parsed.Variant() == uuid.RFC4122
}

func canonicalToken(value string) bool {
	decoded, err := base64.RawURLEncoding.Strict().DecodeString(value)
	return err == nil && len(decoded) == 32 && base64.RawURLEncoding.EncodeToString(decoded) == value
}

func mustJSON(value any) json.RawMessage {
	encoded, _ := json.Marshal(value)
	return encoded
}

func writeEnvelope(ctx context.Context, connection *websocket.Conn, envelope protocol.Envelope) error {
	data, err := json.Marshal(envelope)
	if err != nil {
		return err
	}
	return connection.Write(ctx, websocket.MessageText, data)
}

func readEnvelope(ctx context.Context, connection *websocket.Conn) (protocol.Envelope, error) {
	messageType, data, err := connection.Read(ctx)
	if err != nil || messageType != websocket.MessageText {
		return protocol.Envelope{}, errors.New("invalid websocket response")
	}
	return protocol.Decode(data)
}
