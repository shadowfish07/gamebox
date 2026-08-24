//go:build android || darwin || linux

package lanengine

import (
	"errors"
	"os"
	"strings"
	"syscall"

	"golang.org/x/sys/unix"
)

type cleanupEntry struct {
	name      string
	identity  unix.Stat_t
	directory *os.File
	children  []*cleanupEntry
}

func removeActiveRoomTree(root string) error {
	expectedUID := uint32(os.Geteuid())
	rootDescriptor, err := unix.Open(root, unix.O_RDONLY|unix.O_CLOEXEC|unix.O_DIRECTORY|unix.O_NOFOLLOW, 0)
	if errors.Is(err, syscall.ENOENT) {
		return nil
	}
	if err != nil {
		return err
	}
	defer unix.Close(rootDescriptor)

	var rootIdentity unix.Stat_t
	if err := unix.Fstat(rootDescriptor, &rootIdentity); err != nil {
		return err
	}
	if err := requireSameDirectoryIdentity(rootIdentity, rootIdentity, expectedUID); err != nil {
		return err
	}

	entry, err := preflightEntryAt(rootDescriptor, "active_room", true, expectedUID)
	if err != nil || entry == nil {
		return err
	}
	defer closeCleanupEntry(entry)
	return deletePreflightedEntry(rootDescriptor, entry, expectedUID)
}

func preflightEntryAt(parentDescriptor int, name string, topLevel bool, expectedUID uint32) (*cleanupEntry, error) {
	if !validCleanupEntryName(name) {
		return nil, errors.New("invalid room entry")
	}
	var initial unix.Stat_t
	if err := unix.Fstatat(parentDescriptor, name, &initial, unix.AT_SYMLINK_NOFOLLOW); err != nil {
		if topLevel && errors.Is(err, syscall.ENOENT) {
			return nil, nil
		}
		return nil, err
	}
	if initial.Uid != expectedUID {
		return nil, errors.New("unexpected room entry owner")
	}
	entry := &cleanupEntry{name: name, identity: initial}
	switch initial.Mode & unix.S_IFMT {
	case unix.S_IFREG:
		return entry, nil
	case unix.S_IFDIR:
		directoryDescriptor, err := unix.Openat(
			parentDescriptor,
			name,
			unix.O_RDONLY|unix.O_CLOEXEC|unix.O_DIRECTORY|unix.O_NOFOLLOW,
			0,
		)
		if err != nil {
			return nil, err
		}
		var opened unix.Stat_t
		if err := unix.Fstat(directoryDescriptor, &opened); err != nil {
			_ = unix.Close(directoryDescriptor)
			return nil, err
		}
		if err := requireSameDirectoryIdentity(initial, opened, expectedUID); err != nil {
			_ = unix.Close(directoryDescriptor)
			return nil, err
		}
		entry.directory = os.NewFile(uintptr(directoryDescriptor), "<lan-room-directory>")
		if entry.directory == nil {
			_ = unix.Close(directoryDescriptor)
			return nil, errors.New("invalid room directory")
		}
		names, err := entry.directory.Readdirnames(-1)
		if err != nil {
			closeCleanupEntry(entry)
			return nil, err
		}
		entry.children = make([]*cleanupEntry, 0, len(names))
		for _, childName := range names {
			child, err := preflightEntryAt(directoryDescriptor, childName, false, expectedUID)
			if err != nil {
				closeCleanupEntry(entry)
				return nil, err
			}
			entry.children = append(entry.children, child)
		}
		return entry, nil
	default:
		return nil, errors.New("unsupported room entry")
	}
}

func deletePreflightedEntry(parentDescriptor int, entry *cleanupEntry, expectedUID uint32) error {
	if entry == nil || !validCleanupEntryName(entry.name) {
		return errors.New("invalid room entry")
	}
	if entry.identity.Mode&unix.S_IFMT == unix.S_IFREG {
		return removeUnchangedEntry(parentDescriptor, entry.name, entry.identity, expectedUID, 0)
	}
	if entry.identity.Mode&unix.S_IFMT != unix.S_IFDIR || entry.directory == nil {
		return errors.New("invalid room directory")
	}
	directoryDescriptor := int(entry.directory.Fd())
	var opened unix.Stat_t
	if err := unix.Fstat(directoryDescriptor, &opened); err != nil {
		return err
	}
	if err := requireSameDirectoryIdentity(entry.identity, opened, expectedUID); err != nil {
		return err
	}
	for _, child := range entry.children {
		if err := deletePreflightedEntry(directoryDescriptor, child, expectedUID); err != nil {
			return err
		}
	}
	if err := unix.Fstat(directoryDescriptor, &opened); err != nil {
		return err
	}
	if err := requireSameDirectoryIdentity(entry.identity, opened, expectedUID); err != nil {
		return err
	}
	if err := entry.directory.Close(); err != nil {
		return err
	}
	entry.directory = nil
	return removeUnchangedEntry(parentDescriptor, entry.name, entry.identity, expectedUID, unix.AT_REMOVEDIR)
}

func requireSameDirectoryIdentity(initial unix.Stat_t, opened unix.Stat_t, expectedUID uint32) error {
	if initial.Mode&unix.S_IFMT != unix.S_IFDIR ||
		opened.Mode&unix.S_IFMT != unix.S_IFDIR ||
		initial.Uid != expectedUID ||
		opened.Uid != expectedUID ||
		opened.Dev != initial.Dev ||
		opened.Ino != initial.Ino {
		return errors.New("room directory changed during cleanup")
	}
	return nil
}

func requireSameOwnedEntryIdentity(initial unix.Stat_t, current unix.Stat_t, expectedUID uint32) error {
	if initial.Uid != expectedUID ||
		current.Uid != expectedUID ||
		current.Dev != initial.Dev ||
		current.Ino != initial.Ino ||
		current.Mode&unix.S_IFMT != initial.Mode&unix.S_IFMT {
		return errors.New("room entry changed during cleanup")
	}
	return nil
}

func removeUnchangedEntry(parentDescriptor int, name string, initial unix.Stat_t, expectedUID uint32, flags int) error {
	var current unix.Stat_t
	if err := unix.Fstatat(parentDescriptor, name, &current, unix.AT_SYMLINK_NOFOLLOW); err != nil {
		return err
	}
	if err := requireSameOwnedEntryIdentity(initial, current, expectedUID); err != nil {
		return err
	}
	return unix.Unlinkat(parentDescriptor, name, flags)
}

func closeCleanupEntry(entry *cleanupEntry) {
	if entry == nil {
		return
	}
	for _, child := range entry.children {
		closeCleanupEntry(child)
	}
	if entry.directory != nil {
		_ = entry.directory.Close()
		entry.directory = nil
	}
}

func validCleanupEntryName(name string) bool {
	return name != "" && name != "." && name != ".." && !strings.ContainsRune(name, '/')
}
