package matches

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"me.zqydev/gamebox/server/internal/games/gomoku"
	"me.zqydev/gamebox/server/internal/protocol"
)

type transferDuringConnectStore struct {
	PresenceStore
	beforeRegistration func(context.Context) error
}

func (s transferDuringConnectStore) SetPlayerOnline(ctx context.Context, matchID, userID string) error {
	if err := s.PresenceStore.SetPlayerOnline(ctx, matchID, userID); err != nil {
		return err
	}
	return s.beforeRegistration(ctx)
}

func TestHubRevalidatesTransferBeforeSendingInitialState(t *testing.T) {
	for _, transfer := range []bool{false, true} {
		name := "current_session"
		if transfer {
			name = "transfer_before_registration"
		}
		t.Run(name, func(t *testing.T) {
			f := newFixture(t)
			service := newLaunchTicketService(t, f, f.clock, bytes.NewReader(bytes.Repeat([]byte{1}, 256)))
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			match, err := service.Create(ctx, gomoku.GameID, initiatorID, opponentID)
			if err != nil {
				t.Fatal(err)
			}
			ticket, err := service.CreateLaunchTicket(ctx, match.ID, initiatorID)
			if err != nil {
				t.Fatal(err)
			}
			var hub *Hub
			presence, err := NewPresence(transferDuringConnectStore{
				PresenceStore: service,
				beforeRegistration: func(ctx context.Context) error {
					if !transfer {
						return nil
					}
					// Authentication has completed, but the revocation sweep cannot
					// see this transport until ServeHTTP registers it in the hub.
					if _, err := f.db.ExecContext(ctx, `UPDATE users SET auth_epoch='transferred' WHERE id=?`, initiatorID); err != nil {
						return err
					}
					hub.DisconnectRevokedUser(ctx, initiatorID)
					return nil
				},
			}, f.clock)
			if err != nil {
				t.Fatal(err)
			}
			hub, err = NewHub(service, presence, f.clock)
			if err != nil {
				t.Fatal(err)
			}
			done := make(chan struct{})
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				defer close(done)
				hub.ServeHTTP(w, r)
			}))
			defer server.Close()
			ws, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(server.URL, "http"), nil)
			if err != nil {
				t.Fatal(err)
			}
			defer ws.CloseNow()
			message, _ := json.Marshal(map[string]any{
				"protocolVersion": 1, "type": protocol.TypePlatformConnect,
				"payload": map[string]string{"launchTicket": ticket.Token},
			})
			if err := ws.Write(ctx, websocket.MessageText, message); err != nil {
				t.Fatal(err)
			}
			for _, want := range []string{protocol.TypePlatformConnected, protocol.TypePlatformSnapshot} {
				_, data, err := ws.Read(ctx)
				if transfer {
					if err == nil {
						t.Fatal("revoked session received an initial message")
					}
					break
				}
				var envelope protocol.Envelope
				if err != nil || json.Unmarshal(data, &envelope) != nil || envelope.Type != want {
					t.Fatalf("current session did not receive %s: %v", want, err)
				}
			}
			ws.CloseNow()
			select {
			case <-done:
			case <-ctx.Done():
				t.Fatal("connection handler did not stop")
			}
			hub.mu.Lock()
			remaining := len(hub.matches)
			hub.mu.Unlock()
			if remaining != 0 {
				t.Fatal("closed connection retained in hub")
			}
		})
	}
}
