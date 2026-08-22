//go:build darwin || linux || android

package lanengine

import (
	"io"
	"os"

	"golang.org/x/sys/unix"
)

// readManifestFile treats the manifest as an untrusted, non-authoritative port
// hint. Opening once with O_NOFOLLOW and validating that same descriptor avoids
// symlink and file-type races; O_NONBLOCK prevents a FIFO from stalling Start.
func readManifestFile(path string) ([]byte, error) {
	descriptor, err := unix.Open(path, unix.O_RDONLY|unix.O_CLOEXEC|unix.O_NOFOLLOW|unix.O_NONBLOCK, 0)
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(descriptor), path)
	if file == nil {
		_ = unix.Close(descriptor)
		return nil, ErrInvalidConfiguration
	}
	defer file.Close()

	var status unix.Stat_t
	if err := unix.Fstat(descriptor, &status); err != nil || status.Mode&unix.S_IFMT != unix.S_IFREG {
		return nil, ErrInvalidConfiguration
	}
	data, err := io.ReadAll(io.LimitReader(file, maximumJSONBytes+1))
	if err != nil || len(data) > maximumJSONBytes {
		return nil, ErrInvalidConfiguration
	}
	return data, nil
}
