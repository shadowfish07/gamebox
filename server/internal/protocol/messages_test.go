package protocol

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"
)

func TestFixtures(t *testing.T) {
	fixtureDir := fixtureDirectory(t)
	paths, err := filepath.Glob(filepath.Join(fixtureDir, "*.json"))
	if err != nil {
		t.Fatalf("glob fixtures: %v", err)
	}
	if len(paths) != 4 {
		t.Fatalf("fixture count = %d, want 4", len(paths))
	}

	wantTypes := map[string]string{
		"snapshot.json":      TypePlatformSnapshot,
		"move_action.json":   TypeGomokuMoveRequested,
		"move_accepted.json": TypeGomokuMoveAccepted,
		"error.json":         TypePlatformError,
	}

	for _, path := range paths {
		path := path
		name := filepath.Base(path)
		t.Run(name, func(t *testing.T) {
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("read fixture: %v", err)
			}

			envelope, err := Decode(data)
			if err != nil {
				t.Fatalf("decode fixture: %v", err)
			}
			if envelope.ProtocolVersion != Version1 {
				t.Fatalf("protocolVersion = %d, want %d", envelope.ProtocolVersion, Version1)
			}
			if envelope.Type == "" {
				t.Fatal("type is required")
			}
			if envelope.Type != wantTypes[name] {
				t.Fatalf("type = %q, want %q", envelope.Type, wantTypes[name])
			}
			if envelope.Revision != nil && envelope.ExpectedRevision != nil {
				t.Fatal("revision and expectedRevision must be mutually exclusive")
			}

			if name == "move_action.json" {
				if envelope.ActionID == "" {
					t.Fatal("client action fixture must contain actionId")
				}
				if envelope.ExpectedRevision == nil {
					t.Fatal("client action fixture must contain expectedRevision")
				}
				if envelope.Revision != nil {
					t.Fatal("client action fixture must not contain revision")
				}
			} else {
				if envelope.Revision == nil {
					t.Fatal("bound server fixture must contain revision")
				}
				if envelope.ExpectedRevision != nil {
					t.Fatal("server fixture must not contain expectedRevision")
				}
			}

			encoded, err := json.Marshal(envelope)
			if err != nil {
				t.Fatalf("marshal fixture: %v", err)
			}
			assertJSONSemanticallyEqual(t, data, encoded)
		})
	}
}

func TestFixturesSnapshotHasExactBoardAndNullResults(t *testing.T) {
	data, err := os.ReadFile(filepath.Join(fixtureDirectory(t), "snapshot.json"))
	if err != nil {
		t.Fatalf("read snapshot fixture: %v", err)
	}
	envelope, err := Decode(data)
	if err != nil {
		t.Fatalf("decode snapshot fixture: %v", err)
	}

	var payload struct {
		Board        []json.Number `json:"board"`
		BoardSize    json.Number   `json:"boardSize"`
		WinnerUserID any           `json:"winnerUserId"`
		Result       any           `json:"result"`
	}
	decoder := json.NewDecoder(bytes.NewReader(envelope.Payload))
	decoder.UseNumber()
	if err := decoder.Decode(&payload); err != nil {
		t.Fatalf("decode snapshot payload: %v", err)
	}
	if len(payload.Board) != 225 {
		t.Fatalf("board length = %d, want 225", len(payload.Board))
	}
	for index, cell := range payload.Board {
		if cell.String() != "0" {
			t.Fatalf("board[%d] = %s, want integer 0", index, cell)
		}
	}
	if payload.BoardSize.String() != "15" {
		t.Fatalf("boardSize = %s, want integer 15", payload.BoardSize)
	}
	if payload.WinnerUserID != nil || payload.Result != nil {
		t.Fatalf("winnerUserId and result must remain JSON null: %#v %#v", payload.WinnerUserID, payload.Result)
	}
}

func TestFixturesRejectInvalidEnvelopeShapes(t *testing.T) {
	valid := `{"protocolVersion":1,"gameId":"gomoku","matchId":"11111111-1111-4111-8111-111111111111","expectedRevision":3,"type":"gomoku.move.requested","actionId":"33333333-3333-4333-8333-333333333333","payload":{"x":7,"y":7}}`
	tests := map[string]string{
		"unknown top-level field":   strings.Replace(valid, `"payload":`, `"unexpected":true,"payload":`, 1),
		"unsupported version":       strings.Replace(valid, `"protocolVersion":1`, `"protocolVersion":2`, 1),
		"missing type":              strings.Replace(valid, `"type":"gomoku.move.requested",`, "", 1),
		"missing payload":           strings.Replace(valid, `,"payload":{"x":7,"y":7}`, "", 1),
		"null payload":              strings.Replace(valid, `"payload":{"x":7,"y":7}`, `"payload":null`, 1),
		"null optional identifier":  `{"protocolVersion":1,"gameId":null,"type":"platform.connect","payload":{}}`,
		"null optional revision":    `{"protocolVersion":1,"gameId":"gomoku","matchId":"11111111-1111-4111-8111-111111111111","revision":null,"type":"platform.pong","payload":{"nonce":"n1"}}`,
		"both revisions":            strings.Replace(valid, `"expectedRevision":3`, `"revision":3,"expectedRevision":3`, 1),
		"missing action id":         strings.Replace(valid, `,"actionId":"33333333-3333-4333-8333-333333333333"`, "", 1),
		"missing expected revision": strings.Replace(valid, `,"expectedRevision":3`, "", 1),
		"revisionless server ping":  `{"protocolVersion":1,"gameId":"gomoku","matchId":"11111111-1111-4111-8111-111111111111","type":"platform.ping","payload":{"nonce":"n1"}}`,
		"trailing document":         valid + `{}`,
	}
	for name, input := range tests {
		t.Run(name, func(t *testing.T) {
			if _, err := Decode([]byte(input)); err == nil {
				t.Fatal("Decode succeeded, want error")
			}
		})
	}
}

func TestFixturesPayloadFieldsRemainOpaque(t *testing.T) {
	input := []byte(`{"protocolVersion":1,"gameId":"gomoku","matchId":"11111111-1111-4111-8111-111111111111","expectedRevision":3,"type":"gomoku.move.requested","actionId":"33333333-3333-4333-8333-333333333333","payload":{"gameSpecificExtra":null,"fraction":1.25}}`)
	envelope, err := Decode(input)
	if err != nil {
		t.Fatalf("decode message-specific payload: %v", err)
	}
	encoded, err := json.Marshal(envelope)
	if err != nil {
		t.Fatalf("marshal message-specific payload: %v", err)
	}
	assertJSONSemanticallyEqual(t, input, encoded)
}

func fixtureDirectory(t *testing.T) string {
	t.Helper()
	_, filename, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("resolve fixture test source path")
	}
	return filepath.Clean(filepath.Join(filepath.Dir(filename), "..", "..", "..", "protocol", "fixtures"))
}

func assertJSONSemanticallyEqual(t *testing.T, want, got []byte) {
	t.Helper()
	decode := func(data []byte) any {
		decoder := json.NewDecoder(bytes.NewReader(data))
		decoder.UseNumber()
		var value any
		if err := decoder.Decode(&value); err != nil {
			t.Fatalf("decode JSON for comparison: %v", err)
		}
		return value
	}
	if wantValue, gotValue := decode(want), decode(got); !reflect.DeepEqual(wantValue, gotValue) {
		t.Fatalf("JSON changed during round trip\nwant: %s\n got: %s", want, got)
	}
}
