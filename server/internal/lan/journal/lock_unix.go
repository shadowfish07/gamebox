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

func releaseJournalRootLock(file *os.File) error {
	unlockErr := unix.Flock(int(file.Fd()), unix.LOCK_UN)
	closeErr := file.Close()
	if unlockErr != nil {
		return fmt.Errorf("unlock journal root: %w", unlockErr)
	}
	if closeErr != nil {
		return fmt.Errorf("close journal lock: %w", closeErr)
	}
	return nil
}
