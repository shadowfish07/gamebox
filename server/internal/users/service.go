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
	zeroWidthNonJoiner   = '\u200c'
	zeroWidthJoiner      = '\u200d'
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
	// Inspect the raw value before TrimSpace so a leading or trailing control,
	// line separator, or paragraph separator cannot be silently trimmed away.
	for _, character := range raw {
		if isForbiddenControlOrSeparator(character) {
			return "", "", ErrInvalidNickname
		}
	}
	display = strings.TrimSpace(raw)
	runeCount := utf8.RuneCountInString(display)
	if runeCount < minimumNicknameRunes || runeCount > maximumNicknameRunes {
		return "", "", ErrInvalidNickname
	}
	characters := []rune(display)
	hasVisibleBase := false
	for index, character := range characters {
		if unicode.Is(unicode.Cf, character) {
			switch character {
			case zeroWidthJoiner:
				if !validEmojiJoinerContext(characters, index) {
					return "", "", ErrInvalidNickname
				}
			case zeroWidthNonJoiner:
				if !validTextNonJoinerContext(characters, index) {
					return "", "", ErrInvalidNickname
				}
			default:
				return "", "", ErrInvalidNickname
			}
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

func isForbiddenControlOrSeparator(character rune) bool {
	return unicode.Is(unicode.Cc, character) || unicode.Is(unicode.Zl, character) || unicode.Is(unicode.Zp, character)
}

// validEmojiJoinerContext intentionally supports only symbol-based emoji ZWJ
// sequences. Marks such as variation selectors and the standard skin-tone
// modifiers may decorate either adjacent emoji base, but letters cannot use a
// zero-width joiner to masquerade as an unjoined spelling.
func validEmojiJoinerContext(characters []rune, joinerIndex int) bool {
	left, leftFound := adjacentBase(characters, joinerIndex, -1, isEmojiDecoration)
	right, rightFound := adjacentBase(characters, joinerIndex, 1, isEmojiDecoration)
	return leftFound && rightFound && unicode.Is(unicode.So, left) && unicode.Is(unicode.So, right)
}

// validTextNonJoinerContext permits ZWNJ only inside text: both sides must
// resolve to letters after skipping attached combining marks. Symbols,
// whitespace, another joiner, and leading or trailing placement all fail.
func validTextNonJoinerContext(characters []rune, joinerIndex int) bool {
	left, leftFound := adjacentBase(characters, joinerIndex, -1, unicode.IsMark)
	right, rightFound := adjacentBase(characters, joinerIndex, 1, unicode.IsMark)
	return leftFound && rightFound && unicode.IsLetter(left) && unicode.IsLetter(right)
}

func adjacentBase(characters []rune, start, direction int, decoration func(rune) bool) (rune, bool) {
	for index := start + direction; index >= 0 && index < len(characters); index += direction {
		if decoration(characters[index]) {
			continue
		}
		return characters[index], true
	}
	return 0, false
}

func isEmojiDecoration(character rune) bool {
	return unicode.IsMark(character) || character >= 0x1f3fb && character <= 0x1f3ff
}
