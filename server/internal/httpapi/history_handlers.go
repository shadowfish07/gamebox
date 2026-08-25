package httpapi

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"time"

	"github.com/google/uuid"

	"me.zqydev/gamebox/server/internal/games/gomoku"
	"me.zqydev/gamebox/server/internal/matches"
)

type historyCursorPayload struct {
	Version    int    `json:"v"`
	FinishedAt int64  `json:"finishedAt"`
	MatchID    string `json:"matchId"`
}

func parseHistoryQuery(rawQuery string) (matches.HistoryPageRequest, error) {
	values, err := url.ParseQuery(rawQuery)
	if err != nil {
		return matches.HistoryPageRequest{}, matches.ErrInvalidRequest
	}
	for key, entries := range values {
		if (key != "cursor" && key != "limit") || len(entries) != 1 {
			return matches.HistoryPageRequest{}, matches.ErrInvalidRequest
		}
	}

	request := matches.HistoryPageRequest{Limit: 20}
	if entries := values["limit"]; len(entries) == 1 {
		limit, parseErr := strconv.Atoi(entries[0])
		if parseErr != nil || limit < 1 || limit > 50 {
			return matches.HistoryPageRequest{}, matches.ErrInvalidRequest
		}
		request.Limit = limit
	}
	if entries := values["cursor"]; len(entries) == 1 {
		cursor, decodeErr := decodeHistoryCursor(entries[0])
		if decodeErr != nil {
			return matches.HistoryPageRequest{}, matches.ErrInvalidRequest
		}
		request.Cursor = &cursor
	}
	return request, nil
}

func decodeHistoryCursor(value string) (matches.HistoryCursor, error) {
	decoded, err := base64.RawURLEncoding.DecodeString(value)
	if err != nil || value == "" || base64.RawURLEncoding.EncodeToString(decoded) != value {
		return matches.HistoryCursor{}, matches.ErrInvalidRequest
	}

	decoder := json.NewDecoder(bytes.NewReader(decoded))
	opening, err := decoder.Token()
	if err != nil || opening != json.Delim('{') {
		return matches.HistoryCursor{}, matches.ErrInvalidRequest
	}
	payload := historyCursorPayload{}
	seen := make(map[string]bool, 3)
	for decoder.More() {
		token, tokenErr := decoder.Token()
		name, validName := token.(string)
		if tokenErr != nil || !validName || seen[name] {
			return matches.HistoryCursor{}, matches.ErrInvalidRequest
		}
		seen[name] = true
		switch name {
		case "v":
			err = decoder.Decode(&payload.Version)
		case "finishedAt":
			err = decoder.Decode(&payload.FinishedAt)
		case "matchId":
			err = decoder.Decode(&payload.MatchID)
		default:
			return matches.HistoryCursor{}, matches.ErrInvalidRequest
		}
		if err != nil {
			return matches.HistoryCursor{}, matches.ErrInvalidRequest
		}
	}
	closing, err := decoder.Token()
	if err != nil || closing != json.Delim('}') || len(seen) != 3 || !seen["v"] || !seen["finishedAt"] || !seen["matchId"] || payload.Version != 1 {
		return matches.HistoryCursor{}, matches.ErrInvalidRequest
	}
	if _, err = decoder.Token(); err != io.EOF {
		return matches.HistoryCursor{}, matches.ErrInvalidRequest
	}

	cursor := matches.HistoryCursor{
		FinishedAt: time.UnixMilli(payload.FinishedAt).UTC(),
		MatchID:    payload.MatchID,
	}
	canonical, err := encodeHistoryCursor(cursor)
	if err != nil || canonical != value {
		return matches.HistoryCursor{}, matches.ErrInvalidRequest
	}
	return cursor, nil
}

func encodeHistoryCursor(cursor matches.HistoryCursor) (string, error) {
	if !validHTTPHistoryCursor(cursor) {
		return "", matches.ErrInvalidRequest
	}
	payload, err := json.Marshal(historyCursorPayload{
		Version: 1, FinishedAt: cursor.FinishedAt.UnixMilli(), MatchID: cursor.MatchID,
	})
	if err != nil {
		return "", matches.ErrInvalidRequest
	}
	return base64.RawURLEncoding.EncodeToString(payload), nil
}

func validHTTPHistoryCursor(cursor matches.HistoryCursor) bool {
	if cursor.FinishedAt.IsZero() {
		return false
	}
	canonicalTime := time.UnixMilli(cursor.FinishedAt.UnixMilli()).UTC()
	parsedID, err := uuid.Parse(cursor.MatchID)
	return cursor.FinishedAt == canonicalTime && err == nil && parsedID.String() == cursor.MatchID && parsedID.Variant() == uuid.RFC4122
}

type historyStatisticsResponse struct {
	ValidMatches int64   `json:"validMatches"`
	Wins         int64   `json:"wins"`
	Losses       int64   `json:"losses"`
	Draws        int64   `json:"draws"`
	WinRate      float64 `json:"winRate"`
}

type historyMatchResponse struct {
	ID               string `json:"id"`
	Outcome          string `json:"outcome"`
	OpponentNickname string `json:"opponentNickname"`
	Color            string `json:"color"`
	FinishedAt       int64  `json:"finishedAt"`
	MoveCount        int64  `json:"moveCount"`
}

type historyResponse struct {
	Statistics historyStatisticsResponse `json:"statistics"`
	Matches    []historyMatchResponse    `json:"matches"`
	NextCursor *string                   `json:"nextCursor"`
}

func (router *router) gomokuHistory(writer http.ResponseWriter, request *http.Request) {
	user, ok := authenticatedUser(request)
	if !ok {
		writeAPIError(writer, http.StatusUnauthorized, "unauthorized")
		return
	}
	pageRequest, parseErr := parseHistoryQuery(request.URL.RawQuery)
	if parseErr != nil {
		writeAPIError(writer, http.StatusBadRequest, "invalid_request")
		return
	}
	page, historyErr := router.matches.ListHistory(request.Context(), gomoku.GameID, user.ID, pageRequest)
	if historyErr != nil {
		if phase, category, hasMetadata := matches.HistoryFailureMetadata(historyErr); hasMetadata {
			router.logger.Printf(
				"request_id=%s feature=match_history phase=%s category=%s",
				requestIDFromContext(request.Context()), phase, category,
			)
		}
		writeServiceError(writer, historyErr)
		return
	}

	nextCursor := (*string)(nil)
	if page.NextCursor != nil {
		encoded, encodeErr := encodeHistoryCursor(*page.NextCursor)
		if encodeErr != nil {
			writeAPIError(writer, http.StatusInternalServerError, "internal_error")
			return
		}
		nextCursor = &encoded
	}
	response := historyResponse{
		Statistics: historyStatisticsResponse{
			ValidMatches: page.Statistics.ValidMatches,
			Wins:         page.Statistics.Wins,
			Losses:       page.Statistics.Losses,
			Draws:        page.Statistics.Draws,
			WinRate:      page.Statistics.WinRate,
		},
		Matches:    make([]historyMatchResponse, 0, len(page.Matches)),
		NextCursor: nextCursor,
	}
	for _, entry := range page.Matches {
		response.Matches = append(response.Matches, historyMatchResponse{
			ID:               entry.ID,
			Outcome:          entry.Outcome,
			OpponentNickname: entry.OpponentNickname,
			Color:            string(entry.Color),
			FinishedAt:       entry.FinishedAt.UTC().UnixMilli(),
			MoveCount:        entry.MoveCount,
		})
	}
	writeJSON(writer, http.StatusOK, response)
}
