//go:build android || darwin || linux

package journal

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"golang.org/x/sys/unix"
)

// readCommittedRecord atomically opens a committed candidate without following
// its final path component, makes FIFO/device opens nonblocking, verifies the
// opened descriptor is regular, and reads from that same descriptor.
func readCommittedRecord(root, name string, limit int) (data []byte, returnErr error) {
	path := filepath.Join(root, name)
	fd, err := unix.Open(path, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
	if err != nil {
		if errors.Is(err, unix.ENOENT) || errors.Is(err, unix.ELOOP) {
			return nil, fmt.Errorf("%w: committed journal candidate %q changed before open: %v", ErrJournalCorrupt, name, err)
		}
		return nil, err
	}
	file := os.NewFile(uintptr(fd), path)
	if file == nil {
		_ = unix.Close(fd)
		return nil, errors.New("wrap committed journal descriptor")
	}
	defer func() {
		if closeErr := file.Close(); closeErr != nil {
			wrapped := fmt.Errorf("close committed journal candidate %q: %w", name, closeErr)
			if returnErr == nil {
				returnErr = wrapped
			} else {
				returnErr = errors.Join(returnErr, wrapped)
			}
		}
	}()
	info, err := file.Stat()
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() {
		return nil, fmt.Errorf("%w: opened journal candidate %q is not a regular file", ErrJournalCorrupt, name)
	}
	return readOpenedFileBounded(file, limit)
}
