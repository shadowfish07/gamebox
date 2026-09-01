package httpapi

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"

	"me.zqydev/gamebox/server/internal/games/chinesecheckers"
	"me.zqydev/gamebox/server/internal/games/gomoku"
	"me.zqydev/gamebox/server/internal/games/rps"
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
		if descriptor.PlayerLimit != 2 {
			writeAPIError(writer, http.StatusInternalServerError, "internal_error")
			return
		}
		title := map[string]string{chinesecheckers.GameID: "跳棋", gomoku.GameID: "五子棋", rps.GameID: "石头剪刀布"}[descriptor.GameID]
		if title == "" {
			writeAPIError(writer, http.StatusInternalServerError, "internal_error")
			return
		}
		games = append(games, gameResponse{ID: descriptor.GameID, Title: title, PlayerCount: descriptor.PlayerLimit})
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
	router.gameOpponents(writer, request, gomoku.GameID)
}

func (router *router) chineseCheckersOpponents(writer http.ResponseWriter, request *http.Request) {
	router.gameOpponents(writer, request, chinesecheckers.GameID)
}

func (router *router) rpsOpponents(writer http.ResponseWriter, request *http.Request) {
	router.gameOpponents(writer, request, rps.GameID)
}

func (router *router) gameOpponents(writer http.ResponseWriter, request *http.Request, gameID string) {
	user, ok := authenticatedUser(request)
	if !ok {
		writeAPIError(writer, http.StatusUnauthorized, "unauthorized")
		return
	}
	opponents, listErr := router.matches.ListOpponents(request.Context(), gameID, user.ID)
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
	Format   string `json:"format,omitempty"`
}

func (router *router) gomokuStatus(writer http.ResponseWriter, request *http.Request) {
	router.gameStatus(writer, request, gomoku.GameID, "gomoku_status")
}

func (router *router) chineseCheckersStatus(writer http.ResponseWriter, request *http.Request) {
	router.gameStatus(writer, request, chinesecheckers.GameID, "chinese_checkers_status")
}

func (router *router) rpsStatus(writer http.ResponseWriter, request *http.Request) {
	router.gameStatus(writer, request, rps.GameID, "rps_status")
}

func (router *router) gameStatus(writer http.ResponseWriter, request *http.Request, gameID, operation string) {
	user, ok := authenticatedUser(request)
	if !ok {
		writeAPIError(writer, http.StatusUnauthorized, "unauthorized")
		return
	}
	active, statusErr := router.matches.CurrentMatch(request.Context(), gameID, user.ID)
	if statusErr != nil {
		router.logServiceError(request, operation, statusErr)
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
	if gameID == rps.GameID {
		var config struct {
			Format string `json:"format"`
		}
		if json.Unmarshal(active.GameConfig, &config) != nil || (config.Format != rps.FormatSingleRound && config.Format != rps.FormatBestOfThree) {
			writeAPIError(writer, http.StatusInternalServerError, "internal_error")
			return
		}
		match.Format = config.Format
	}
	writeJSON(writer, http.StatusOK, struct {
		State string                    `json:"state"`
		Match activeStatusMatchResponse `json:"match"`
	}{State: "active", Match: match})
}

type createMatchRequest struct {
	OpponentID string `json:"opponentId"`
}

func (router *router) createGomokuMatch(writer http.ResponseWriter, request *http.Request) {
	router.createUnconfiguredMatch(writer, request, gomoku.GameID)
}

func (router *router) createChineseCheckersMatch(writer http.ResponseWriter, request *http.Request) {
	router.createUnconfiguredMatch(writer, request, chinesecheckers.GameID)
}

func (router *router) createUnconfiguredMatch(writer http.ResponseWriter, request *http.Request, gameID string) {
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
	match, createErr := router.matches.Create(request.Context(), gameID, user.ID, body.OpponentID)
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

type createRpsMatchRequest struct {
	OpponentID string `json:"opponentId"`
	Format     string `json:"format"`
}

func (router *router) createRpsMatch(writer http.ResponseWriter, request *http.Request) {
	user, ok := authenticatedUser(request)
	if !ok {
		writeAPIError(writer, http.StatusUnauthorized, "unauthorized")
		return
	}
	var body createRpsMatchRequest
	if status, decodeErr := decodeJSONBody(request, &body, "opponentId", "format"); decodeErr != nil || (body.Format != rps.FormatSingleRound && body.Format != rps.FormatBestOfThree) {
		if decodeErr != nil {
			writeAPIError(writer, status, "invalid_request")
		} else {
			writeAPIError(writer, http.StatusBadRequest, "invalid_request")
		}
		return
	}
	config, marshalErr := json.Marshal(struct {
		Format string `json:"format"`
	}{Format: body.Format})
	if marshalErr != nil {
		writeAPIError(writer, http.StatusInternalServerError, "internal_error")
		return
	}
	match, createErr := router.matches.CreateWithConfig(request.Context(), rps.GameID, user.ID, body.OpponentID, config)
	if createErr != nil {
		writeServiceError(writer, createErr)
		return
	}
	writeJSON(writer, http.StatusCreated, struct {
		Match struct {
			ID     string `json:"id"`
			GameID string `json:"gameId"`
			State  string `json:"state"`
			Format string `json:"format"`
		} `json:"match"`
	}{Match: struct {
		ID     string `json:"id"`
		GameID string `json:"gameId"`
		State  string `json:"state"`
		Format string `json:"format"`
	}{ID: match.ID, GameID: match.GameID, State: "active", Format: body.Format}})
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
