package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"

	"me.zqydev/gamebox/server/internal/auth"
	"me.zqydev/gamebox/server/internal/games/gomoku"
	"me.zqydev/gamebox/server/internal/matches"
)

var ErrInvalidConfiguration = errors.New("invalid http api configuration")

var errorMessages = map[string]string{
	"invalid_request":       "请求无效",
	"unauthorized":          "身份验证失败",
	"invite_invalid":        "邀请码无效或已使用",
	"nickname_taken":        "昵称已被使用",
	"opponent_busy":         "对手已进入其他对局",
	"active_match_exists":   "你已在五子棋对局中",
	"match_not_found":       "对局不存在",
	"match_not_cancellable": "对局无法取消",
	"match_not_finished":    "对局尚未结束",
	"ticket_invalid":        "启动票据无效",
	"stale_revision":        "对局状态已更新",
	"not_your_turn":         "还未轮到你",
	"cell_occupied":         "该位置已有棋子",
	"action_conflict":       "动作编号已被使用",
	"internal_error":        "服务器内部错误",
}

type errorResponse struct {
	Error struct {
		Code    string         `json:"code"`
		Message string         `json:"message"`
		Details map[string]any `json:"details"`
	} `json:"error"`
}

func writeAPIError(writer http.ResponseWriter, status int, code string) {
	message, known := errorMessages[code]
	if !known {
		status, code, message = http.StatusInternalServerError, "internal_error", errorMessages["internal_error"]
	}
	var response errorResponse
	response.Error.Code = code
	response.Error.Message = message
	response.Error.Details = map[string]any{}
	writeJSON(writer, status, response)
}

func writeServiceError(writer http.ResponseWriter, err error) {
	status, code := http.StatusInternalServerError, "internal_error"
	switch {
	case errors.Is(err, auth.ErrUnauthorized):
		status, code = http.StatusUnauthorized, "unauthorized"
	case errors.Is(err, auth.ErrInviteInvalid):
		status, code = http.StatusUnprocessableEntity, "invite_invalid"
	case errors.Is(err, auth.ErrNicknameTaken):
		status, code = http.StatusConflict, "nickname_taken"
	case errors.Is(err, auth.ErrInvalidRequest), errors.Is(err, matches.ErrInvalidRequest):
		status, code = http.StatusBadRequest, "invalid_request"
	case errors.Is(err, matches.ErrActiveMatchExists):
		status, code = http.StatusConflict, "active_match_exists"
	case errors.Is(err, matches.ErrOpponentBusy):
		status, code = http.StatusConflict, "opponent_busy"
	case errors.Is(err, matches.ErrMatchNotFound):
		status, code = http.StatusNotFound, "match_not_found"
	case errors.Is(err, matches.ErrMatchNotCancellable):
		status, code = http.StatusConflict, "match_not_cancellable"
	case errors.Is(err, matches.ErrMatchNotFinished):
		status, code = http.StatusConflict, "match_not_finished"
	case errors.Is(err, matches.ErrStaleRevision):
		status, code = http.StatusConflict, "stale_revision"
	case errors.Is(err, gomoku.ErrNotYourTurn):
		status, code = http.StatusConflict, "not_your_turn"
	case errors.Is(err, gomoku.ErrCellOccupied):
		status, code = http.StatusConflict, "cell_occupied"
	case errors.Is(err, matches.ErrActionConflict):
		status, code = http.StatusConflict, "action_conflict"
	}
	writeAPIError(writer, status, code)
}

func writeJSON(writer http.ResponseWriter, status int, value any) {
	writer.Header().Set("Content-Type", "application/json; charset=utf-8")
	writer.Header().Set("X-Content-Type-Options", "nosniff")
	writer.WriteHeader(status)
	_ = json.NewEncoder(writer).Encode(value)
}
