package results

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestSharedFixtureValidatesAndEncodesCanonically(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "protocol", "fixtures", "game_result.json"))
	if err != nil {
		t.Fatal(err)
	}
	var result GameResult
	if err := json.Unmarshal(data, &result); err != nil {
		t.Fatal(err)
	}
	encoded, err := ValidateAndEncode(result)
	if err != nil {
		t.Fatal(err)
	}
	want := bytes.TrimSpace(data)
	if !bytes.Equal(encoded, want) {
		t.Fatalf("canonical fixture mismatch\n got %s\nwant %s", encoded, want)
	}
	if hash, err := Hash(encoded); err != nil || len(hash) != 64 {
		t.Fatalf("Hash() = %q, %v", hash, err)
	}
}

func TestRejectsDiscontinuousOrInconsistentResult(t *testing.T) {
	result := fixtureResult(t)
	result.Events[1].Revision = 3
	if _, err := ValidateAndEncode(result); err == nil {
		t.Fatal("accepted revision gap")
	}
	result = fixtureResult(t)
	result.WinnerUserID = nil
	if _, err := ValidateAndEncode(result); err == nil {
		t.Fatal("accepted missing winner")
	}
}

func fixtureResult(t *testing.T) GameResult {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "protocol", "fixtures", "game_result.json"))
	if err != nil {
		t.Fatal(err)
	}
	var result GameResult
	if err := json.Unmarshal(data, &result); err != nil {
		t.Fatal(err)
	}
	return result
}
