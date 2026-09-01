//go:build android || darwin || linux

package journal

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

func TestAtomicCommittedReaderRejectsCheckedFileSwappedToSymlink(t *testing.T) {
	root, sourcePath, sourceContents := oneRecordJournal(t)
	externalPath := filepath.Join(t.TempDir(), "external-record.json")
	if err := os.WriteFile(externalPath, sourceContents, 0o600); err != nil {
		t.Fatal(err)
	}
	swapped := false
	reader := func(root, name string, limit int) ([]byte, error) {
		if !swapped {
			swapped = true
			if err := os.Remove(sourcePath); err != nil {
				return nil, err
			}
			if err := os.Symlink(externalPath, sourcePath); err != nil {
				return nil, err
			}
		}
		return readCommittedRecord(root, name, limit)
	}

	if store, _, err := openWithCommittedRecordReader(root, nil, reader); store != nil || !errors.Is(err, ErrJournalCorrupt) {
		if store != nil {
			_ = store.Close()
		}
		t.Fatalf("Open after swap = (%v, %v), want ErrJournalCorrupt", store, err)
	}
	if target, err := os.Readlink(sourcePath); err != nil || target != externalPath {
		t.Fatalf("source symlink = (%q, %v), want unchanged target %q", target, err, externalPath)
	}
	if got, err := os.ReadFile(externalPath); err != nil || !bytes.Equal(got, sourceContents) {
		t.Fatalf("external target changed, read error = %v", err)
	}
	if store, _, err := Open(root, nil); store != nil || !errors.Is(err, ErrJournalCorrupt) || errors.Is(err, ErrJournalLocked) {
		if store != nil {
			_ = store.Close()
		}
		t.Fatalf("second Open = (%v, %v), want corruption after released lock", store, err)
	}
}

func TestAtomicCommittedReaderRejectsCheckedFileSwappedToFIFOWithoutBlocking(t *testing.T) {
	root, sourcePath, _ := oneRecordJournal(t)
	reader := func(root, name string, limit int) ([]byte, error) {
		if err := os.Remove(sourcePath); err != nil {
			return nil, err
		}
		if err := unix.Mkfifo(sourcePath, 0o600); err != nil {
			return nil, err
		}
		return readCommittedRecord(root, name, limit)
	}
	type result struct {
		store *Store
		err   error
	}
	completed := make(chan result, 1)
	go func() {
		store, _, err := openWithCommittedRecordReader(root, nil, reader)
		completed <- result{store: store, err: err}
	}()
	select {
	case got := <-completed:
		if got.store != nil {
			_ = got.store.Close()
		}
		if got.store != nil || !errors.Is(got.err, ErrJournalCorrupt) {
			t.Fatalf("Open after FIFO swap = (%v, %v), want ErrJournalCorrupt", got.store, got.err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Open blocked on committed FIFO candidate")
	}
	if info, err := os.Lstat(sourcePath); err != nil || info.Mode()&os.ModeNamedPipe == 0 {
		t.Fatalf("FIFO source = (%v, %v), want unchanged FIFO", info, err)
	}
	if store, _, err := Open(root, nil); store != nil || !errors.Is(err, ErrJournalCorrupt) || errors.Is(err, ErrJournalLocked) {
		if store != nil {
			_ = store.Close()
		}
		t.Fatalf("second Open = (%v, %v), want corruption after released lock", store, err)
	}
}

func TestAtomicCommittedReaderClassifiesMissingAfterEnumeration(t *testing.T) {
	root, sourcePath, _ := oneRecordJournal(t)
	reader := func(root, name string, limit int) ([]byte, error) {
		if err := os.Remove(sourcePath); err != nil {
			return nil, err
		}
		return readCommittedRecord(root, name, limit)
	}
	if store, _, err := openWithCommittedRecordReader(root, nil, reader); store != nil || !errors.Is(err, ErrJournalCorrupt) {
		if store != nil {
			_ = store.Close()
		}
		t.Fatalf("Open after removal = (%v, %v), want ErrJournalCorrupt", store, err)
	}
	store, records, err := Open(root, nil)
	if err != nil || store == nil || len(records) != 0 {
		t.Fatalf("Open after removal/released lock = (%v, %d records, %v)", store, len(records), err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
}

func oneRecordJournal(t *testing.T) (string, string, []byte) {
	t.Helper()
	root := t.TempDir()
	store, _, err := Open(root, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.Append(t.Context(), Draft{Type: "room.created", Payload: json.RawMessage(`{"createdAt":1}`)}); err != nil {
		t.Fatal(err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "0000000000000001.json")
	contents, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return root, path, contents
}
