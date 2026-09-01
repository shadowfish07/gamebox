package nickname

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

type nicknameFixture struct {
	SchemaVersion int `json:"schemaVersion"`
	Cases         []struct {
		Name       string `json:"name"`
		Input      string `json:"input"`
		Valid      bool   `json:"valid"`
		Display    string `json:"display"`
		Normalized string `json:"normalized"`
	} `json:"cases"`
}

func TestNormalizeNicknameMatchesSharedFixture(t *testing.T) {
	fixture := loadNicknameFixture(t)
	if fixture.SchemaVersion != 1 || len(fixture.Cases) == 0 {
		t.Fatalf("nickname fixture metadata = version %d cases %d", fixture.SchemaVersion, len(fixture.Cases))
	}
	for _, test := range fixture.Cases {
		t.Run(test.Name, func(t *testing.T) {
			display, normalized, err := Normalize(test.Input)
			if test.Valid {
				if err != nil || display != test.Display || normalized != test.Normalized {
					t.Fatalf("Normalize() = (%q, %q, %v), want (%q, %q, nil)", display, normalized, err, test.Display, test.Normalized)
				}
				return
			}
			if !errors.Is(err, ErrInvalid) || display != "" || normalized != "" {
				t.Fatalf("Normalize() = (%q, %q, %v), want empty values and ErrInvalid", display, normalized, err)
			}
		})
	}
}

func loadNicknameFixture(t *testing.T) nicknameFixture {
	t.Helper()
	path := filepath.Join("..", "..", "..", "protocol", "fixtures", "nickname_cases.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	var fixture nicknameFixture
	decoderErr := json.Unmarshal(data, &fixture)
	if decoderErr != nil {
		t.Fatalf("decode %s: %v", path, decoderErr)
	}
	return fixture
}
