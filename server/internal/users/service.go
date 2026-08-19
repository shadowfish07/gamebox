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
	return display, normalizedNicknameKey(display), nil
}

func isForbiddenControlOrSeparator(character rune) bool {
	return unicode.Is(unicode.Cc, character) || unicode.Is(unicode.Zl, character) || unicode.Is(unicode.Zp, character)
}

// validEmojiJoinerContext intentionally supports only symbol-based emoji ZWJ
// sequences. Marks and skin-tone modifiers may trail the left emoji base, but
// the rune immediately after ZWJ must be the right emoji base; decorations may
// then follow that base normally. Letters cannot use a zero-width joiner to
// masquerade as an unjoined spelling.
func validEmojiJoinerContext(characters []rune, joinerIndex int) bool {
	left, leftFound := precedingBase(characters, joinerIndex, isEmojiDecoration)
	rightIndex := joinerIndex + 1
	return leftFound && unicode.Is(unicode.So, left) &&
		rightIndex < len(characters) && unicode.Is(unicode.So, characters[rightIndex])
}

// validTextNonJoinerContext permits ZWNJ only inside text: marks may trail the
// left letter, while the rune immediately after ZWNJ must be the right letter
// (and may itself be followed by marks). Symbols, whitespace, another joiner,
// and leading or trailing placement all fail.
func validTextNonJoinerContext(characters []rune, joinerIndex int) bool {
	left, leftFound := precedingBase(characters, joinerIndex, unicode.IsMark)
	rightIndex := joinerIndex + 1
	return leftFound && unicode.IsLetter(left) &&
		rightIndex < len(characters) && unicode.IsLetter(characters[rightIndex])
}

func precedingBase(characters []rune, start int, decoration func(rune) bool) (rune, bool) {
	for index := start - 1; index >= 0; index-- {
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

// normalizedNicknameKey is deliberately more conservative than the display
// spelling. Contextually valid joiners remain visible to the user, but are
// removed only after lower-casing so invisible formatting cannot create a
// second unique account for an otherwise identical nickname.
func normalizedNicknameKey(display string) string {
	return strings.Map(func(character rune) rune {
		if character == zeroWidthJoiner || character == zeroWidthNonJoiner {
			return -1
		}
		return character
	}, strings.ToLower(display))
}
