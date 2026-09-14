package httpapi

import (
	"errors"
	"me.zqydev/gamebox/server/internal/battleship"
	"net/http"
	"net/url"
)

func (router *router) registerBattleship(mux *http.ServeMux) {
	if router.battleship == nil {
		return
	}
	for pattern, handler := range map[string]http.HandlerFunc{
		"GET /v1/battleship/matches":                    router.battleshipList,
		"POST /v1/battleship/matches":                   router.battleshipCreate,
		"GET /v1/battleship/opponents":                  router.battleshipOpponents,
		"GET /v1/battleship/matches/{matchId}":          router.battleshipGet,
		"POST /v1/battleship/matches/{matchId}/actions": router.battleshipAct,
	} {
		mux.Handle(pattern, router.authenticated(handler))
	}
	registerMethodFallback(mux, "/v1/battleship/matches", "GET, POST")
	registerMethodFallback(mux, "/v1/battleship/opponents", "GET")
	registerMethodFallback(mux, "/v1/battleship/matches/{matchId}", "GET")
	registerMethodFallback(mux, "/v1/battleship/matches/{matchId}/actions", "POST")
}
func battleshipReply(w http.ResponseWriter, v any, err error) {
	w.Header().Set("Cache-Control", "no-store")
	switch {
	case err == nil:
		writeJSON(w, 200, v)
	case errors.Is(err, battleship.ErrInvalid):
		writeAPIError(w, 400, "invalid_request")
	case errors.Is(err, battleship.ErrConflict):
		writeAPIError(w, 409, "stale_revision")
	case errors.Is(err, battleship.ErrNotFound):
		writeAPIError(w, 404, "match_not_found")
	default:
		writeAPIError(w, 500, "internal_error")
	}
}
func battleshipCursor(r *http.Request) (string, error) {
	q, e := url.ParseQuery(r.URL.RawQuery)
	if e != nil || len(q) > 1 || len(q["after"]) > 1 {
		return "", battleship.ErrInvalid
	}
	for k := range q {
		if k != "after" {
			return "", battleship.ErrInvalid
		}
	}
	return q.Get("after"), nil
}
func (router *router) battleshipList(w http.ResponseWriter, r *http.Request) {
	u, _ := authenticatedUser(r)
	after, e := battleshipCursor(r)
	if e != nil {
		battleshipReply(w, nil, e)
		return
	}
	v, e := router.battleship.List(r.Context(), u.ID, after)
	battleshipReply(w, v, e)
}
func (router *router) battleshipOpponents(w http.ResponseWriter, r *http.Request) {
	u, _ := authenticatedUser(r)
	after, e := battleshipCursor(r)
	if e != nil {
		battleshipReply(w, nil, e)
		return
	}
	v, e := router.battleship.Opponents(r.Context(), u.ID, after)
	battleshipReply(w, v, e)
}
func (router *router) battleshipGet(w http.ResponseWriter, r *http.Request) {
	u, _ := authenticatedUser(r)
	if r.URL.RawQuery != "" {
		battleshipReply(w, nil, battleship.ErrInvalid)
		return
	}
	v, e := router.battleship.Get(r.Context(), u.ID, r.PathValue("matchId"))
	battleshipReply(w, v, e)
}
func (router *router) battleshipCreate(w http.ResponseWriter, r *http.Request) {
	u, _ := authenticatedUser(r)
	var body struct {
		ID         string `json:"id"`
		OpponentID string `json:"opponentId"`
	}
	if status, e := decodeJSONBody(r, &body, "id", "opponentId"); e != nil {
		writeAPIError(w, status, "invalid_request")
		return
	}
	v, e := router.battleship.Create(r.Context(), u.ID, body.ID, body.OpponentID)
	battleshipReply(w, v, e)
}
func (router *router) battleshipAct(w http.ResponseWriter, r *http.Request) {
	u, _ := authenticatedUser(r)
	var body battleship.Action
	if status, e := decodeJSONBody(r, &body, "actionId", "revision", "kind", "ships", "cell"); e != nil {
		writeAPIError(w, status, "invalid_request")
		return
	}
	v, e := router.battleship.Act(r.Context(), u.ID, r.PathValue("matchId"), body)
	battleshipReply(w, v, e)
}
