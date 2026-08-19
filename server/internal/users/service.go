// Package users contains user-facing identity rules shared by registration and
// later profile editing flows.
package users

import (
	"errors"
	"strings"
	"unicode"
	"unicode/utf8"
)

const (
	minimumNicknameRunes = 2
	maximumNicknameRunes = 16
)

// ErrInvalidNickname is deliberately stable and contains no submitted text.
var ErrInvalidNickname = errors.New("invalid nickname")

// User is the non-secret user identity returned by account operations.
type User struct {
	ID       string
	Nickname string
}

// NormalizeNickname trims surrounding Unicode whitespace, preserves the
// trimmed spelling for display, and derives the case-insensitive unique key.
// Length limits are measured in Unicode code points rather than UTF-8 bytes.
func NormalizeNickname(raw string) (display string, normalized string, err error) {
	if !utf8.ValidString(raw) {
		return "", "", ErrInvalidNickname
	}
	display = strings.TrimSpace(raw)
	runeCount := utf8.RuneCountInString(display)
	if runeCount < minimumNicknameRunes || runeCount > maximumNicknameRunes {
		return "", "", ErrInvalidNickname
	}
	hasVisibleBase := false
	for _, character := range display {
		if unicode.Is(unicode.Cc, character) || unicode.Is(unicode.Cf, character) {
			return "", "", ErrInvalidNickname
		}
		// Ordinary internal spaces and combining marks may decorate a name,
		// but cannot make an otherwise invisible nickname valid. Letters,
		// numbers, punctuation, and symbols (including emoji) are base runes.
		if unicode.IsLetter(character) || unicode.IsNumber(character) || unicode.IsPunct(character) || unicode.IsSymbol(character) {
			hasVisibleBase = true
		}
	}
	if !hasVisibleBase {
		return "", "", ErrInvalidNickname
	}
	return display, strings.ToLower(display), nil
}
