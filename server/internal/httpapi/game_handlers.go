package httpapi

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"

	"me.zqydev/gamebox/server/internal/games/gomoku"
	"me.zqydev/gamebox/server/internal/matches"
)

func (router *router) health(writer http.ResponseWriter, _ *http.Request) {
	writeJSON(writer, http.StatusOK, struct {
		Status string `json:"status"`
	}{Status: "ok"})
}

type gameResponse struct {
	ID          string `json:"id"`
	Title       string `json:"title"`
	PlayerCount int    `json:"playerCount"`
}

func (router *router) listGames(writer http.ResponseWriter, _ *http.Request) {
	descriptors := router.games.Descriptors()
	games := make([]gameResponse, 0, len(descriptors))
	for _, descriptor := range descriptors {
		if descriptor.GameID != gomoku.GameID || descriptor.PlayerLimit != 2 {
			writeAPIError(writer, http.StatusInternalServerError, "internal_error")
			return
		}
		games = append(games, gameResponse{ID: descriptor.GameID, Title: "五子棋", PlayerCount: descriptor.PlayerLimit})
	}
	writeJSON(writer, http.StatusOK, struct {
		Games []gameResponse `json:"games"`
	}{Games: games})
}

type opponentResponse struct {
	ID           string `json:"id"`
	Nickname     string `json:"nickname"`
	Availability string `json:"availability"`
	Presence     string `json:"presence"`
}

func (router *router) gomokuOpponents(writer http.ResponseWriter, request *http.Request) {
	user, ok := authenticatedUser(request)
	if !ok {
		writeAPIError(writer, http.StatusUnauthorized, "unauthorized")
		return
	}
	opponents, listErr := router.matches.ListOpponents(request.Context(), gomoku.GameID, user.ID)
	if listErr != nil {
		writeServiceError(writer, listErr)
		return
	}
	response := make([]opponentResponse, 0, len(opponents))
	for _, opponent := range opponents {
		response = append(response, opponentResponse{
			ID: opponent.ID, Nickname: opponent.Nickname,
			Availability: opponent.Availability, Presence: opponent.Presence,
		})
	}
	writeJSON(writer, http.StatusOK, struct {
		Opponents []opponentResponse `json:"opponents"`
	}{Opponents: response})
}

type activeStatusMatchResponse struct {
	ID       string `json:"id"`
	Opponent struct {
		ID       string `json:"id"`
		Nickname string `json:"nickname"`
	} `json:"opponent"`
	Color    string `json:"color"`
	Revision int64  `json:"revision"`
}

func (router *router) gomokuStatus(writer http.ResponseWriter, request *http.Request) {
	user, ok := authenticatedUser(request)
	if !ok {
		writeAPIError(writer, http.StatusUnauthorized, "unauthorized")
		return
	}
	active, statusErr := router.matches.CurrentMatch(request.Context(), gomoku.GameID, user.ID)
	if statusErr != nil {
		router.logServiceError(request, "gomoku_status", statusErr)
		writeServiceError(writer, statusErr)
		return
	}
	if active == nil {
		writeJSON(writer, http.StatusOK, struct {
			State string `json:"state"`
		}{State: "idle"})
		return
	}
	match := activeStatusMatchResponse{ID: active.ID, Color: string(active.Color), Revision: active.Revision}
	match.Opponent.ID = active.OpponentID
	match.Opponent.Nickname = active.OpponentNickname
	writeJSON(writer, http.StatusOK, struct {
		State string                    `json:"state"`
		Match activeStatusMatchResponse `json:"match"`
	}{State: "active", Match: match})
}

type createMatchRequest struct {
	OpponentID string `json:"opponentId"`
}

func (router *router) createGomokuMatch(writer http.ResponseWriter, request *http.Request) {
	user, ok := authenticatedUser(request)
	if !ok {
		writeAPIError(writer, http.StatusUnauthorized, "unauthorized")
		return
	}
	var body createMatchRequest
	if status, decodeErr := decodeJSONBody(request, &body, "opponentId"); decodeErr != nil {
		writeAPIError(writer, status, "invalid_request")
		return
	}
	match, createErr := router.matches.Create(request.Context(), gomoku.GameID, user.ID, body.OpponentID)
	if createErr != nil {
		writeServiceError(writer, createErr)
		return
	}
	writeJSON(writer, http.StatusCreated, struct {
		Match struct {
			ID     string `json:"id"`
			GameID string `json:"gameId"`
			State  string `json:"state"`
		} `json:"match"`
	}{Match: struct {
		ID     string `json:"id"`
		GameID string `json:"gameId"`
		State  string `json:"state"`
	}{ID: match.ID, GameID: match.GameID, State: "active"}})
}

func (router *router) cancelMatch(writer http.ResponseWriter, request *http.Request) {
	user, ok := authenticatedUser(request)
	if !ok {
		writeAPIError(writer, http.StatusUnauthorized, "unauthorized")
		return
	}
	matchID, valid := literalCanonicalPathUUID(request, "matchId")
	if !valid {
		writeAPIError(writer, http.StatusBadRequest, "invalid_request")
		return
	}
	event, cancelErr := router.matches.Cancel(request.Context(), matchID, user.ID)
	if cancelErr != nil {
		writeServiceError(writer, cancelErr)
		return
	}
	publishCommittedEvent(router.publisher, matchID, event)
	writer.WriteHeader(http.StatusNoContent)
}

func publishCommittedEvent(publisher MatchEventPublisher, matchID string, event matches.Event) {
	defer func() { _ = recover() }()
	publisher.Publish(matchID, event)
}

func (router *router) createLaunchTicket(writer http.ResponseWriter, request *http.Request) {
	user, ok := authenticatedUser(request)
	if !ok {
		writeAPIError(writer, http.StatusUnauthorized, "unauthorized")
		return
	}
	if request.ContentLength != 0 {
		var empty struct{}
		if status, decodeErr := decodeJSONBody(request, &empty); decodeErr != nil {
			writeAPIError(writer, status, "invalid_request")
			return
		}
	} else if request.Body != nil {
		var probe [1]byte
		count, readErr := request.Body.Read(probe[:])
		if readErr != nil && !errors.Is(readErr, io.EOF) || count != 0 || strings.TrimSpace(string(probe[:count])) != "" {
			writeAPIError(writer, http.StatusBadRequest, "invalid_request")
			return
		}
	}
	matchID, valid := literalCanonicalPathUUID(request, "matchId")
	if !valid {
		writeAPIError(writer, http.StatusBadRequest, "invalid_request")
		return
	}
	ticket, ticketErr := router.matches.CreateLaunchTicket(request.Context(), matchID, user.ID)
	if ticketErr != nil {
		writeServiceError(writer, ticketErr)
		return
	}
	writer.Header().Set("Cache-Control", "no-store")
	writeJSON(writer, http.StatusCreated, struct {
		MatchID      string `json:"matchId"`
		GameID       string `json:"gameId"`
		LaunchTicket string `json:"launchTicket"`
		ExpiresAt    int64  `json:"expiresAt"`
	}{
		MatchID: ticket.MatchID, GameID: ticket.GameID,
		LaunchTicket: ticket.Token, ExpiresAt: ticket.ExpiresAt.UTC().UnixMilli(),
	})
}

func (router *router) matchResult(writer http.ResponseWriter, request *http.Request) {
	user, ok := authenticatedUser(request)
	if !ok {
		writeAPIError(writer, http.StatusUnauthorized, "unauthorized")
		return
	}
	matchID, valid := literalCanonicalPathUUID(request, "matchId")
	if !valid {
		writeAPIError(writer, http.StatusBadRequest, "invalid_request")
		return
	}
	_, encoded, resultErr := router.matches.Result(request.Context(), matchID, user.ID)
	if resultErr != nil {
		writeServiceError(writer, resultErr)
		return
	}
	writer.Header().Set("Cache-Control", "no-store")
	writeJSON(writer, http.StatusOK, struct {
		Result json.RawMessage `json:"result"`
	}{Result: encoded})
}
