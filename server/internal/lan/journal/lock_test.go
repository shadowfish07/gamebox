package journal

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"golang.org/x/sys/unix"
)

func TestReleaseJournalRootLockUnlockFailureRetainsDescriptorForRetry(t *testing.T) {
	file, err := os.CreateTemp(t.TempDir(), "journal-lock")
	if err != nil {
		t.Fatal(err)
	}
	if err := unix.Flock(int(file.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		t.Fatal(err)
	}
	unlockFailure := errors.New("unlock failed")
	unlockCalls := 0
	closeCalls := 0
	ops := journalLockReleaseOps{
		unlock: func(int) error {
			unlockCalls++
			if unlockCalls == 1 {
				return unlockFailure
			}
			return unix.Flock(int(file.Fd()), unix.LOCK_UN)
		},
		close: func(file *os.File) error {
			closeCalls++
			return file.Close()
		},
	}

	first := releaseJournalRootLockWithOps(file, ops)
	if first.ownershipReleased || !errors.Is(first.err, unlockFailure) {
		t.Fatalf("first release = %#v, want retained unlock failure", first)
	}
	if closeCalls != 0 {
		t.Fatalf("close calls after unlock failure = %d, want 0", closeCalls)
	}
	if _, err := file.Stat(); err != nil {
		t.Fatalf("retained descriptor is not retryable: %v", err)
	}

	second := releaseJournalRootLockWithOps(file, ops)
	if !second.ownershipReleased || second.err != nil {
		t.Fatalf("second release = %#v, want released success", second)
	}
	if unlockCalls != 2 || closeCalls != 1 {
		t.Fatalf("release calls unlock=%d close=%d, want 2/1", unlockCalls, closeCalls)
	}
}

func TestReleaseJournalRootLockCloseErrorReportsReleasedAfterOneClose(t *testing.T) {
	file, err := os.CreateTemp(t.TempDir(), "journal-lock")
	if err != nil {
		t.Fatal(err)
	}
	if err := unix.Flock(int(file.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		t.Fatal(err)
	}
	closeFailure := errors.New("close failed after ownership release")
	closeCalls := 0
	outcome := releaseJournalRootLockWithOps(file, journalLockReleaseOps{
		unlock: func(descriptor int) error { return unix.Flock(descriptor, unix.LOCK_UN) },
		close: func(file *os.File) error {
			closeCalls++
			if err := file.Close(); err != nil {
				t.Fatal(err)
			}
			return closeFailure
		},
	})

	if !outcome.ownershipReleased || !errors.Is(outcome.err, closeFailure) {
		t.Fatalf("release = %#v, want released close failure", outcome)
	}
	if closeCalls != 1 {
		t.Fatalf("close calls = %d, want exactly 1", closeCalls)
	}
	if _, err := file.Stat(); err == nil {
		t.Fatal("close-error fixture did not actually close the descriptor")
	}
}

func TestOpenExclusivelyLocksRootUntilClose(t *testing.T) {
	root := t.TempDir()
	first, _, err := Open(root, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, journalLockFilename)); err != nil {
		t.Fatalf("persistent lock file stat error = %v", err)
	}
	firstRecord, err := first.Append(context.Background(), Draft{Type: "room.created", Payload: json.RawMessage(`{"createdAt":1}`)})
	if err != nil {
		t.Fatal(err)
	}
	if second, _, err := Open(root, nil); !errors.Is(err, ErrJournalLocked) || second != nil {
		t.Fatalf("second Open() = (%v, %v), want ErrJournalLocked", second, err)
	}
	if err := first.Close(); err != nil {
		t.Fatalf("first Close() error = %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, journalLockFilename)); err != nil {
		t.Fatalf("Close() removed non-authoritative lock file: %v", err)
	}

	reopened, records, err := Open(root, nil)
	if err != nil {
		t.Fatalf("Open() after Close error = %v", err)
	}
	defer reopened.Close()
	if len(records) != 1 || records[0].JournalSequence != 1 || records[0].Hash != firstRecord.Hash {
		t.Fatalf("replayed records = %#v, want acknowledged first record", records)
	}
}

func TestProcessExitReleasesJournalLock(t *testing.T) {
	const childFlag = "GAMEBOX_JOURNAL_LOCK_CHILD"
	const rootFlag = "GAMEBOX_JOURNAL_LOCK_ROOT"
	if os.Getenv(childFlag) == "1" {
		store, _, err := Open(os.Getenv(rootFlag), nil)
		if err != nil {
			t.Fatalf("child Open() error = %v", err)
		}
		if _, err := store.Append(context.Background(), Draft{Type: "room.created", Payload: json.RawMessage(`{"createdAt":1}`)}); err != nil {
			t.Fatalf("child Append() error = %v", err)
		}
		return // Deliberately do not Close: process exit must release the advisory lock.
	}

	root := t.TempDir()
	command := exec.Command(os.Args[0], "-test.run=^TestProcessExitReleasesJournalLock$")
	command.Env = append(os.Environ(), childFlag+"=1", rootFlag+"="+root)
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("lock helper exited with %v: %s", err, output)
	}

	store, records, err := Open(root, nil)
	if err != nil {
		t.Fatalf("parent Open() after helper exit error = %v", err)
	}
	defer store.Close()
	if len(records) != 1 || records[0].JournalSequence != 1 {
		t.Fatalf("parent replay = %#v, want helper's acknowledged record", records)
	}
}

func TestCloseSerializesWithMutationsAndClosesStore(t *testing.T) {
	for name, operation := range map[string]func(*Store) error{
		"append": func(store *Store) error {
			_, err := store.Append(context.Background(), Draft{Type: "credential.issued", Payload: json.RawMessage(`{}`)})
			return err
		},
		"manifest": func(store *Store) error {
			return store.WriteManifestProjection("room-1", "gomoku", "192.168.1.7:1", 1)
		},
	} {
		t.Run(name, func(t *testing.T) {
			root := t.TempDir()
			ops := newBlockingFileOps()
			store, _, err := Open(root, ops)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := store.Append(context.Background(), Draft{Type: "room.created", Payload: json.RawMessage(`{"createdAt":1}`)}); err != nil {
				t.Fatal(err)
			}
			ops.blockNextWrite()
			mutationDone := make(chan error, 1)
			go func() { mutationDone <- operation(store) }()
			<-ops.started
			closeDone := make(chan error, 1)
			go func() { closeDone <- store.Close() }()
			select {
			case err := <-closeDone:
				t.Fatalf("Close() completed during in-flight mutation: %v", err)
			default:
			}
			close(ops.release)
			if err := <-mutationDone; err != nil {
				t.Fatalf("in-flight %s error = %v", name, err)
			}
			if err := <-closeDone; err != nil {
				t.Fatalf("Close() error = %v", err)
			}
			if _, err := store.Append(context.Background(), Draft{Type: "credential.issued", Payload: json.RawMessage(`{}`)}); !errors.Is(err, ErrJournalClosed) {
				t.Fatalf("Append() after Close error = %v, want ErrJournalClosed", err)
			}
			if err := store.WriteManifestProjection("room-1", "gomoku", "192.168.1.7:1", 1); !errors.Is(err, ErrJournalClosed) {
				t.Fatalf("WriteManifestProjection() after Close error = %v, want ErrJournalClosed", err)
			}
			if err := store.Close(); err != nil {
				t.Fatalf("second Close() error = %v, want idempotent success", err)
			}
			wantRecords := 1
			if name == "append" {
				wantRecords = 2
			}
			if records := store.Records(); len(records) != wantRecords {
				t.Fatalf("Records() after Close = %#v, want %d immutable readable records", records, wantRecords)
			}
		})
	}
}

func TestOpenRejectsInvalidCommittedOuterRecordsWithoutRepair(t *testing.T) {
	for name, mutate := range map[string]func(t *testing.T, first, second []byte) []byte{
		"duplicate outer key": func(t *testing.T, first, _ []byte) []byte {
			t.Helper()
			return replaceRecordBytes(t, first, `"type":"room.created"`, `"type":"room.created","type":"room.created"`)
		},
		"missing outer key": func(t *testing.T, first, _ []byte) []byte {
			t.Helper()
			return replaceRecordBytes(t, first, `,"actionId":null`, "")
		},
		"invalid UTF-8": func(_ *testing.T, first, _ []byte) []byte {
			corrupt := append([]byte(nil), first...)
			corrupt[0] = 0xff
			return corrupt
		},
		"trailing JSON": func(_ *testing.T, first, _ []byte) []byte {
			return append(append([]byte(nil), first...), []byte(`{}`)...)
		},
		"noncanonical outer bytes": func(_ *testing.T, first, _ []byte) []byte {
			return append([]byte(" \n"), first...)
		},
		"upper-case hash": func(t *testing.T, first, _ []byte) []byte {
			t.Helper()
			corrupt := append([]byte(nil), first...)
			start := bytes.Index(corrupt, []byte(`"hash":"`)) + len(`"hash":"`)
			if start < len(`"hash":"`) {
				t.Fatal("record did not contain a hash field")
			}
			for index := start; index < len(corrupt); index++ {
				value := corrupt[index]
				if value >= 'a' && value <= 'f' {
					corrupt[index] = value - ('a' - 'A')
					return corrupt
				}
			}
			t.Fatal("record hash did not contain a lower-case hexadecimal letter")
			return nil
		},
		"invalid schema": func(t *testing.T, first, _ []byte) []byte {
			t.Helper()
			return replaceRecordBytes(t, first, `"schemaVersion":1`, `"schemaVersion":2`)
		},
		"invalid sequence": func(t *testing.T, first, _ []byte) []byte {
			t.Helper()
			return replaceRecordBytes(t, first, `"journalSequence":1`, `"journalSequence":0`)
		},
		"filename mismatched sequence": func(_ *testing.T, _, second []byte) []byte {
			return append([]byte(nil), second...)
		},
	} {
		t.Run(name, func(t *testing.T) {
			root, records := journalWithTwoRecords(t)
			path := filepath.Join(root, "0000000000000001.json")
			corrupt := mutate(t, records[0], records[1])
			if err := os.WriteFile(path, corrupt, 0o600); err != nil {
				t.Fatal(err)
			}
			if _, _, err := Open(root, nil); err == nil {
				t.Fatal("Open() error = nil, want committed-record rejection")
			}
			got, err := os.ReadFile(path)
			if err != nil || !bytes.Equal(got, corrupt) {
				t.Fatalf("Open() repaired corrupt record: got %q, err=%v", got, err)
			}
			if _, _, err := Open(root, nil); err == nil || errors.Is(err, ErrJournalLocked) {
				t.Fatalf("second Open() after replay error = %v, want corruption rejection after lock release", err)
			}
		})
	}
}

func replaceRecordBytes(t *testing.T, data []byte, old, replacement string) []byte {
	t.Helper()
	updated := strings.Replace(string(data), old, replacement, 1)
	if updated == string(data) {
		t.Fatalf("test fixture did not contain %q", old)
	}
	return []byte(updated)
}

type blockingFileOps struct {
	started chan struct{}
	release chan struct{}
	mu      sync.Mutex
	block   bool
}

func newBlockingFileOps() *blockingFileOps {
	return &blockingFileOps{started: make(chan struct{}), release: make(chan struct{})}
}

func (ops *blockingFileOps) blockNextWrite() {
	ops.mu.Lock()
	defer ops.mu.Unlock()
	ops.block = true
}

func (ops *blockingFileOps) WriteFileSync(path string, data []byte, mode os.FileMode) error {
	if err := (osFileOps{}).WriteFileSync(path, data, mode); err != nil {
		return err
	}
	ops.mu.Lock()
	block := ops.block
	if block {
		ops.block = false
	}
	ops.mu.Unlock()
	if block {
		close(ops.started)
		<-ops.release
	}
	return nil
}

func (ops *blockingFileOps) Rename(oldPath, newPath string) error { return os.Rename(oldPath, newPath) }

func (ops *blockingFileOps) SyncDir(path string) error {
	directory, err := os.Open(path)
	if err != nil {
		return err
	}
	defer directory.Close()
	return directory.Sync()
}
