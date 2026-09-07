package httpapi

import (
	"errors"
	"github.com/google/uuid"
	"me.zqydev/gamebox/server/internal/scratch"
	"net/http"
	"net/url"
)

func (router *router) listScratchCollections(w http.ResponseWriter, r *http.Request) {
	query, err := url.ParseQuery(r.URL.RawQuery)
	if err != nil || len(query) > 1 || len(query["after"]) > 1 {
		writeAPIError(w, 400, "invalid_request")
		return
	}
	for key := range query {
		if key != "after" {
			writeAPIError(w, 400, "invalid_request")
			return
		}
	}
	after := query.Get("after")
	if after != "" {
		id, err := uuid.Parse(after)
		if err != nil || id.String() != after {
			writeAPIError(w, 400, "invalid_request")
			return
		}
	}
	page, err := router.scratch.List(r.Context(), after)
	if err != nil {
		writeAPIError(w, 500, "internal_error")
		return
	}
	writeJSON(w, 200, page)
}
func (router *router) publishScratchCollection(w http.ResponseWriter, r *http.Request) {
	user, ok := authenticatedUser(r)
	if !ok {
		writeAPIError(w, 401, "unauthorized")
		return
	}
	var body struct {
		Counts []int `json:"counts"`
	}
	if status, err := decodeJSONBody(r, &body, "counts"); err != nil {
		writeAPIError(w, status, "invalid_request")
		return
	}
	err := router.scratch.Publish(r.Context(), user.ID, body.Counts)
	if errors.Is(err, scratch.ErrInvalid) {
		writeAPIError(w, 400, "invalid_request")
		return
	}
	if err != nil {
		writeAPIError(w, 500, "internal_error")
		return
	}
	writeJSON(w, 200, struct {
		Published bool `json:"published"`
	}{true})
}
