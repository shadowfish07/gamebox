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
		{name: "embedded newline control", nickname: "A\nB"},
		{name: "embedded nul control", nickname: "A\x00B"},
		{name: "embedded c1 control", nickname: "A\u0085B"},
		{name: "zero width format", nickname: "A\u200bB"},
		{name: "only zero width formats", nickname: "\u200b\u200b"},
		{name: "bidi format", nickname: "A\u202eB"},
		{name: "only combining marks", nickname: "\u0301\u0302"},
		{name: "space wrapped combining marks", nickname: " \u0301\u0302 "},
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

func TestNicknameAllowsVisibleUnicodeBasesSpacesAndAttachedCombiningMarks(t *testing.T) {
	tests := []struct {
		name        string
		raw         string
		wantDisplay string
	}{
		{name: "Chinese", raw: " \u5c0f\u9c7c ", wantDisplay: "\u5c0f\u9c7c"},
		{name: "emoji symbols", raw: "\U0001F642\U0001F3AE", wantDisplay: "\U0001F642\U0001F3AE"},
		{name: "attached combining mark", raw: " e\u0301 ", wantDisplay: "e\u0301"},
		{name: "ordinary internal space", raw: "A B", wantDisplay: "A B"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			display, normalized, err := NormalizeNickname(test.raw)
			if err != nil {
				t.Fatalf("NormalizeNickname(%q) returned error: %v", test.raw, err)
			}
			if display != test.wantDisplay || normalized != strings.ToLower(test.wantDisplay) {
				t.Fatalf("NormalizeNickname(%q) = (%q, %q), want (%q, %q)", test.raw, display, normalized, test.wantDisplay, strings.ToLower(test.wantDisplay))
			}
		})
	}
}

func TestNicknameAllowsContextualEmojiZWJAndTextZWNJ(t *testing.T) {
	tests := []struct {
		name     string
		nickname string
	}{
		{name: "woman technologist", nickname: "\U0001F469\u200d\U0001F4BB"},
		{name: "family", nickname: "\U0001F468\u200d\U0001F469\u200d\U0001F467\u200d\U0001F466"},
		{name: "skin tone modifier", nickname: "\U0001F469\U0001F3FD\u200d\U0001F4BB"},
		{name: "family skin tones", nickname: "\U0001F468\U0001F3FD\u200d\U0001F469\U0001F3FD\u200d\U0001F467\U0001F3FD\u200d\U0001F466\U0001F3FD"},
		{name: "variation selector", nickname: "\u2764\ufe0f\u200d\U0001F525"},
		{name: "right base variation selector", nickname: "\U0001F3C3\u200d\u2640\ufe0f"},
		{name: "Persian non-joiner", nickname: "\u0645\u06cc\u200c\u062e\u0648\u0627\u0647\u0645"},
		{name: "text marks after adjacent bases", nickname: "\u0646\u064e\u200c\u0645\u0650"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			display, normalized, err := NormalizeNickname(test.nickname)
			if err != nil {
				t.Fatalf("NormalizeNickname(%q) returned error: %v", test.nickname, err)
			}
			wantNormalized := strings.NewReplacer("\u200c", "", "\u200d", "").Replace(strings.ToLower(test.nickname))
			if display != test.nickname || normalized != wantNormalized {
				t.Fatalf("NormalizeNickname(%q) = (%q, %q), want display %q and conservative key %q", test.nickname, display, normalized, test.nickname, wantNormalized)
			}
		})
	}
}

func TestNicknameRejectsUnsafeSeparatorsFormatsAndJoinerContexts(t *testing.T) {
	tests := []struct {
		name     string
		nickname string
	}{
		{name: "line separator", nickname: "A\u2028B"},
		{name: "paragraph separator", nickname: "A\u2029B"},
		{name: "trimmed trailing newline control", nickname: "AB\n"},
		{name: "trimmed leading line separator", nickname: "\u2028AB"},
		{name: "trimmed trailing paragraph separator", nickname: "AB\u2029"},
		{name: "leading joiner", nickname: "\u200dAB"},
		{name: "trailing joiner", nickname: "AB\u200d"},
		{name: "leading non-joiner", nickname: "\u200c\u0627\u0628"},
		{name: "trailing non-joiner", nickname: "\u0627\u0628\u200c"},
		{name: "consecutive joiners", nickname: "\U0001F642\u200d\u200d\U0001F4BB"},
		{name: "letters around ZWJ", nickname: "a\u200db"},
		{name: "space before joiner", nickname: "\U0001F642 \u200d\U0001F4BB"},
		{name: "space after joiner", nickname: "\U0001F642\u200d \U0001F4BB"},
		{name: "mark before right emoji base", nickname: "\U0001F642\u200d\ufe0f\U0001F4BB"},
		{name: "modifier before right emoji base", nickname: "\U0001F642\u200d\U0001F3FD\U0001F4BB"},
		{name: "symbols around ZWNJ", nickname: "\U0001F642\u200c\U0001F4BB"},
		{name: "space before ZWNJ", nickname: "\u0645 \u200c\u06cc"},
		{name: "mark before right text base", nickname: "\u0646\u200c\u0650\u0645"},
		{name: "zero width space", nickname: "A\u200bB"},
		{name: "soft hyphen", nickname: "A\u00adB"},
		{name: "word joiner", nickname: "A\u2060B"},
		{name: "byte order mark", nickname: "A\ufeffB"},
		{name: "left to right mark", nickname: "A\u200eB"},
		{name: "bidi override", nickname: "A\u202eB"},
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
