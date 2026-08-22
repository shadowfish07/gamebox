// Package lanengine exposes the future Android LAN host boundary to gomobile.
package lanengine

import (
	"encoding/json"
	"errors"
	"strings"

	"me.zqydev/gamebox/server/internal/nickname"
)

// NormalizeNickname exposes the single Go nickname implementation through a
// primitive gomobile-safe JSON boundary.
func NormalizeNickname(raw string) string {
	display, normalized, err := nickname.Normalize(raw)
	result := struct {
		Display    string `json:"display"`
		Normalized string `json:"normalized"`
		Valid      bool   `json:"valid"`
	}{Display: display, Normalized: normalized, Valid: err == nil}
	encoded, marshalErr := json.Marshal(result)
	if marshalErr != nil {
		return `{"display":"","normalized":"","valid":false}`
	}
	return string(encoded)
}

var ErrInvalidConfiguration = errors.New("invalid configuration")

var errNotReady = errors.New("not_ready")

// Engine owns a future LAN host rooted at root.
type Engine struct {
	root string
}

// NewEngine creates an Engine with its local data root.
func NewEngine(root string) (*Engine, error) {
	if strings.TrimSpace(root) == "" {
		return nil, ErrInvalidConfiguration
	}
	return &Engine{root: root}, nil
}

// Start will start a LAN host once the host implementation is available.
func (engine *Engine) Start(roomSecretsJSON string) (string, error) {
	return "", errNotReady
}

// CreateRoom will create a LAN room once the host implementation is available.
func (engine *Engine) CreateRoom(createJSON string) (string, error) {
	return "", errNotReady
}

// IssueHostLaunch will issue a host launch once the host implementation is available.
func (engine *Engine) IssueHostLaunch() (string, error) {
	return "", errNotReady
}

// Status returns the current LAN host status.
func (engine *Engine) Status() string {
	return `{"schemaVersion":1,"state":"empty"}`
}

// Stop will stop a LAN host once the host implementation is available.
func (engine *Engine) Stop() error {
	return errNotReady
}
