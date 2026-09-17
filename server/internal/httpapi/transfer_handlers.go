package httpapi

import (
	"net"
	"net/http"
	"strings"
)

func (r *router) createTransfer(w http.ResponseWriter, q *http.Request) {
	var body struct {
		Snapshot string `json:"snapshot"`
	}
	if status, err := decodeJSONBody(q, &body, "snapshot"); err != nil {
		writeAPIError(w, status, "invalid_request")
		return
	}
	_, access, _ := strings.Cut(q.Header.Get("Authorization"), " ")
	result, err := r.auth.CreateTransfer(q.Context(), access, body.Snapshot)
	if err != nil {
		writeServiceError(w, err)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, 201, result)
}
func (r *router) cancelTransfer(w http.ResponseWriter, q *http.Request) {
	_, access, _ := strings.Cut(q.Header.Get("Authorization"), " ")
	if err := r.auth.CancelTransfer(q.Context(), access); err != nil {
		writeServiceError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
func (r *router) redeemTransfer(w http.ResponseWriter, q *http.Request) {
	var body struct {
		Code     string `json:"code"`
		Receiver string `json:"receiver"`
	}
	if status, err := decodeJSONBody(q, &body, "code", "receiver"); err != nil {
		writeAPIError(w, status, "invalid_request")
		return
	}
	peer, _, err := net.SplitHostPort(q.RemoteAddr)
	if err != nil {
		peer = q.RemoteAddr
	}
	result, err := r.auth.RedeemTransferForUser(q.Context(), body.Code, body.Receiver, peer, q.URL.Query().Get("expectedUserId"))
	if err != nil {
		writeServiceError(w, err)
		return
	}
	r.hub.DisconnectRevokedUser(q.Context(), result.Session.User.ID)
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, 200, struct {
		Session  sessionPayload `json:"session"`
		Snapshot string         `json:"snapshot"`
	}{encodeSession(result.Session).Session, result.Snapshot})
}
