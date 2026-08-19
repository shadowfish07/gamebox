package protocol

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
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

func TestFixturesAllowSemanticallyOmittedMatchFields(t *testing.T) {
	valid := []string{
		`{"protocolVersion":1,"type":"platform.connect","payload":{"launchTicket":"opaque"}}`,
		`{"protocolVersion":1,"type":"platform.error","payload":{"code":"ticket_invalid","message":"invalid","details":{}}}`,
	}
	for _, input := range valid {
		if _, err := Decode([]byte(input)); err != nil {
			t.Fatalf("Decode rejected semantically omitted match fields: %v", err)
		}
	}
}

func TestFixturesRejectNonCanonicalEnvelopeJSON(t *testing.T) {
	action := `{"protocolVersion":1,"gameId":"gomoku","matchId":"11111111-1111-4111-8111-111111111111","expectedRevision":3,"type":"gomoku.move.requested","actionId":"33333333-3333-4333-8333-333333333333","payload":{"x":7,"y":7}}`
	snapshot := `{"protocolVersion":1,"gameId":"gomoku","matchId":"11111111-1111-4111-8111-111111111111","revision":3,"type":"platform.snapshot","payload":{}}`

	caseVariants := map[string]string{
		"protocolVersion":  "ProtocolVersion",
		"gameId":           "GameId",
		"matchId":          "MatchId",
		"revision":         "Revision",
		"expectedRevision": "ExpectedRevision",
		"type":             "Type",
		"actionId":         "ActionId",
		"payload":          "Payload",
	}
	for canonical, variant := range caseVariants {
		base := action
		if canonical == "revision" {
			base = snapshot
		}
		input := strings.Replace(base, `"`+canonical+`":`, `"`+variant+`":`, 1)
		t.Run("exact case "+canonical, func(t *testing.T) {
			if _, err := Decode([]byte(input)); err == nil {
				t.Fatalf("Decode accepted non-canonical key %q", variant)
			}
		})
	}

	duplicates := map[string]string{
		"protocolVersion":  strings.Replace(action, `"protocolVersion":1`, `"protocolVersion":2,"protocolVersion":1`, 1),
		"gameId":           strings.Replace(action, `"gameId":"gomoku"`, `"gameId":null,"gameId":"gomoku"`, 1),
		"matchId":          strings.Replace(action, `"matchId":"11111111-1111-4111-8111-111111111111"`, `"matchId":"","matchId":"11111111-1111-4111-8111-111111111111"`, 1),
		"revision":         strings.Replace(snapshot, `"revision":3`, `"revision":-1,"revision":3`, 1),
		"expectedRevision": strings.Replace(action, `"expectedRevision":3`, `"expectedRevision":-1,"expectedRevision":3`, 1),
		"type":             strings.Replace(action, `"type":"gomoku.move.requested"`, `"type":"unknown.message","type":"gomoku.move.requested"`, 1),
		"actionId":         strings.Replace(action, `"actionId":"33333333-3333-4333-8333-333333333333"`, `"actionId":"","actionId":"33333333-3333-4333-8333-333333333333"`, 1),
		"payload":          strings.Replace(action, `"payload":{"x":7,"y":7}`, `"payload":null,"payload":{"x":7,"y":7}`, 1),
	}
	for field, input := range duplicates {
		t.Run("duplicate "+field, func(t *testing.T) {
			if _, err := Decode([]byte(input)); err == nil {
				t.Fatalf("Decode accepted duplicate key %q", field)
			}
		})
	}

	invalid := map[string]string{
		"trailing comma":           strings.TrimSuffix(action, "}") + ",}",
		"escaped top-level key":    strings.Replace(action, `"gameId":`, `"game\u0049d":`, 1),
		"empty game id on connect": `{"protocolVersion":1,"gameId":"","type":"platform.connect","payload":{}}`,
		"empty ids on error":       `{"protocolVersion":1,"gameId":"","matchId":"","type":"platform.error","payload":{}}`,
	}
	for name, input := range invalid {
		t.Run(name, func(t *testing.T) {
			if _, err := Decode([]byte(input)); err == nil {
				t.Fatal("Decode succeeded, want error")
			}
		})
	}

	validStringPayload := strings.Replace(
		action,
		`{"x":7,"y":7}`,
		`{"text":"escaped quote: \" and key text: \"revision\":999, {}[]","nested":{"Type":"payload keys stay opaque"}}`,
		1,
	)
	if _, err := Decode([]byte(validStringPayload)); err != nil {
		t.Fatalf("key-like string content was misclassified: %v", err)
	}
}

func TestFixturesEnforceSafeJSONIntegerRange(t *testing.T) {
	wrapPayload := func(payload string) string {
		return `{"protocolVersion":1,"gameId":"gomoku","matchId":"11111111-1111-4111-8111-111111111111","expectedRevision":3,"type":"gomoku.move.requested","actionId":"33333333-3333-4333-8333-333333333333","payload":` + payload + `}`
	}
	valid := []string{
		wrapPayload(`{"minimum":-9007199254740991,"maximum":9007199254740991,"fraction":1.25,"nested":[0,{"fraction":-0.5}]}`),
		wrapPayload(`{"decimalBoundary":9007199254740991.0,"exponentBoundary":90071992547409910e-1}`),
		wrapPayload(`{"zeroExponent":1e0000000,"positiveExponent":1e+0000001}`),
		wrapPayload(`{"largeIntegerAsString":"9007199254740992"}`),
	}
	for _, input := range valid {
		if _, err := Decode([]byte(input)); err != nil {
			t.Fatalf("Decode rejected safe numeric payload: %v", err)
		}
	}

	invalid := []string{
		wrapPayload(`{"tooLarge":9007199254740992}`),
		wrapPayload(`{"tooSmall":-9007199254740992}`),
		wrapPayload(`{"nested":[{"tooLarge":9007199254740992}]}`),
		wrapPayload(`{"decimalTooLarge":9007199254740992.0}`),
		wrapPayload(`{"exponentTooLarge":90071992547409920e-1}`),
		wrapPayload(`{"roundedFraction":1.00000000000000001}`),
		wrapPayload(`{"roundedLargeFraction":9007199254740990.5}`),
		wrapPayload(`{"roundedUnsafeFraction":9007199254740991.5}`),
		wrapPayload(`{"duplicate":9007199254740992,"duplicate":1}`),
		`{"protocolVersion":1,"gameId":"gomoku","matchId":"11111111-1111-4111-8111-111111111111","expectedRevision":9007199254740992,"type":"gomoku.move.requested","actionId":"33333333-3333-4333-8333-333333333333","payload":{}}`,
	}
	for _, input := range invalid {
		if _, err := Decode([]byte(input)); err == nil {
			t.Fatalf("Decode accepted unsafe JSON integer: %s", input)
		}
	}
}

func TestProtocolResourceLimits(t *testing.T) {
	wrapPayload := func(payload string) string {
		return `{"protocolVersion":1,"gameId":"gomoku","matchId":"11111111-1111-4111-8111-111111111111","expectedRevision":3,"type":"gomoku.move.requested","actionId":"33333333-3333-4333-8333-333333333333","payload":` + payload + `}`
	}

	if MaxMessageBytes != 64*1024 || MaxJSONDepth != 32 || MaxNumberTokenBytes != 128 {
		t.Fatalf("unexpected protocol resource limits: %d/%d/%d", MaxMessageBytes, MaxJSONDepth, MaxNumberTokenBytes)
	}
	validNumber := "1." + strings.Repeat("0", MaxNumberTokenBytes-2)
	if len(validNumber) != MaxNumberTokenBytes {
		t.Fatalf("valid number token length = %d", len(validNumber))
	}
	if _, err := Decode([]byte(wrapPayload(`{"number":` + validNumber + `}`))); err != nil {
		t.Fatalf("Decode rejected number token at limit: %v", err)
	}

	validNested := "0"
	for range MaxJSONDepth - 2 {
		validNested = "[" + validNested + "]"
	}
	if _, err := Decode([]byte(wrapPayload(`{"nested":` + validNested + `}`))); err != nil {
		t.Fatalf("Decode rejected JSON at depth limit: %v", err)
	}

	tooDeep := "[" + validNested + "]"
	invalid := map[string]string{
		"oversized message": wrapPayload(`{"text":"` + strings.Repeat("x", MaxMessageBytes) + `"}`),
		"too deep array":    wrapPayload(`{"nested":` + tooDeep + `}`),
		"long mantissa":     wrapPayload(`{"number":` + strings.Repeat("1", MaxNumberTokenBytes+1) + `}`),
		"long exponent":     wrapPayload(`{"number":1e+` + strings.Repeat("0", MaxNumberTokenBytes-2) + `1}`),
		"deep object":       wrapPayload(`{"nested":` + strings.Repeat(`{"x":`, MaxJSONDepth) + `0` + strings.Repeat(`}`, MaxJSONDepth) + `}`),
	}
	for name, input := range invalid {
		t.Run(name, func(t *testing.T) {
			if _, err := Decode([]byte(input)); err == nil {
				t.Fatal("Decode succeeded, want resource-limit error")
			}
		})
	}

	started := time.Now()
	for range 25 {
		for _, input := range invalid {
			_, _ = Decode([]byte(input))
		}
	}
	if elapsed := time.Since(started); elapsed > 10*time.Second {
		t.Fatalf("bounded invalid inputs took %s", elapsed)
	}
}

func TestProtocolErrorsNeverEchoUntrustedInput(t *testing.T) {
	markers := []string{
		"secret_field_marker",
		"secret_type_marker",
		"987654321098765432109876543210",
		"secret_payload_marker",
	}
	inputs := []string{
		`{"protocolVersion":1,"type":"platform.connect","payload":{},"secret_field_marker":true}`,
		`{"protocolVersion":1,"type":"secret_type_marker","payload":{}}`,
		`{"protocolVersion":1,"type":"platform.connect","payload":{"n":987654321098765432109876543210}}`,
		`{"protocolVersion":1,"type":"platform.connect","payload":{"secret_payload_marker":}}`,
	}
	for _, input := range inputs {
		_, err := Decode([]byte(input))
		if err == nil {
			t.Fatal("Decode succeeded, want protocol error")
		}
		var protocolError *ProtocolError
		if !errors.As(err, &protocolError) {
			t.Fatalf("error %T is not a ProtocolError", err)
		}
		if protocolError.Code == "" || len(protocolError.Error()) > 128 {
			t.Fatalf("protocol error contract is missing or unbounded: %#v", protocolError)
		}
		for _, marker := range markers {
			if strings.Contains(protocolError.Error(), marker) {
				t.Fatalf("protocol error echoed untrusted marker %q", marker)
			}
		}
	}
}

func fixtureDirectory(t *testing.T) string {
	t.Helper()
	directory, err := os.Getwd()
	if err != nil {
		t.Fatalf("get test working directory: %v", err)
	}
	for {
		fixtureDir := filepath.Join(directory, "protocol", "fixtures")
		if fileExists(filepath.Join(directory, "protocol", "README.md")) && fileExists(filepath.Join(directory, "server", "go.mod")) {
			return fixtureDir
		}
		parent := filepath.Dir(directory)
		if parent == directory {
			t.Fatal("find repository root containing protocol/README.md and server/go.mod")
		}
		directory = parent
	}
}

func fileExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
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
