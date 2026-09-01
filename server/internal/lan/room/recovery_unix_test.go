//go:build android || darwin || linux

package room

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"golang.org/x/sys/unix"

	"me.zqydev/gamebox/server/internal/lan/journal"
)

func TestRecoveryMapsCommittedFIFOWithoutBlockingOrLockLeak(t *testing.T) {
	root := t.TempDir()
	store, _, err := journal.Open(root, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "0000000000000001.json")
	if err := unix.Mkfifo(path, 0o600); err != nil {
		t.Fatal(err)
	}
	type result struct {
		service *Service
		err     error
	}
	completed := make(chan result, 1)
	go func() {
		service, err := Open(Config{Root: root, TokenPepper: testPepper})
		completed <- result{service: service, err: err}
	}()
	select {
	case got := <-completed:
		if got.service != nil {
			_ = got.service.Close()
		}
		if got.service != nil || !errors.Is(got.err, ErrRecoveryCorrupt) {
			t.Fatalf("room.Open FIFO = (%v, %v), want ErrRecoveryCorrupt", got.service, got.err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("room.Open blocked on committed FIFO candidate")
	}
	if info, err := os.Lstat(path); err != nil || info.Mode()&os.ModeNamedPipe == 0 {
		t.Fatalf("FIFO source = (%v, %v), want unchanged FIFO", info, err)
	}
	if service, err := Open(Config{Root: root, TokenPepper: testPepper}); service != nil || !errors.Is(err, ErrRecoveryCorrupt) || errors.Is(err, journal.ErrJournalLocked) {
		if service != nil {
			_ = service.Close()
		}
		t.Fatalf("second room.Open = (%v, %v), want corruption after released lock", service, err)
	}
}
