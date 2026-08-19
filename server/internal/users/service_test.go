package users

import (
	"errors"
	"strings"
	"testing"
	"unicode/utf8"
)

func TestNicknameNormalizationPreservesTrimmedDisplayAndFoldsCase(t *testing.T) {
	display, normalized, err := NormalizeNickname("\u2003Alice-\u4e2d\U0001F642\u2003")
	if err != nil {
		t.Fatalf("NormalizeNickname returned error: %v", err)
	}
	if display != "Alice-\u4e2d\U0001F642" {
		t.Fatalf("display = %q, want trimmed original case", display)
	}
	if normalized != "alice-\u4e2d\U0001F642" {
		t.Fatalf("normalized = %q, want case-folded display", normalized)
	}
}

func TestNicknameAcceptsInclusiveUnicodeRuneBoundaries(t *testing.T) {
	for _, nickname := range []string{"\u754c\U0001F642", strings.Repeat("\u754c", 16)} {
		display, normalized, err := NormalizeNickname(nickname)
		if err != nil {
			t.Errorf("NormalizeNickname(%q) returned error: %v", nickname, err)
			continue
		}
		if display != nickname || normalized != strings.ToLower(nickname) {
			t.Errorf("NormalizeNickname(%q) = (%q, %q), want preserved display and lower-case normalized form", nickname, display, normalized)
		}
		if count := utf8.RuneCountInString(display); count < 2 || count > 16 {
			t.Errorf("accepted display rune count = %d, want within 2..16", count)
		}
	}
}

func TestNicknameRejectsInvalidUTF8WhitespaceAndRuneLengths(t *testing.T) {
	tests := []struct {
		name     string
		nickname string
	}{
		{name: "empty", nickname: ""},
		{name: "unicode whitespace", nickname: " \t\n\u2003 "},
		{name: "one rune", nickname: "\U0001F642"},
		{name: "seventeen runes", nickname: strings.Repeat("\u754c", 17)},
		{name: "invalid utf8", nickname: string([]byte{'A', 0xff})},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			display, normalized, err := NormalizeNickname(test.nickname)
			if !errors.Is(err, ErrInvalidNickname) {
				t.Fatalf("NormalizeNickname(%q) error = %v, want ErrInvalidNickname", test.nickname, err)
			}
			if display != "" || normalized != "" {
				t.Fatalf("invalid nickname returned (%q, %q), want no derived values", display, normalized)
			}
		})
	}
}
