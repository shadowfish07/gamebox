package httpapi

import (
	"context"
	"database/sql"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
)

func TestHubCloseTerminatesActiveWebSocketPersistsOfflineAndRejectsLateDial(t *testing.T) {
	fixture := newAPIFixture(t)
	client := openFixtureWebSocket(t, fixture, "hub-close")

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := fixture.hub.Close(ctx); err != nil {
		t.Fatalf("Close: %v", err)
	}
	readContext, cancelRead := context.WithTimeout(context.Background(), time.Second)
	_, _, readErr := client.connection.Read(readContext)
	cancelRead()
	if readErr == nil || fixture.presence.IsOnline(client.matchID, client.userID) {
		t.Fatalf("active connection survived Close: readErr=%v online=%t", readErr, fixture.presence.IsOnline(client.matchID, client.userID))
	}
	var offlineSince sql.NullInt64
	if err := fixture.db.QueryRow(`SELECT both_offline_since FROM matches WHERE id=?`, client.matchID).Scan(&offlineSince); err != nil || !offlineSince.Valid {
		t.Fatalf("offline boundary=%v err=%v", offlineSince, err)
	}

	server := httptest.NewServer(fixture.handler)
	defer server.Close()
	dialContext, cancelDial := context.WithTimeout(context.Background(), time.Second)
	late, response, dialErr := websocket.Dial(dialContext, "ws"+strings.TrimPrefix(server.URL, "http")+"/v1/ws", nil)
	cancelDial()
	if late != nil {
		_ = late.CloseNow()
	}
	if dialErr == nil || response == nil || response.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("late dial=(connection=%v response=%v err=%v)", late, response, dialErr)
	}
	_ = response.Body.Close()

	alreadyCanceled, cancelAlready := context.WithCancel(context.Background())
	cancelAlready()
	if err := fixture.hub.Close(alreadyCanceled); err != nil {
		t.Fatalf("completed idempotent Close with canceled context: %v", err)
	}
}
