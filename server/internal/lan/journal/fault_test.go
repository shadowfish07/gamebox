package journal

import (
	"context"
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"sync"
	"testing"
)

var errInjected = errors.New("injected failure")

func TestFaultAppendWritesSyncBeforeRenameAndDirectorySyncAfterRename(t *testing.T) {
	root := t.TempDir()
	ops := &recordingFileOps{root: root}
	store, _, err := Open(root, ops)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.Append(context.Background(), Draft{Type: "room.created", Payload: json.RawMessage(`{"createdAt":1}`)}); err != nil {
		t.Fatal(err)
	}
	if got, want := ops.calls, []string{"write", "rename", "syncdir"}; !equalStrings(got, want) {
		t.Fatalf("durability calls = %v, want %v", got, want)
	}
}

func TestFaultAppendFailureDoesNotAdvanceInMemorySequenceBeforeReplayableRecord(t *testing.T) {
	for _, boundary := range []string{"write", "rename"} {
		t.Run(boundary, func(t *testing.T) {
			root := t.TempDir()
			ops := &recordingFileOps{root: root, fail: boundary}
			store, _, err := Open(root, ops)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := store.Append(context.Background(), Draft{Type: "room.created", Payload: json.RawMessage(`{"createdAt":1}`)}); !errors.Is(err, errInjected) {
				t.Fatalf("Append() error = %v, want injected failure", err)
			}
			if len(store.Records()) != 0 {
				t.Fatalf("Records() advanced before commit: %#v", store.Records())
			}
			if _, err := os.Stat(filepath.Join(root, "0000000000000001.json")); !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("committed record stat = %v, want not exist", err)
			}
		})
	}
}

func TestFaultDirectorySyncPoisonsStoreBecauseRenameMayBeDurable(t *testing.T) {
	root := t.TempDir()
	ops := &recordingFileOps{root: root, fail: "syncdir"}
	store, _, err := Open(root, ops)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.Append(context.Background(), Draft{Type: "room.created", Payload: json.RawMessage(`{"createdAt":1}`)}); !errors.Is(err, errInjected) {
		t.Fatalf("Append() error = %v, want injected failure", err)
	}
	if len(store.Records()) != 0 {
		t.Fatalf("Records() advanced after unacknowledged directory sync: %#v", store.Records())
	}
	if _, err := os.Stat(filepath.Join(root, "0000000000000001.json")); err != nil {
		t.Fatalf("renamed record missing: %v", err)
	}
	if _, err := store.Append(context.Background(), Draft{Type: "credential.issued", Payload: json.RawMessage(`{}`)}); !errors.Is(err, ErrReopenRequired) {
		t.Fatalf("Append() after directory sync failure = %v, want ErrReopenRequired", err)
	}
	if _, records, err := Open(root, nil); err != nil || len(records) != 1 {
		t.Fatalf("reopen = (%d records, %v), want one replayable record", len(records), err)
	}
}

func TestFaultManifestDirectorySyncAlsoRequiresReopen(t *testing.T) {
	root := t.TempDir()
	ops := &recordingFileOps{root: root}
	store, _, err := Open(root, ops)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.Append(context.Background(), Draft{Type: "room.created", Payload: json.RawMessage(`{"createdAt":1}`)}); err != nil {
		t.Fatal(err)
	}
	ops.fail = "syncdir"
	if err := store.WriteManifestProjection("room-1", "gomoku", "192.168.1.7:1", 1); !errors.Is(err, errInjected) {
		t.Fatalf("WriteManifestProjection() error = %v, want injected failure", err)
	}
	if _, err := store.Append(context.Background(), Draft{Type: "credential.issued", Payload: json.RawMessage(`{}`)}); !errors.Is(err, ErrReopenRequired) {
		t.Fatalf("Append() after ambiguous manifest write = %v, want ErrReopenRequired", err)
	}
}

func TestFaultContextCanceledAfterTempSyncDoesNotRenameOrAdvance(t *testing.T) {
	root := t.TempDir()
	ctx, cancel := context.WithCancel(context.Background())
	ops := &cancelAfterWriteFileOps{recordingFileOps: recordingFileOps{root: root}, cancel: cancel}
	store, _, err := Open(root, ops)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.Append(ctx, Draft{Type: "room.created", Payload: json.RawMessage(`{"createdAt":1}`)}); !errors.Is(err, context.Canceled) {
		t.Fatalf("Append() error = %v, want context.Canceled", err)
	}
	if got := len(store.Records()); got != 0 {
		t.Fatalf("Records() = %d, want no uncommitted record", got)
	}
	if got := ops.calls; !equalStrings(got, []string{"write"}) {
		t.Fatalf("durability calls = %v, want only temp write", got)
	}
}

func TestAppendIsSafeForConcurrentCallers(t *testing.T) {
	store, _, err := Open(t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	const writers = 12
	var group sync.WaitGroup
	errs := make(chan error, writers)
	for index := 0; index < writers; index++ {
		group.Add(1)
		go func() {
			defer group.Done()
			_, err := store.Append(context.Background(), Draft{Type: "room.created", Payload: json.RawMessage(`{"createdAt":1}`)})
			errs <- err
		}()
	}
	group.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatalf("concurrent Append() error = %v", err)
		}
	}
	if got := len(store.Records()); got != writers {
		t.Fatalf("Records() = %d, want %d", got, writers)
	}
}

type recordingFileOps struct {
	root  string
	fail  string
	calls []string
}

type cancelAfterWriteFileOps struct {
	recordingFileOps
	cancel context.CancelFunc
}

func (ops *cancelAfterWriteFileOps) WriteFileSync(path string, data []byte, mode fs.FileMode) error {
	err := ops.recordingFileOps.WriteFileSync(path, data, mode)
	if err == nil {
		ops.cancel()
	}
	return err
}

func (ops *recordingFileOps) WriteFileSync(path string, data []byte, mode fs.FileMode) error {
	ops.calls = append(ops.calls, "write")
	if ops.fail == "write" {
		return errInjected
	}
	return osFileOps{}.WriteFileSync(path, data, mode)
}

func (ops *recordingFileOps) Rename(oldPath, newPath string) error {
	ops.calls = append(ops.calls, "rename")
	if ops.fail == "rename" {
		return errInjected
	}
	return os.Rename(oldPath, newPath)
}

func (ops *recordingFileOps) SyncDir(path string) error {
	ops.calls = append(ops.calls, "syncdir")
	if ops.fail == "syncdir" {
		return errInjected
	}
	directory, err := os.Open(path)
	if err != nil {
		return err
	}
	defer directory.Close()
	return directory.Sync()
}

func equalStrings(got, want []string) bool {
	if len(got) != len(want) {
		return false
	}
	for index := range got {
		if got[index] != want[index] {
			return false
		}
	}
	return true
}
