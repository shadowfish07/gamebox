// Package lanengine exposes the future Android LAN host boundary to gomobile.
package lanengine

import (
	"errors"
	"strings"
)

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
