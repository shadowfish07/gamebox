// Package httpapi exposes one authoritative LAN room over strict HTTP and
// WebSocket boundaries without depending on public identity or match services.
package httpapi

import (
	"context"
	"net/http"
	"path"
	"reflect"
	"strings"

	"me.zqydev/gamebox/server/internal/lan/room"
)

type RoomService interface {
	Join(context.Context, room.JoinRequest) (room.JoinedPlayer, error)
	IssueLaunch(context.Context, string, string) (room.LaunchTicket, error)
	ConnectLAN(context.Context, room.ConnectCredential) (room.ConnectionCredential, error)
	Apply(context.Context, room.ActionRequest) (room.Event, room.Snapshot, *room.GameResult, error)
	AcknowledgeResult(context.Context, string, string) error
	Snapshot() room.Snapshot
}

type Router struct {
	service RoomService
	mux     *http.ServeMux
	hub     *Hub
}

func NewRouter(service RoomService) (*Router, error) {
	if nilInterface(service) {
		return nil, room.ErrInvalidConfiguration
	}
	hub, err := NewHub(service)
	if err != nil {
		return nil, err
	}
	router := &Router{service: service, hub: hub}
	mux := http.NewServeMux()
	mux.HandleFunc("POST /lan/v1/rooms/{roomId}/join", router.join)
	mux.HandleFunc("POST /lan/v1/rooms/{roomId}/resume-ticket", router.resumeTicket)
	mux.HandleFunc("GET /lan/v1/rooms/{roomId}/result", router.result)
	mux.HandleFunc("HEAD /lan/v1/rooms/{roomId}/result", methodNotAllowed(http.MethodGet))
	mux.HandleFunc("POST /lan/v1/rooms/{roomId}/result-ack", router.resultAck)
	mux.HandleFunc("GET /lan/v1/ws", router.webSocket)
	registerMethodFallback(mux, "/lan/v1/rooms/{roomId}/join", http.MethodPost)
	registerMethodFallback(mux, "/lan/v1/rooms/{roomId}/resume-ticket", http.MethodPost)
	registerMethodFallback(mux, "/lan/v1/rooms/{roomId}/result", http.MethodGet)
	registerMethodFallback(mux, "/lan/v1/rooms/{roomId}/result-ack", http.MethodPost)
	registerMethodFallback(mux, "/lan/v1/ws", http.MethodGet)
	mux.HandleFunc("/", func(writer http.ResponseWriter, _ *http.Request) {
		writeAPIError(writer, http.StatusNotFound, "invalid_request")
	})
	router.mux = mux
	return router, nil
}

func (router *Router) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	if router == nil || router.mux == nil || request == nil {
		writeAPIError(writer, http.StatusServiceUnavailable, "internal_error")
		return
	}
	cleaned := path.Clean(request.URL.Path)
	if request.URL.RawQuery != "" || cleaned != request.URL.Path || strings.Contains(request.URL.EscapedPath(), "%2f") || strings.Contains(request.URL.EscapedPath(), "%2F") {
		writeAPIError(writer, http.StatusBadRequest, "invalid_request")
		return
	}
	router.mux.ServeHTTP(writer, request)
}

func (router *Router) Close(ctx context.Context) error {
	if router == nil || router.hub == nil {
		return nil
	}
	return router.hub.Close(ctx)
}

// PublishCommitted delivers an event already durably committed through the
// authoritative RoomService. It is the narrow boundary used by local Android
// host actions so they share the hub's revision ordering and slow-client rules
// with WebSocket actions.
func (router *Router) PublishCommitted(event room.Event) error {
	if router == nil || router.hub == nil || event.RoomID == "" || event.Revision <= 0 {
		return room.ErrInvalidRequest
	}
	router.hub.publish(event)
	return nil
}

func (router *Router) webSocket(writer http.ResponseWriter, request *http.Request) {
	if request.ContentLength != 0 || len(request.TransferEncoding) != 0 || request.Header.Get("Authorization") != "" || request.Header.Get("Cookie") != "" {
		writeAPIError(writer, http.StatusBadRequest, "invalid_request")
		return
	}
	router.hub.ServeHTTP(writer, request)
}

func registerMethodFallback(mux *http.ServeMux, pattern, allow string) {
	mux.HandleFunc(pattern, methodNotAllowed(allow))
}

func methodNotAllowed(allow string) http.HandlerFunc {
	return func(writer http.ResponseWriter, _ *http.Request) {
		writer.Header().Set("Allow", allow)
		writeAPIError(writer, http.StatusMethodNotAllowed, "method_not_allowed")
	}
}

func nilInterface(value any) bool {
	if value == nil {
		return true
	}
	reflected := reflect.ValueOf(value)
	switch reflected.Kind() {
	case reflect.Chan, reflect.Func, reflect.Interface, reflect.Map, reflect.Pointer, reflect.Slice:
		return reflected.IsNil()
	default:
		return false
	}
}
