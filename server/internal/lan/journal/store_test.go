package journal

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
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
	if len(records) != 0 {
		t.Fatalf("Open() records = %d, want 0", len(records))
	}

	record, err := store.Append(context.Background(), Draft{
		Type:     "room.created",
		ActionID: stringPtr("create-1"),
		Payload:  json.RawMessage(`{"roomId":"room-1","players":[]}`),
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
	want := `{"schemaVersion":1,"journalSequence":1,"gameRevision":null,"type":"room.created","actionId":"create-1","payload":{"players":[],"roomId":"room-1"},"previousHash":"","hash":"` + record.Hash + `"}`
	if string(contents) != want {
		t.Fatalf("canonical record = %s\nwant %s", contents, want)
	}
}

func TestAppendChainsConsecutiveRecords(t *testing.T) {
	store, _, err := Open(t.TempDir(), nil)
	if err != nil {
		t.Fatalf("Open() error = %v", err)
	}
	first, err := store.Append(context.Background(), Draft{Type: "room.created", Payload: json.RawMessage(`{}`)})
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
	if _, _, err := Open(root, nil); err != nil {
		t.Fatalf("Open() error = %v", err)
	}
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
	for _, fixture := range []string{"corrupt_hash", "sequence_gap"} {
		t.Run(fixture, func(t *testing.T) {
			root := t.TempDir()
			copyFixtureTree(t, fixture, root)
			if _, _, err := Open(root, nil); err == nil {
				t.Fatal("Open() error = nil, want corruption rejection")
			}
		})
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
		if _, _, err := Open(root, nil); err == nil {
			t.Fatal("Open() error = nil, want reordered chain rejection")
		}
	})
	t.Run("duplicate sequence filename", func(t *testing.T) {
		root, records := journalWithTwoRecords(t)
		if err := os.WriteFile(filepath.Join(root, "00000000000000001.json"), records[0], 0o600); err != nil {
			t.Fatal(err)
		}
		if _, _, err := Open(root, nil); err == nil {
			t.Fatal("Open() error = nil, want duplicate sequence filename rejection")
		}
	})
	t.Run("wrong previous hash", func(t *testing.T) {
		rootA, _ := journalWithTwoRecords(t)
		rootB := t.TempDir()
		storeB, _, err := Open(rootB, nil)
		if err != nil {
			t.Fatal(err)
		}
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
		if _, _, err := Open(rootA, nil); err == nil {
			t.Fatal("Open() error = nil, want valid-but-wrong previous hash rejection")
		}
	})
	for name, mutate := range map[string]func([]byte) []byte{
		"invalid JSON": func([]byte) []byte { return []byte(`{`) },
		"unknown field": func([]byte) []byte {
			return []byte(`{"schemaVersion":1,"journalSequence":1,"gameRevision":null,"type":"room.created","actionId":null,"payload":{},"previousHash":"","hash":"0000000000000000000000000000000000000000000000000000000000000000","extra":true}`)
		},
		"wrong current hash": func(data []byte) []byte {
			value := string(data)
			return []byte(value[:len(value)-2] + `0"}`)
		},
	} {
		t.Run(name, func(t *testing.T) {
			root, records := journalWithTwoRecords(t)
			if err := os.WriteFile(filepath.Join(root, "0000000000000001.json"), mutate(records[0]), 0o600); err != nil {
				t.Fatal(err)
			}
			if _, _, err := Open(root, nil); err == nil {
				t.Fatal("Open() error = nil, want rejection")
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
	payload := append(json.RawMessage(`"`), make([]byte, 1<<20)...)
	payload = append(payload, '"')
	if _, err := store.Append(context.Background(), Draft{Type: "room.created", Payload: payload}); !errors.Is(err, ErrInvalidDraft) {
		t.Fatalf("Append() error = %v, want ErrInvalidDraft", err)
	}
	if len(ops.calls) != 0 || len(store.Records()) != 0 {
		t.Fatalf("oversized draft reached durability boundary: calls=%v records=%v", ops.calls, store.Records())
	}
}

func TestAppendRejectsNonUTF8CallerFieldsBeforeFileOperation(t *testing.T) {
	root := t.TempDir()
	ops := &recordingFileOps{root: root}
	store, _, err := Open(root, ops)
	if err != nil {
		t.Fatal(err)
	}
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
	if _, err := store.Append(context.Background(), Draft{Type: "room.created", Payload: json.RawMessage(`{"createdAt":1724300000}`)}); err != nil {
		t.Fatal(err)
	}
	if err := store.WriteManifestProjection("room-1", "gomoku", "192.168.1.7:49152", 1); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Append(context.Background(), Draft{Type: "credential.issued", Payload: json.RawMessage(`{}`)}); err != nil {
		t.Fatal(err)
	}
	_, records, err := Open(root, nil)
	if err != nil {
		t.Fatalf("Open() rejected valid journal behind manifest: %v", err)
	}
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

func TestAppendRejectsCanceledContextBeforeCommit(t *testing.T) {
	root := t.TempDir()
	store, _, err := Open(root, nil)
	if err != nil {
		t.Fatal(err)
	}
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
	contents := make([][]byte, 2)
	for index := range contents {
		contents[index], err = os.ReadFile(filepath.Join(root, "000000000000000"+string(rune('1'+index))+".json"))
		if err != nil {
			t.Fatal(err)
		}
	}
	return root, contents
}
