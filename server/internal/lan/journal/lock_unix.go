//go:build android || darwin || linux

package journal

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"golang.org/x/sys/unix"
)

const journalLockFilename = ".journal.lock"

// acquireJournalRootLock uses a non-blocking advisory file lock so the kernel
// releases it if the hosting process crashes or is force-stopped.
func acquireJournalRootLock(root string) (*os.File, error) {
	file, err := os.OpenFile(filepath.Join(root, journalLockFilename), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, fmt.Errorf("open journal lock: %w", err)
	}
	if err := unix.Flock(int(file.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		_ = file.Close()
		if errors.Is(err, unix.EAGAIN) || errors.Is(err, unix.EWOULDBLOCK) {
			return nil, ErrJournalLocked
		}
		return nil, fmt.Errorf("lock journal root: %w", err)
	}
	return file, nil
}

type journalLockReleaseOps struct {
	unlock func(int) error
	close  func(*os.File) error
}

func releaseJournalRootLock(file *os.File) lockReleaseOutcome {
	return releaseJournalRootLockWithOps(file, journalLockReleaseOps{
		unlock: func(descriptor int) error { return unix.Flock(descriptor, unix.LOCK_UN) },
		close:  func(file *os.File) error { return file.Close() },
	})
}

func releaseJournalRootLockWithOps(file *os.File, ops journalLockReleaseOps) lockReleaseOutcome {
	if file == nil || ops.unlock == nil || ops.close == nil {
		return lockReleaseOutcome{err: errors.New("invalid journal lock release")}
	}
	if err := ops.unlock(int(file.Fd())); err != nil {
		return lockReleaseOutcome{err: fmt.Errorf("unlock journal root: %w", err)}
	}
	if err := ops.close(file); err != nil {
		return lockReleaseOutcome{ownershipReleased: true, err: fmt.Errorf("close journal lock: %w", err)}
	}
	return lockReleaseOutcome{ownershipReleased: true}
}
