package journal

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestOpenRejectsSemanticallyInvalidRoomCreatedRecordsWithoutRepair(t *testing.T) {
	for name, payload := range map[string]json.RawMessage{
		"missing":    json.RawMessage(`{}`),
		"null":       json.RawMessage(`{"createdAt":null}`),
		"zero":       json.RawMessage(`{"createdAt":0}`),
		"negative":   json.RawMessage(`{"createdAt":-1}`),
		"fractional": json.RawMessage(`{"createdAt":1.0}`),
		"exponent":   json.RawMessage(`{"createdAt":1e0}`),
		"overflow":   json.RawMessage(`{"createdAt":9223372036854775808}`),
	} {
		t.Run(name, func(t *testing.T) {
			root := t.TempDir()
			path := filepath.Join(root, "0000000000000001.json")
			data := sealedRoomCreatedRecord(t, payload)
			if err := os.WriteFile(path, data, 0o600); err != nil {
				t.Fatal(err)
			}
			for attempt := 1; attempt <= 2; attempt++ {
				if store, _, err := Open(root, nil); store != nil || err == nil {
					t.Fatalf("Open() attempt %d = (%v, %v), want semantic replay rejection", attempt, store, err)
				}
			}
			if got, err := os.ReadFile(path); err != nil || !bytes.Equal(got, data) {
				t.Fatalf("Open() repaired record: got %q, err=%v", got, err)
			}
		})
	}
}

func TestOpenReplaysValidRoomCreatedAndWritesManifest(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "0000000000000001.json")
	if err := os.WriteFile(path, sealedRoomCreatedRecord(t, json.RawMessage(`{"createdAt":1724300000}`)), 0o600); err != nil {
		t.Fatal(err)
	}
	store, records, err := Open(root, nil)
	if err != nil {
		t.Fatalf("Open() valid room.created error = %v", err)
	}
	t.Cleanup(func() {
		if err := store.Close(); err != nil {
			t.Errorf("Close() error = %v", err)
		}
	})
	if len(records) != 1 || records[0].Type != "room.created" {
		t.Fatalf("Open() records = %#v, want valid room.created", records)
	}
	if err := store.WriteManifestProjection("room-1", "gomoku", "192.168.1.7:1", 1); err != nil {
		t.Fatalf("WriteManifestProjection() error = %v", err)
	}
}

func sealedRoomCreatedRecord(t *testing.T, payload json.RawMessage) []byte {
	t.Helper()
	record := Record{
		SchemaVersion:   schemaVersion,
		JournalSequence: 1,
		Type:            "room.created",
		Payload:         append(json.RawMessage(nil), payload...),
	}
	withoutHash, err := canonicalRecordWithoutHash(record)
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(withoutHash)
	record.Hash = hex.EncodeToString(digest[:])
	data, err := canonicalRecord(record)
	if err != nil {
		t.Fatal(err)
	}
	return data
}
