package httpapi

import (
	"errors"
	"github.com/google/uuid"
	"me.zqydev/gamebox/server/internal/scratch"
	"net/http"
	"net/url"
	"strconv"
)

func (router *router) listScratchCollections(w http.ResponseWriter, r *http.Request) {
	query, err := url.ParseQuery(r.URL.RawQuery)
	if err != nil || len(query) > 3 || len(query["after"]) > 1 || len(query["card"]) > 1 || len(query["catalogSize"]) > 1 {
		writeAPIError(w, 400, "invalid_request")
		return
	}
	for key := range query {
		if key != "after" && key != "card" && key != "catalogSize" {
			writeAPIError(w, 400, "invalid_request")
			return
		}
	}
	// Keep the 24-entry response contract for installed cat-only clients.
	catalogSize := scratch.LegacyCatalogSize
	if values, ok := query["catalogSize"]; ok {
		size, parseErr := strconv.Atoi(values[0])
		if parseErr != nil || (size != scratch.LegacyCatalogSize && size != scratch.CatalogSize) || strconv.Itoa(size) != values[0] {
			writeAPIError(w, 400, "invalid_request")
			return
		}
		catalogSize = size
	}
	after := query.Get("after")
	if after != "" {
		id, err := uuid.Parse(after)
		if err != nil || id.String() != after {
			writeAPIError(w, 400, "invalid_request")
			return
		}
	}
	var card *int
	if values, ok := query["card"]; ok {
		index, err := strconv.Atoi(values[0])
		if err != nil || index < 0 || index >= catalogSize || strconv.Itoa(index) != values[0] {
			writeAPIError(w, 400, "invalid_request")
			return
		}
		card = &index
	}
	page, err := router.scratch.List(r.Context(), after, card)
	if err != nil {
		writeAPIError(w, 500, "internal_error")
		return
	}
	for i := range page.Players {
		page.Players[i].Counts = page.Players[i].Counts[:catalogSize]
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
