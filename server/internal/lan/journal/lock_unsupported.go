//go:build !android && !darwin && !linux

package journal

import (
	"errors"
	"os"
)

const journalLockFilename = ".journal.lock"

func acquireJournalRootLock(string) (*os.File, error) {
	return nil, errors.New("journal root locking is unsupported on this platform")
}

func releaseJournalRootLock(*os.File) error { return nil }
