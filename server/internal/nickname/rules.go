// Package nickname owns the mobile-safe nickname rules shared by public and
// LAN identities.
package nickname

import (
	"errors"
	"strings"
	"unicode"
	"unicode/utf8"
)

const (
	minimumRunes       = 2
	maximumRunes       = 16
	zeroWidthNonJoiner = '\u200c'
	zeroWidthJoiner    = '\u200d'
)

// ErrInvalid is stable and deliberately contains no submitted text.
var ErrInvalid = errors.New("invalid nickname")

// Normalize trims surrounding Unicode whitespace, preserves the display
// spelling, and derives a conservative case-insensitive key.
func Normalize(raw string) (display string, normalized string, err error) {
	if !utf8.ValidString(raw) {
		return "", "", ErrInvalid
	}
	for _, character := range raw {
		if isForbiddenControlOrSeparator(character) {
			return "", "", ErrInvalid
		}
	}
	display = strings.TrimSpace(raw)
	runeCount := utf8.RuneCountInString(display)
	if runeCount < minimumRunes || runeCount > maximumRunes {
		return "", "", ErrInvalid
	}
	characters := []rune(display)
	hasVisibleBase := false
	for index, character := range characters {
		if unicode.Is(unicode.Cf, character) {
			switch character {
			case zeroWidthJoiner:
				if !validEmojiJoinerContext(characters, index) {
					return "", "", ErrInvalid
				}
			case zeroWidthNonJoiner:
				if !validTextNonJoinerContext(characters, index) {
					return "", "", ErrInvalid
				}
			default:
				return "", "", ErrInvalid
			}
		}
		if unicode.IsLetter(character) || unicode.IsNumber(character) || unicode.IsPunct(character) || unicode.IsSymbol(character) {
			hasVisibleBase = true
		}
	}
	if !hasVisibleBase {
		return "", "", ErrInvalid
	}
	return display, normalizedKey(display), nil
}

func isForbiddenControlOrSeparator(character rune) bool {
	return unicode.Is(unicode.Cc, character) || unicode.Is(unicode.Zl, character) || unicode.Is(unicode.Zp, character)
}

func validEmojiJoinerContext(characters []rune, joinerIndex int) bool {
	left, leftFound := precedingBase(characters, joinerIndex, isEmojiDecoration)
	rightIndex := joinerIndex + 1
	return leftFound && unicode.Is(unicode.So, left) && rightIndex < len(characters) && unicode.Is(unicode.So, characters[rightIndex])
}

func validTextNonJoinerContext(characters []rune, joinerIndex int) bool {
	left, leftFound := precedingBase(characters, joinerIndex, unicode.IsMark)
	rightIndex := joinerIndex + 1
	return leftFound && unicode.IsLetter(left) && rightIndex < len(characters) && unicode.IsLetter(characters[rightIndex])
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

func normalizedKey(display string) string {
	return strings.Map(func(character rune) rune {
		if character == zeroWidthJoiner || character == zeroWidthNonJoiner {
			return -1
		}
		return character
	}, strings.ToLower(display))
}
