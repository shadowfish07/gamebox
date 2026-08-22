//go:build android || darwin || linux

package lanengine

import (
	"errors"
	"os"
	"syscall"

	"golang.org/x/sys/unix"
)

func removeActiveRoomTree(root string) error {
	rootDescriptor, err := unix.Open(root, unix.O_RDONLY|unix.O_CLOEXEC|unix.O_DIRECTORY|unix.O_NOFOLLOW, 0)
	if errors.Is(err, syscall.ENOENT) {
		return nil
	}
	if err != nil {
		return err
	}
	defer unix.Close(rootDescriptor)
	return removeEntryAt(rootDescriptor, "active_room", true)
}

func removeEntryAt(parentDescriptor int, name string, topLevel bool) error {
	if name == "" || name == "." || name == ".." {
		return errors.New("invalid room entry")
	}
	var initial unix.Stat_t
	if err := unix.Fstatat(parentDescriptor, name, &initial, unix.AT_SYMLINK_NOFOLLOW); err != nil {
		if topLevel && errors.Is(err, syscall.ENOENT) {
			return nil
		}
		return err
	}
	switch initial.Mode & unix.S_IFMT {
	case unix.S_IFREG:
		return removeUnchangedEntry(parentDescriptor, name, initial, 0)
	case unix.S_IFDIR:
		directoryDescriptor, err := unix.Openat(
			parentDescriptor,
			name,
			unix.O_RDONLY|unix.O_CLOEXEC|unix.O_DIRECTORY|unix.O_NOFOLLOW,
			0,
		)
		if err != nil {
			return err
		}
		var opened unix.Stat_t
		if err := unix.Fstat(directoryDescriptor, &opened); err != nil {
			_ = unix.Close(directoryDescriptor)
			return err
		}
		if err := requireSameDirectoryIdentity(initial, opened); err != nil {
			_ = unix.Close(directoryDescriptor)
			return err
		}
		directory := os.NewFile(uintptr(directoryDescriptor), "<lan-room-directory>")
		if directory == nil {
			_ = unix.Close(directoryDescriptor)
			return errors.New("invalid room directory")
		}
		names, readErr := directory.Readdirnames(-1)
		if readErr != nil {
			_ = directory.Close()
			return readErr
		}
		for _, child := range names {
			if err := removeEntryAt(directoryDescriptor, child, false); err != nil {
				_ = directory.Close()
				return err
			}
		}
		if err := directory.Close(); err != nil {
			return err
		}
		return removeUnchangedEntry(parentDescriptor, name, initial, unix.AT_REMOVEDIR)
	default:
		return errors.New("unsupported room entry")
	}
}

func requireSameDirectoryIdentity(initial unix.Stat_t, opened unix.Stat_t) error {
	if initial.Mode&unix.S_IFMT != unix.S_IFDIR ||
		opened.Mode&unix.S_IFMT != unix.S_IFDIR ||
		opened.Dev != initial.Dev ||
		opened.Ino != initial.Ino ||
		opened.Uid != initial.Uid {
		return errors.New("room directory changed during cleanup")
	}
	return nil
}

func removeUnchangedEntry(parentDescriptor int, name string, initial unix.Stat_t, flags int) error {
	var current unix.Stat_t
	if err := unix.Fstatat(parentDescriptor, name, &current, unix.AT_SYMLINK_NOFOLLOW); err != nil {
		return err
	}
	if current.Dev != initial.Dev || current.Ino != initial.Ino || current.Mode&unix.S_IFMT != initial.Mode&unix.S_IFMT {
		return errors.New("room entry changed during cleanup")
	}
	return unix.Unlinkat(parentDescriptor, name, flags)
}
