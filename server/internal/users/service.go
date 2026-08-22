// Package users contains user-facing identity rules shared by registration and
// later profile editing flows.
package users

import (
	"me.zqydev/gamebox/server/internal/nickname"
)

// ErrInvalidNickname is deliberately stable and contains no submitted text.
var ErrInvalidNickname = nickname.ErrInvalid

// User is the non-secret user identity returned by account operations.
type User struct {
	ID       string
	Nickname string
}

// NormalizeNickname trims surrounding Unicode whitespace, preserves the
// trimmed spelling for display, and derives the case-insensitive unique key.
// Length limits are measured in Unicode code points rather than UTF-8 bytes.
func NormalizeNickname(raw string) (display string, normalized string, err error) {
	return nickname.Normalize(raw)
}
