package httpapi

import (
	"net/http"

	"me.zqydev/gamebox/server/internal/auth"
)

type registerRequest struct {
	InviteCode string `json:"inviteCode"`
	Nickname   string `json:"nickname"`
}

type refreshRequest struct {
	RefreshToken string `json:"refreshToken"`
}

type updateNicknameRequest struct {
	Nickname string `json:"nickname"`
}

type userResponse struct {
	ID       string `json:"id"`
	Nickname string `json:"nickname"`
}

type sessionPayload struct {
	User             userResponse `json:"user"`
	AccessToken      string       `json:"accessToken"`
	AccessExpiresAt  int64        `json:"accessExpiresAt"`
	RefreshToken     string       `json:"refreshToken"`
	RefreshExpiresAt int64        `json:"refreshExpiresAt"`
}

type sessionEnvelope struct {
	Session sessionPayload `json:"session"`
}

func (router *router) register(writer http.ResponseWriter, request *http.Request) {
	var body registerRequest
	if status, decodeErr := decodeJSONBody(request, &body, "inviteCode", "nickname"); decodeErr != nil {
		writeAPIError(writer, status, "invalid_request")
		return
	}
	session, registerErr := router.auth.RegisterAndIssue(request.Context(), body.InviteCode, body.Nickname)
	if registerErr != nil {
		writeServiceError(writer, registerErr)
		return
	}
	writer.Header().Set("Cache-Control", "no-store")
	writeJSON(writer, http.StatusCreated, encodeSession(session))
}

func (router *router) refresh(writer http.ResponseWriter, request *http.Request) {
	var body refreshRequest
	if status, decodeErr := decodeJSONBody(request, &body, "refreshToken"); decodeErr != nil {
		writeAPIError(writer, status, "invalid_request")
		return
	}
	session, refreshErr := router.auth.Refresh(request.Context(), body.RefreshToken)
	if refreshErr != nil {
		writeServiceError(writer, refreshErr)
		return
	}
	writer.Header().Set("Cache-Control", "no-store")
	writeJSON(writer, http.StatusOK, encodeSession(session))
}

func (router *router) me(writer http.ResponseWriter, request *http.Request) {
	user, ok := authenticatedUser(request)
	if !ok {
		writeAPIError(writer, http.StatusUnauthorized, "unauthorized")
		return
	}
	writeJSON(writer, http.StatusOK, struct {
		User userResponse `json:"user"`
	}{User: userResponse{ID: user.ID, Nickname: user.Nickname}})
}

func (router *router) patchMe(writer http.ResponseWriter, request *http.Request) {
	user, ok := authenticatedUser(request)
	if !ok {
		writeAPIError(writer, http.StatusUnauthorized, "unauthorized")
		return
	}
	var body updateNicknameRequest
	if status, decodeErr := decodeJSONBody(request, &body, "nickname"); decodeErr != nil {
		writeAPIError(writer, status, "invalid_request")
		return
	}
	updated, updateErr := router.auth.UpdateNickname(request.Context(), user.ID, body.Nickname)
	if updateErr != nil {
		writeServiceError(writer, updateErr)
		return
	}
	writeJSON(writer, http.StatusOK, struct {
		User userResponse `json:"user"`
	}{User: userResponse{ID: updated.ID, Nickname: updated.Nickname}})
}

func encodeSession(session auth.Session) sessionEnvelope {
	return sessionEnvelope{Session: sessionPayload{
		User:        userResponse{ID: session.User.ID, Nickname: session.User.Nickname},
		AccessToken: session.AccessToken, AccessExpiresAt: session.AccessExpiresAt.UTC().UnixMilli(),
		RefreshToken: session.RefreshToken, RefreshExpiresAt: session.RefreshExpiresAt.UTC().UnixMilli(),
	}}
}
