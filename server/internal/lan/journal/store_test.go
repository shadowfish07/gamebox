package journal

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Each test names the production change it protects: removing durable chain
// validation, changing canonical serialization, or trusting the projection.
func TestAppendWritesFirstCanonicalRecord(t *testing.T) {
	root := t.TempDir()
	store, records, err := Open(root, nil)
	if err != nil {
		t.Fatalf("Open() error = %v", err)
	}
	cleanupStore(t, store)
	if len(records) != 0 {
		t.Fatalf("Open() records = %d, want 0", len(records))
	}

	record, err := store.Append(context.Background(), Draft{
		Type:     "room.created",
		ActionID: stringPtr("create-1"),
		Payload:  json.RawMessage(`{"roomId":"room-1","players":[],"createdAt":1}`),
	})
	if err != nil {
		t.Fatalf("Append() error = %v", err)
	}
	if record.SchemaVersion != 1 || record.JournalSequence != 1 || record.PreviousHash != "" {
		t.Fatalf("first record = %#v", record)
	}
	if !isLowerSHA256(record.Hash) {
		t.Fatalf("first hash = %q, want lower-case SHA-256", record.Hash)
	}

	contents, err := os.ReadFile(filepath.Join(root, "0000000000000001.json"))
	if err != nil {
		t.Fatalf("read record: %v", err)
	}
	want := `{"schemaVersion":1,"journalSequence":1,"gameRevision":null,"type":"room.created","actionId":"create-1","payload":{"createdAt":1,"players":[],"roomId":"room-1"},"previousHash":"","hash":"` + record.Hash + `"}`
	if string(contents) != want {
		t.Fatalf("canonical record = %s\nwant %s", contents, want)
	}
}

func TestAppendChainsConsecutiveRecords(t *testing.T) {
	store, _, err := Open(t.TempDir(), nil)
	if err != nil {
		t.Fatalf("Open() error = %v", err)
	}
	cleanupStore(t, store)
	first, err := store.Append(context.Background(), Draft{Type: "room.created", Payload: json.RawMessage(`{"createdAt":1}`)})
	if err != nil {
		t.Fatalf("first Append() error = %v", err)
	}
	revision := int64(1)
	second, err := store.Append(context.Background(), Draft{Type: "game.event", GameRevision: &revision, Payload: json.RawMessage(`{"move":1}`)})
	if err != nil {
		t.Fatalf("second Append() error = %v", err)
	}
	if second.JournalSequence != 2 || second.PreviousHash != first.Hash || second.GameRevision == nil || *second.GameRevision != 1 {
		t.Fatalf("second record = %#v, first hash = %q", second, first.Hash)
	}
	got := store.Records()
	if len(got) != 2 || got[0].Hash != first.Hash || got[1].Hash != second.Hash {
		t.Fatalf("Records() = %#v", got)
	}
}

func TestOpenCleansOnlyRecognizedJournalTemps(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "0000000000000001.json.tmp"), []byte("partial"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "manifest.json.tmp"), []byte("partial manifest"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "unrelated.tmp"), []byte("keep"), 0o600); err != nil {
		t.Fatal(err)
	}
	store, _, err := Open(root, nil)
	if err != nil {
		t.Fatalf("Open() error = %v", err)
	}
	cleanupStore(t, store)
	if _, err := os.Stat(filepath.Join(root, "0000000000000001.json.tmp")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("journal temp stat error = %v, want not exist", err)
	}
	if _, err := os.Stat(filepath.Join(root, "manifest.json.tmp")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("manifest temp stat error = %v, want not exist", err)
	}
	if got, err := os.ReadFile(filepath.Join(root, "unrelated.tmp")); err != nil || string(got) != "keep" {
		t.Fatalf("unrelated temp = %q, %v; want preserved", got, err)
	}
}

func TestOpenRejectsCorruptAndNonContiguousCommittedRecords(t *testing.T) {
	for _, testCase := range []struct {
		fixture  string
		want     error
		contains string
	}{
		{fixture: "corrupt_hash", want: ErrInvalidRecord, contains: "current hash does not verify"},
		{fixture: "sequence_gap", want: ErrJournalSequenceGap, contains: "sequence gap"},
	} {
		t.Run(testCase.fixture, func(t *testing.T) {
			root := t.TempDir()
			copyFixtureTree(t, testCase.fixture, root)
			if _, _, err := Open(root, nil); !errors.Is(err, ErrJournalCorrupt) || !errors.Is(err, testCase.want) || !strings.Contains(err.Error(), testCase.contains) {
				t.Fatalf("Open() error = %v, want ErrJournalCorrupt and %v containing %q", err, testCase.want, testCase.contains)
			}
		})
	}
}

func TestOpenClassifiesCommittedContentFailuresButNotOperationalFailures(t *testing.T) {
	t.Run("invalid committed filename", func(t *testing.T) {
		root := t.TempDir()
		if err := os.WriteFile(filepath.Join(root, "1.json"), []byte(`{}`), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, _, err := Open(root, nil); !errors.Is(err, ErrJournalCorrupt) {
			t.Fatalf("Open() error = %v, want ErrJournalCorrupt", err)
		}
	})

	t.Run("decode and record semantics", func(t *testing.T) {
		for name, contents := range map[string][]byte{
			"decode":   []byte(`{`),
			"semantic": []byte(`{"schemaVersion":2,"journalSequence":1,"gameRevision":null,"type":"room.created","actionId":null,"payload":{"createdAt":1},"previousHash":"","hash":"0000000000000000000000000000000000000000000000000000000000000000"}`),
		} {
			t.Run(name, func(t *testing.T) {
				root := t.TempDir()
				if err := os.WriteFile(filepath.Join(root, "0000000000000001.json"), contents, 0o600); err != nil {
					t.Fatal(err)
				}
				if _, _, err := Open(root, nil); !errors.Is(err, ErrJournalCorrupt) {
					t.Fatalf("Open() error = %v, want ErrJournalCorrupt", err)
				}
			})
		}
	})

	t.Run("operational root error", func(t *testing.T) {
		root := filepath.Join(t.TempDir(), "not-a-directory")
		if err := os.WriteFile(root, []byte("file"), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, _, err := Open(root, nil); err == nil || errors.Is(err, ErrJournalCorrupt) {
			t.Fatalf("Open() error = %v, want non-corruption operational error", err)
		}
	})
}

func TestSequenceGapFixturesContainCanonicalChainRecords(t *testing.T) {
	first, err := makeRecord(1, "", Draft{Type: "room.created", Payload: json.RawMessage(`{"createdAt":1}`)})
	if err != nil {
		t.Fatal(err)
	}
	second, err := makeRecord(2, first.Hash, Draft{Type: "credential.issued", Payload: json.RawMessage(`{}`)})
	if err != nil {
		t.Fatal(err)
	}
	third, err := makeRecord(3, second.Hash, Draft{Type: "credential.issued", Payload: json.RawMessage(`{}`)})
	if err != nil {
		t.Fatal(err)
	}
	for name, record := range map[string]Record{
		"0000000000000001.json": first,
		"0000000000000003.json": third,
	} {
		want, err := canonicalRecord(record)
		if err != nil {
			t.Fatal(err)
		}
		got, err := os.ReadFile(filepath.Join("testdata", "sequence_gap", name))
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(got, want) {
			t.Fatalf("fixture %s is not its valid canonical chain record\ngot  %s\nwant %s", name, got, want)
		}
	}
}

func TestCorruptHashFixtureReachesHashVerification(t *testing.T) {
	root := t.TempDir()
	copyFixtureTree(t, "corrupt_hash", root)
	if _, _, err := Open(root, nil); !errors.Is(err, ErrInvalidRecord) || !strings.Contains(err.Error(), "current hash does not verify") {
		t.Fatalf("Open() error = %v, want hash-verification rejection", err)
	}
}

func TestOpenRejectsReorderedDuplicateMalformedAndUnverifiableRecords(t *testing.T) {
	t.Run("reordered hash chain", func(t *testing.T) {
		root, records := journalWithTwoRecords(t)
		if err := os.Rename(filepath.Join(root, "0000000000000001.json"), filepath.Join(root, "0000000000000003.json")); err != nil {
			t.Fatal(err)
		}
		if err := os.Rename(filepath.Join(root, "0000000000000002.json"), filepath.Join(root, "0000000000000001.json")); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, "0000000000000002.json"), records[0], 0o600); err != nil {
			t.Fatal(err)
		}
		if _, _, err := Open(root, nil); !errors.Is(err, ErrJournalCorrupt) {
			t.Fatalf("Open() error = %v, want ErrJournalCorrupt for reordered chain", err)
		}
	})
	t.Run("duplicate sequence filename", func(t *testing.T) {
		root, records := journalWithTwoRecords(t)
		if err := os.WriteFile(filepath.Join(root, "00000000000000001.json"), records[0], 0o600); err != nil {
			t.Fatal(err)
		}
		if _, _, err := Open(root, nil); !errors.Is(err, ErrJournalCorrupt) {
			t.Fatalf("Open() error = %v, want ErrJournalCorrupt for duplicate sequence filename", err)
		}
	})
	t.Run("wrong previous hash", func(t *testing.T) {
		rootA, _ := journalWithTwoRecords(t)
		rootB := t.TempDir()
		storeB, _, err := Open(rootB, nil)
		if err != nil {
			t.Fatal(err)
		}
		cleanupStore(t, storeB)
		if _, err := storeB.Append(context.Background(), Draft{Type: "different.created", Payload: json.RawMessage(`{}`)}); err != nil {
			t.Fatal(err)
		}
		if _, err := storeB.Append(context.Background(), Draft{Type: "credential.issued", Payload: json.RawMessage(`{}`)}); err != nil {
			t.Fatal(err)
		}
		otherSecond, err := os.ReadFile(filepath.Join(rootB, "0000000000000002.json"))
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(rootA, "0000000000000002.json"), otherSecond, 0o600); err != nil {
			t.Fatal(err)
		}
		if _, _, err := Open(rootA, nil); !errors.Is(err, ErrJournalCorrupt) {
			t.Fatalf("Open() error = %v, want ErrJournalCorrupt for wrong previous hash", err)
		}
	})
	for name, mutate := range map[string]func([]byte) []byte{
		"invalid JSON": func([]byte) []byte { return []byte(`{`) },
		"unknown field": func([]byte) []byte {
			return []byte(`{"schemaVersion":1,"journalSequence":1,"gameRevision":null,"type":"room.created","actionId":null,"payload":{},"previousHash":"","hash":"0000000000000000000000000000000000000000000000000000000000000000","extra":true}`)
		},
		"wrong current hash": func(data []byte) []byte {
			value := string(data)
			lastHashDigit := len(value) - 3
			replacement := byte('0')
			if value[lastHashDigit] == replacement {
				replacement = '1'
			}
			return []byte(value[:lastHashDigit] + string(replacement) + value[lastHashDigit+1:])
		},
	} {
		t.Run(name, func(t *testing.T) {
			root, records := journalWithTwoRecords(t)
			mutated := mutate(records[0])
			if name == "wrong current hash" && bytes.Equal(mutated, records[0]) {
				t.Fatal("hash corruption test did not change a hexadecimal digit")
			}
			if err := os.WriteFile(filepath.Join(root, "0000000000000001.json"), mutated, 0o600); err != nil {
				t.Fatal(err)
			}
			if _, _, err := Open(root, nil); !errors.Is(err, ErrJournalCorrupt) {
				t.Fatalf("Open() error = %v, want ErrJournalCorrupt", err)
			}
		})
	}
}

func TestAppendRejectsOversizedPayloadBeforeFileOperation(t *testing.T) {
	root := t.TempDir()
	ops := &recordingFileOps{root: root}
	store, _, err := Open(root, ops)
	if err != nil {
		t.Fatal(err)
	}
	cleanupStore(t, store)
	exactPayload := validJSONStringOfLength(maxPayloadBytes)
	if record, err := store.Append(context.Background(), Draft{Type: "credential.issued", Payload: exactPayload}); err != nil {
		t.Fatalf("Append() exact %d-byte canonical payload error = %v", maxPayloadBytes, err)
	} else if got := len(record.Payload); got != maxPayloadBytes {
		t.Fatalf("accepted canonical payload bytes = %d, want %d", got, maxPayloadBytes)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	store, records, err := Open(root, ops)
	if err != nil || len(records) != 1 || len(records[0].Payload) != maxPayloadBytes {
		t.Fatalf("Open() exact payload = (%d records, %v), want one replayable %d-byte payload", len(records), err, maxPayloadBytes)
	}
	defer store.Close()
	callsBeforeOversize := len(ops.calls)
	if _, err := store.Append(context.Background(), Draft{Type: "credential.issued", Payload: validJSONStringOfLength(maxPayloadBytes + 1)}); !errors.Is(err, ErrInvalidDraft) {
		t.Fatalf("Append() %d-byte canonical payload error = %v, want ErrInvalidDraft", maxPayloadBytes+1, err)
	}
	if got := len(ops.calls); got != callsBeforeOversize {
		t.Fatalf("oversized draft reached durability boundary: calls=%v", ops.calls)
	}
	if got := len(store.Records()); got != 1 {
		t.Fatalf("oversized draft advanced sequence: records=%d, want 1", got)
	}
}

func TestAppendCanonicalizesEquivalentNestedNumericSpellings(t *testing.T) {
	store, _, err := Open(t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	cleanupStore(t, store)
	record, err := store.Append(context.Background(), Draft{
		Type:    "credential.issued",
		Payload: json.RawMessage(`{"outer":{"integer":1.0,"negativeZero":-0.0},"items":[1e0,10e-1,0.0100]}`),
	})
	if err != nil {
		t.Fatalf("Append() error = %v", err)
	}
	want := `{"items":[1,1,0.01],"outer":{"integer":1,"negativeZero":0}}`
	if string(record.Payload) != want {
		t.Fatalf("canonical payload = %s\nwant %s", record.Payload, want)
	}
}

func TestStreamingJSONStringEscapingIsCanonicalAndCapped(t *testing.T) {
	output := newCappedJSONBuffer(maxPayloadBytes)
	if err := writeJSONString(&output, "<>&\u2028\u2029\x01\n\\"); err != nil {
		t.Fatalf("writeJSONString() error = %v", err)
	}
	want := `"\u003c\u003e\u0026\u2028\u2029\u0001\n\\"`
	if got := string(output.Bytes()); got != want {
		t.Fatalf("escaped string = %q, want %q", got, want)
	}
	if err := writeJSONString(&output, string([]byte{0xff})); err == nil {
		t.Fatal("writeJSONString() accepted invalid UTF-8")
	}

	for name, payload := range map[string]json.RawMessage{
		"value": json.RawMessage(`"` + strings.Repeat("<", 200_000) + `"`),
		"key":   json.RawMessage(`{"` + strings.Repeat("<", 200_000) + `":0}`),
	} {
		t.Run(name, func(t *testing.T) {
			if len(payload) >= maxPayloadBytes {
				t.Fatalf("raw payload = %d bytes, want below %d", len(payload), maxPayloadBytes)
			}
			store, _, err := Open(t.TempDir(), &recordingFileOps{})
			if err != nil {
				t.Fatal(err)
			}
			cleanupStore(t, store)
			if _, err := store.Append(context.Background(), Draft{Type: "credential.issued", Payload: payload}); !errors.Is(err, ErrInvalidDraft) {
				t.Fatalf("Append() error = %v, want ErrInvalidDraft", err)
			}
			if got := len(store.Records()); got != 0 {
				t.Fatalf("escaped expansion advanced records to %d", got)
			}
		})
	}
}

func TestAppendRejectsOversizedRecordMetadataBeforeFileOperation(t *testing.T) {
	ops := &recordingFileOps{}
	store, _, err := Open(t.TempDir(), ops)
	if err != nil {
		t.Fatal(err)
	}
	cleanupStore(t, store)
	if _, err := store.Append(context.Background(), Draft{Type: strings.Repeat("x", maxRecordMetadataBytes+1), Payload: json.RawMessage(`{}`)}); !errors.Is(err, ErrInvalidDraft) {
		t.Fatalf("Append() error = %v, want ErrInvalidDraft", err)
	}
	if len(ops.calls) != 0 || len(store.Records()) != 0 {
		t.Fatalf("oversized metadata reached durability boundary: calls=%v records=%v", ops.calls, store.Records())
	}
}

func TestOpenRejectsOversizedCommittedRecordWithBoundedRead(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "0000000000000001.json")
	if err := os.WriteFile(path, bytes.Repeat([]byte{'x'}, maxRecordBytes+1), 0o600); err != nil {
		t.Fatal(err)
	}
	data, err := readFileBounded(path, maxRecordBytes)
	if err == nil {
		t.Fatal("readFileBounded() error = nil, want oversize rejection")
	}
	if len(data) > maxRecordBytes+1 {
		t.Fatalf("bounded read retained %d bytes, want at most %d", len(data), maxRecordBytes+1)
	}
	if _, _, err := Open(root, nil); !errors.Is(err, ErrJournalCorrupt) {
		t.Fatalf("Open() error = %v, want ErrJournalCorrupt", err)
	}
}

func TestRoomCreatedDraftRequiresCanonicalCreatedAtBeforeNormalization(t *testing.T) {
	for name, payload := range map[string]json.RawMessage{
		"null":     json.RawMessage(`{"createdAt":null}`),
		"zero":     json.RawMessage(`{"createdAt":0}`),
		"negative": json.RawMessage(`{"createdAt":-1}`),
		"fraction": json.RawMessage(`{"createdAt":1.0}`),
		"exponent": json.RawMessage(`{"createdAt":1e0}`),
		"overflow": json.RawMessage(`{"createdAt":9223372036854775808}`),
		"missing":  json.RawMessage(`{}`),
	} {
		t.Run(name, func(t *testing.T) {
			ops := &recordingFileOps{}
			store, _, err := Open(t.TempDir(), ops)
			if err != nil {
				t.Fatal(err)
			}
			cleanupStore(t, store)
			if _, err := store.Append(context.Background(), Draft{Type: "room.created", Payload: payload}); !errors.Is(err, ErrInvalidDraft) {
				t.Fatalf("Append() error = %v, want ErrInvalidDraft", err)
			}
			if len(ops.calls) != 0 || len(store.Records()) != 0 {
				t.Fatalf("invalid createdAt reached durability boundary: calls=%v records=%v", ops.calls, store.Records())
			}
		})
	}

	store, _, err := Open(t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	cleanupStore(t, store)
	if _, err := store.Append(context.Background(), Draft{Type: "room.created", Payload: json.RawMessage(`{"createdAt":1724300000}`)}); err != nil {
		t.Fatalf("Append() valid room.created error = %v", err)
	}
	if err := store.WriteManifestProjection("room-1", "gomoku", "192.168.1.7:1", 1); err != nil {
		t.Fatalf("WriteManifestProjection() after valid append error = %v", err)
	}
}

func TestAppendRejectsCumulativeCanonicalExpansionBeforeFileOperation(t *testing.T) {
	raw := manySmallExponentArray(10_500)
	if len(raw) >= maxPayloadBytes {
		t.Fatalf("test payload raw bytes = %d, want below %d", len(raw), maxPayloadBytes)
	}
	root := t.TempDir()
	ops := &recordingFileOps{root: root}
	store, _, err := Open(root, ops)
	if err != nil {
		t.Fatal(err)
	}
	cleanupStore(t, store)
	if _, err := store.Append(context.Background(), Draft{Type: "credential.issued", Payload: raw}); !errors.Is(err, ErrInvalidDraft) {
		t.Fatalf("Append() error = %v, want ErrInvalidDraft", err)
	}
	if len(ops.calls) != 0 || len(store.Records()) != 0 {
		t.Fatalf("cumulative expansion reached durability boundary: calls=%v records=%v", ops.calls, store.Records())
	}

	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var value any
	if err := decoder.Decode(&value); err != nil {
		t.Fatal(err)
	}
	output := newCappedJSONBuffer(maxPayloadBytes)
	if err := writeCanonicalJSON(&output, value); err == nil {
		t.Fatal("writeCanonicalJSON() error = nil, want cumulative output limit")
	}
	if got := output.Len(); got > maxPayloadBytes {
		t.Fatalf("canonical emission retained %d bytes, want at most %d", got, maxPayloadBytes)
	}
}

func TestAppendRejectsWhitespaceExpandedRawPayloadBeforeDecoding(t *testing.T) {
	raw := append(json.RawMessage(strings.Repeat(" ", maxPayloadBytes)), '{', '}')
	root := t.TempDir()
	ops := &recordingFileOps{root: root}
	store, _, err := Open(root, ops)
	if err != nil {
		t.Fatal(err)
	}
	cleanupStore(t, store)
	if _, err := store.Append(context.Background(), Draft{Type: "room.created", Payload: raw}); !errors.Is(err, ErrInvalidDraft) {
		t.Fatalf("Append() error = %v, want ErrInvalidDraft", err)
	}
	if len(ops.calls) != 0 || len(store.Records()) != 0 {
		t.Fatalf("oversized raw payload reached durability boundary: calls=%v records=%v", ops.calls, store.Records())
	}
}

func TestReplayRejectsAlternateNestedNumericSpellingsBeforeHashVerification(t *testing.T) {
	root := t.TempDir()
	store, _, err := Open(root, nil)
	if err != nil {
		t.Fatal(err)
	}
	cleanupStore(t, store)
	if _, err := store.Append(context.Background(), Draft{Type: "credential.issued", Payload: json.RawMessage(`{"array":[1,1],"nested":{"count":1}}`)}); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "0000000000000001.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	altered := strings.Replace(string(data), `"payload":{"array":[1,1],"nested":{"count":1}}`, `"payload":{"array":[1.0,1e0],"nested":{"count":1.00}}`, 1)
	if altered == string(data) {
		t.Fatal("test fixture did not alter payload")
	}
	if err := os.WriteFile(path, []byte(altered), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	if _, _, err := Open(root, nil); !errors.Is(err, ErrJournalCorrupt) || !strings.Contains(err.Error(), "payload is not canonical") {
		t.Fatalf("Open() error = %v, want ErrJournalCorrupt for noncanonical numeric payload", err)
	}
}

func TestAppendRejectsNonUTF8CallerFieldsBeforeFileOperation(t *testing.T) {
	root := t.TempDir()
	ops := &recordingFileOps{root: root}
	store, _, err := Open(root, ops)
	if err != nil {
		t.Fatal(err)
	}
	cleanupStore(t, store)
	if _, err := store.Append(context.Background(), Draft{Type: string([]byte{0xff}), Payload: json.RawMessage(`{}`)}); !errors.Is(err, ErrInvalidDraft) {
		t.Fatalf("Append() error = %v, want ErrInvalidDraft", err)
	}
	if len(ops.calls) != 0 || len(store.Records()) != 0 {
		t.Fatalf("invalid UTF-8 draft reached durability boundary: calls=%v records=%v", ops.calls, store.Records())
	}
}

func TestManifestProjectionCanLagAuthoritativeJournal(t *testing.T) {
	root := t.TempDir()
	store, _, err := Open(root, nil)
	if err != nil {
		t.Fatal(err)
	}
	cleanupStore(t, store)
	if _, err := store.Append(context.Background(), Draft{Type: "room.created", Payload: json.RawMessage(`{"createdAt":1724300000}`)}); err != nil {
		t.Fatal(err)
	}
	if err := store.WriteManifestProjection("room-1", "gomoku", "192.168.1.7:49152", 1); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Append(context.Background(), Draft{Type: "credential.issued", Payload: json.RawMessage(`{}`)}); err != nil {
		t.Fatal(err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	store, records, err := Open(root, nil)
	if err != nil {
		t.Fatalf("Open() rejected valid journal behind manifest: %v", err)
	}
	defer store.Close()
	if len(records) != 2 {
		t.Fatalf("Open() records = %d, want 2", len(records))
	}
	manifest, err := os.ReadFile(filepath.Join(root, "manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	wantManifest := `{"schemaVersion":1,"roomId":"room-1","gameId":"gomoku","createdAt":1724300000,"endpoint":"192.168.1.7:49152","journalFormatVersion":1,"journalSequence":1}`
	if string(manifest) != wantManifest {
		t.Fatalf("manifest = %s\nwant %s", manifest, wantManifest)
	}
}

func TestManifestProjectionRequiresPositiveCanonicalIntegerCreatedAt(t *testing.T) {
	for name, payload := range map[string]json.RawMessage{
		"null":     json.RawMessage(`{"createdAt":null}`),
		"zero":     json.RawMessage(`{"createdAt":0}`),
		"negative": json.RawMessage(`{"createdAt":-1}`),
		"overflow": json.RawMessage(`{"createdAt":9223372036854775808}`),
	} {
		t.Run(name, func(t *testing.T) {
			store, _, err := Open(t.TempDir(), nil)
			if err != nil {
				t.Fatal(err)
			}
			cleanupStore(t, store)
			if _, err := store.Append(context.Background(), Draft{Type: "room.created", Payload: payload}); !errors.Is(err, ErrInvalidDraft) {
				t.Fatalf("Append() error = %v, want ErrInvalidDraft", err)
			}
		})
	}
	for _, payload := range []json.RawMessage{
		json.RawMessage(`{"createdAt":1.0}`),
		json.RawMessage(`{"createdAt":1e0}`),
	} {
		if _, err := createdAtFromRecords([]Record{{Type: "room.created", Payload: payload}}); err == nil {
			t.Fatalf("createdAtFromRecords(%s) error = nil, want noncanonical integer rejection", payload)
		}
	}
}

func TestAppendRejectsCanceledContextBeforeCommit(t *testing.T) {
	root := t.TempDir()
	store, _, err := Open(root, nil)
	if err != nil {
		t.Fatal(err)
	}
	cleanupStore(t, store)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := store.Append(ctx, Draft{Type: "room.created", Payload: json.RawMessage(`{}`)}); !errors.Is(err, context.Canceled) {
		t.Fatalf("Append() error = %v, want context.Canceled", err)
	}
	if len(store.Records()) != 0 {
		t.Fatalf("Records() advanced after canceled append: %#v", store.Records())
	}
	if _, err := os.Stat(filepath.Join(root, "0000000000000001.json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("committed file stat error = %v, want not exist", err)
	}
}

func stringPtr(value string) *string { return &value }

func cleanupStore(t *testing.T, store *Store) {
	t.Helper()
	t.Cleanup(func() {
		if err := store.Close(); err != nil {
			t.Errorf("Store.Close() error = %v", err)
		}
	})
}

func validJSONStringOfLength(length int) json.RawMessage {
	return append(append(json.RawMessage(`"`), bytes.Repeat([]byte{'a'}, length-2)...), '"')
}

func manySmallExponentArray(count int) json.RawMessage {
	var payload strings.Builder
	payload.Grow(count*6 + 2)
	payload.WriteByte('[')
	for index := 0; index < count; index++ {
		if index > 0 {
			payload.WriteByte(',')
		}
		payload.WriteString("1e100")
	}
	payload.WriteByte(']')
	return json.RawMessage(payload.String())
}

func isLowerSHA256(value string) bool {
	if len(value) != 64 {
		return false
	}
	for _, char := range value {
		if !((char >= '0' && char <= '9') || (char >= 'a' && char <= 'f')) {
			return false
		}
	}
	return true
}

func copyFixtureTree(t *testing.T, fixture, root string) {
	t.Helper()
	paths, err := filepath.Glob(filepath.Join("testdata", fixture, "*"))
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range paths {
		contents, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, filepath.Base(path)), contents, 0o600); err != nil {
			t.Fatal(err)
		}
	}
}

func journalWithTwoRecords(t *testing.T) (string, [][]byte) {
	t.Helper()
	root := t.TempDir()
	store, _, err := Open(root, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.Append(context.Background(), Draft{Type: "room.created", Payload: json.RawMessage(`{"createdAt":1724300000}`)}); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Append(context.Background(), Draft{Type: "credential.issued", Payload: json.RawMessage(`{}`)}); err != nil {
		t.Fatal(err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	contents := make([][]byte, 2)
	for index := range contents {
		contents[index], err = os.ReadFile(filepath.Join(root, "000000000000000"+string(rune('1'+index))+".json"))
		if err != nil {
			t.Fatal(err)
		}
	}
	return root, contents
}
