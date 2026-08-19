// Package testutil contains real transport helpers shared by server
// integration tests. It deliberately does not bypass HTTP or WebSocket
// serialization boundaries.
package testutil

import (
	"context"
	"encoding/json"
	"errors"
	"net/url"
	"strings"

	"github.com/coder/websocket"

	"me.zqydev/gamebox/server/internal/protocol"
)

type WebSocketClient struct {
	connection *websocket.Conn
}

func DialWebSocket(ctx context.Context, serverURL string) (*WebSocketClient, error) {
	if ctx == nil {
		return nil, errors.New("invalid websocket context")
	}
	parsed, err := url.Parse(serverURL)
	if err != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
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
	connection, _, err := websocket.Dial(ctx, parsed.String(), nil)
	if err != nil {
		return nil, err
	}
	connection.SetReadLimit(protocol.MaxMessageBytes)
	return &WebSocketClient{connection: connection}, nil
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

func (client *WebSocketClient) Close() error {
	if client == nil || client.connection == nil {
		return nil
	}
	return client.connection.Close(websocket.StatusNormalClosure, "")
}
