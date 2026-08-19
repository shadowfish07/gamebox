package matches

import (
	"bytes"
	"context"
	"errors"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestHubCloseIsIdempotentAndRejectsLateConnections(t *testing.T) {
	if err := (&Hub{}).Close(context.Background()); !errors.Is(err, ErrInvalidConfiguration) {
		t.Fatalf("unconfigured Close=%v", err)
	}
	fixture := newFixture(t)
	service := newLaunchTicketService(t, fixture, fixture.clock, bytes.NewReader(bytes.Repeat([]byte{1}, 64)))
	presence, err := NewPresence(service, fixture.clock)
	if err != nil {
		t.Fatal(err)
	}
	var logs bytes.Buffer
	hub, err := NewHubWithConfig(service, presence, fixture.clock, HubConfig{Logger: log.New(&logs, "", 0)})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := hub.Close(ctx); err != nil {
		t.Fatalf("first Close: %v", err)
	}
	if err := hub.Close(ctx); err != nil {
		t.Fatalf("second Close: %v", err)
	}

	request := httptest.NewRequest(http.MethodGet, "/v1/ws", nil)
	response := httptest.NewRecorder()
	hub.ServeHTTP(response, request)
	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("late ServeHTTP status=%d", response.Code)
	}
	if accepted := hub.register(&hubConnection{matchID: "11111111-1111-4111-8111-111111111111", userID: initiatorID}); accepted {
		t.Fatal("register accepted after Close")
	}
	if got := logs.String(); !strings.Contains(got, "event=hub_closed") || strings.Contains(got, "pepper") {
		t.Fatalf("close logs=%q", got)
	}
}
