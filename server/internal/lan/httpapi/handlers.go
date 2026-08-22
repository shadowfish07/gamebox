package httpapi

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net/http"
	"unicode/utf8"

	"me.zqydev/gamebox/server/internal/games/gomoku"
	"me.zqydev/gamebox/server/internal/lan/room"
)

const (
	maximumJSONBodyBytes = 64 * 1024
	maximumJSONDepth     = 32
)

var errorMessages = map[string]string{
	"invalid_request":      "请求无效",
	"method_not_allowed":   "请求方法不受支持",
	"room_key_invalid":     "房间密钥无效",
	"resume_invalid":       "恢复凭证无效",
	"join_expired":         "加入凭证已过期",
	"room_locked":          "房间已锁定",
	"match_not_finished":   "对局尚未结束",
	"result_hash_mismatch": "结果校验失败",
	"ticket_invalid":       "启动票据无效",
	"stale_revision":       "对局状态已更新",
	"not_your_turn":        "还未轮到你",
	"cell_occupied":        "该位置已有棋子",
	"action_conflict":      "动作编号已被使用",
	"internal_error":       "服务器内部错误",
}

type errorResponse struct {
	Error struct {
		Code    string         `json:"code"`
		Message string         `json:"message"`
		Details map[string]any `json:"details"`
	} `json:"error"`
}

type joinBody struct {
	RoomID               string `json:"roomId"`
	Nickname             string `json:"nickname"`
	JoinAttemptID        string `json:"joinAttemptId"`
	CandidateResumeToken string `json:"candidateResumeToken"`
	RoomKey              string `json:"roomKey"`
}

type resumeTicketBody struct {
	RoomID      string `json:"roomId"`
	PlayerID    string `json:"playerId"`
	ResumeToken string `json:"resumeToken"`
}

type resumeBody struct {
	ResumeToken string `json:"resumeToken"`
}

type resultAckBody struct {
	ResumeToken string `json:"resumeToken"`
	ResultHash  string `json:"resultHash"`
}

type launchResponse struct {
	SchemaVersion int    `json:"schemaVersion"`
	MatchID       string `json:"matchId"`
	GameID        string `json:"gameId"`
	PlayerID      string `json:"playerId"`
	LaunchTicket  string `json:"launchTicket"`
	ExpiresAt     int64  `json:"expiresAt"`
}

func (joinBody) String() string {
	return "joinBody{RoomID:<id> Nickname:<redacted> JoinAttemptID:<id> CandidateResumeToken:<redacted> RoomKey:<redacted>}"
}
func (body joinBody) GoString() string { return body.String() }

func (resumeTicketBody) String() string {
	return "resumeTicketBody{RoomID:<id> PlayerID:<id> ResumeToken:<redacted>}"
}
func (body resumeTicketBody) GoString() string { return body.String() }

func (resumeBody) String() string        { return "resumeBody{ResumeToken:<redacted>}" }
func (body resumeBody) GoString() string { return body.String() }

func (resultAckBody) String() string {
	return "resultAckBody{ResumeToken:<redacted> ResultHash:<hash>}"
}
func (body resultAckBody) GoString() string { return body.String() }

func (launchResponse) String() string {
	return "launchResponse{SchemaVersion:1 MatchID:<id> GameID:<id> PlayerID:<id> LaunchTicket:<redacted> ExpiresAt:<time>}"
}
func (response launchResponse) GoString() string { return response.String() }

func (router *Router) join(writer http.ResponseWriter, request *http.Request) {
	var body joinBody
	if status := decodeExactBody(request, []string{"roomId", "nickname", "joinAttemptId", "candidateResumeToken", "roomKey"}, &body); status != 0 {
		writeAPIError(writer, status, "invalid_request")
		return
	}
	if body.RoomID != request.PathValue("roomId") {
		writeAPIError(writer, http.StatusBadRequest, "invalid_request")
		return
	}
	joined, err := router.service.Join(request.Context(), room.JoinRequest{
		RoomID: body.RoomID, Nickname: body.Nickname, JoinAttemptID: body.JoinAttemptID,
		CandidateResumeToken: body.CandidateResumeToken, RoomKey: body.RoomKey,
	})
	if err != nil {
		writeServiceError(writer, err)
		return
	}
	writeJSON(writer, http.StatusOK, launchResponse{
		SchemaVersion: 1, MatchID: body.RoomID, GameID: gomoku.GameID, PlayerID: joined.Player.PlayerID,
		LaunchTicket: joined.LaunchTicket.Token, ExpiresAt: joined.LaunchTicket.ExpiresAt,
	})
}

func (router *Router) resumeTicket(writer http.ResponseWriter, request *http.Request) {
	var body resumeTicketBody
	if status := decodeExactBody(request, []string{"roomId", "playerId", "resumeToken"}, &body); status != 0 {
		writeAPIError(writer, status, "invalid_request")
		return
	}
	if body.RoomID != request.PathValue("roomId") {
		writeAPIError(writer, http.StatusBadRequest, "invalid_request")
		return
	}
	ticket, err := router.service.IssueLaunch(request.Context(), body.PlayerID, body.ResumeToken)
	if err != nil {
		writeServiceError(writer, err)
		return
	}
	writeJSON(writer, http.StatusOK, launchResponse{
		SchemaVersion: 1, MatchID: body.RoomID, GameID: gomoku.GameID, PlayerID: body.PlayerID,
		LaunchTicket: ticket.Token, ExpiresAt: ticket.ExpiresAt,
	})
}

func (router *Router) result(writer http.ResponseWriter, request *http.Request) {
	var body resumeBody
	if status := decodeExactBody(request, []string{"resumeToken"}, &body); status != 0 {
		writeAPIError(writer, status, "invalid_request")
		return
	}
	credential, err := router.service.ConnectLAN(request.Context(), room.ConnectCredential{ResumeToken: body.ResumeToken})
	if err != nil {
		writeServiceError(writer, err)
		return
	}
	snapshot := router.service.Snapshot()
	if credential.RoomID != request.PathValue("roomId") || snapshot.RoomID != credential.RoomID {
		writeAPIError(writer, http.StatusBadRequest, "invalid_request")
		return
	}
	if snapshot.Status != room.StatusFinished || snapshot.Result == nil {
		writeAPIError(writer, http.StatusConflict, "match_not_finished")
		return
	}
	writeJSON(writer, http.StatusOK, struct {
		SchemaVersion int    `json:"schemaVersion"`
		ResultHash    string `json:"resultHash"`
		Result        any    `json:"result"`
	}{SchemaVersion: 1, ResultHash: snapshot.Result.ResultHash, Result: nil})
}

func (router *Router) resultAck(writer http.ResponseWriter, request *http.Request) {
	var body resultAckBody
	if status := decodeExactBody(request, []string{"resumeToken", "resultHash"}, &body); status != 0 {
		writeAPIError(writer, status, "invalid_request")
		return
	}
	credential, err := router.service.ConnectLAN(request.Context(), room.ConnectCredential{ResumeToken: body.ResumeToken})
	if err != nil {
		writeServiceError(writer, err)
		return
	}
	if credential.RoomID != request.PathValue("roomId") {
		writeAPIError(writer, http.StatusBadRequest, "invalid_request")
		return
	}
	if err := router.service.AcknowledgeResult(request.Context(), credential.PlayerID, body.ResultHash); err != nil {
		writeServiceError(writer, err)
		return
	}
	writeJSON(writer, http.StatusOK, struct {
		SchemaVersion int  `json:"schemaVersion"`
		Acknowledged  bool `json:"acknowledged"`
	}{SchemaVersion: 1, Acknowledged: true})
}

func decodeExactBody(request *http.Request, fields []string, target any) int {
	mediaType, parameters, err := mime.ParseMediaType(request.Header.Get("Content-Type"))
	if err != nil || mediaType != "application/json" || len(parameters) != 0 {
		return http.StatusBadRequest
	}
	data, err := io.ReadAll(io.LimitReader(request.Body, maximumJSONBodyBytes+1))
	if err != nil || len(data) == 0 || len(data) > maximumJSONBodyBytes || !utf8.Valid(data) {
		if len(data) > maximumJSONBodyBytes {
			return http.StatusRequestEntityTooLarge
		}
		return http.StatusBadRequest
	}
	if !boundedJSON(data) {
		return http.StatusBadRequest
	}
	allowed := make(map[string]struct{}, len(fields))
	for _, field := range fields {
		allowed[field] = struct{}{}
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	opening, err := decoder.Token()
	if err != nil || opening != json.Delim('{') {
		return http.StatusBadRequest
	}
	seen := make(map[string]struct{}, len(fields))
	for decoder.More() {
		keyToken, err := decoder.Token()
		key, ok := keyToken.(string)
		if err != nil || !ok {
			return http.StatusBadRequest
		}
		if _, ok := allowed[key]; !ok {
			return http.StatusBadRequest
		}
		if _, duplicate := seen[key]; duplicate {
			return http.StatusBadRequest
		}
		seen[key] = struct{}{}
		var raw json.RawMessage
		if decoder.Decode(&raw) != nil {
			return http.StatusBadRequest
		}
	}
	closing, err := decoder.Token()
	if err != nil || closing != json.Delim('}') || len(seen) != len(fields) {
		return http.StatusBadRequest
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		return http.StatusBadRequest
	}
	if json.Unmarshal(data, target) != nil {
		return http.StatusBadRequest
	}
	return 0
}

func boundedJSON(data []byte) bool {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	depth := 0
	for {
		token, err := decoder.Token()
		if err == io.EOF {
			return depth == 0
		}
		if err != nil {
			return false
		}
		if delimiter, ok := token.(json.Delim); ok {
			switch delimiter {
			case '{', '[':
				depth++
				if depth > maximumJSONDepth {
					return false
				}
			case '}', ']':
				depth--
				if depth < 0 {
					return false
				}
			}
		}
	}
}

func writeServiceError(writer http.ResponseWriter, err error) {
	status, code := http.StatusInternalServerError, "internal_error"
	switch {
	case errors.Is(err, room.ErrInvalidRequest):
		status, code = http.StatusBadRequest, "invalid_request"
	case errors.Is(err, room.ErrRoomKeyInvalid):
		status, code = http.StatusForbidden, "room_key_invalid"
	case errors.Is(err, room.ErrResumeInvalid):
		status, code = http.StatusUnauthorized, "resume_invalid"
	case errors.Is(err, room.ErrJoinExpired):
		status, code = http.StatusGone, "join_expired"
	case errors.Is(err, room.ErrRoomLocked):
		status, code = http.StatusConflict, "room_locked"
	case errors.Is(err, room.ErrResultNotReady):
		status, code = http.StatusConflict, "match_not_finished"
	case errors.Is(err, room.ErrResultHashMismatch):
		status, code = http.StatusConflict, "result_hash_mismatch"
	case errors.Is(err, room.ErrTicketInvalid):
		status, code = http.StatusUnauthorized, "ticket_invalid"
	case errors.Is(err, room.ErrStaleRevision):
		status, code = http.StatusConflict, "stale_revision"
	case errors.Is(err, room.ErrActionConflict):
		status, code = http.StatusConflict, "action_conflict"
	case errors.Is(err, gomoku.ErrNotYourTurn):
		status, code = http.StatusConflict, "not_your_turn"
	case errors.Is(err, gomoku.ErrCellOccupied):
		status, code = http.StatusConflict, "cell_occupied"
	}
	writeAPIError(writer, status, code)
}

func writeAPIError(writer http.ResponseWriter, status int, code string) {
	message, found := errorMessages[code]
	if !found {
		status, code, message = http.StatusInternalServerError, "internal_error", errorMessages["internal_error"]
	}
	var response errorResponse
	response.Error.Code = code
	response.Error.Message = message
	response.Error.Details = map[string]any{}
	writeJSON(writer, status, response)
}

func writeJSON(writer http.ResponseWriter, status int, value any) {
	data, err := json.Marshal(value)
	if err != nil {
		status = http.StatusInternalServerError
		data = []byte(`{"error":{"code":"internal_error","message":"服务器内部错误","details":{}}}`)
	}
	writer.Header().Set("Content-Type", "application/json; charset=utf-8")
	writer.Header().Set("X-Content-Type-Options", "nosniff")
	writer.WriteHeader(status)
	_, _ = writer.Write(data)
}
