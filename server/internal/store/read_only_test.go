package store

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestOpenReadOnlyRequiresExistingDatabaseWithoutChangingDirectory(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "missing.sqlite")
	before := readOnlyDirectorySnapshot(t, directory)
	database, err := OpenReadOnly(context.Background(), path)
	if database != nil || err == nil {
		if database != nil {
			_ = database.Close()
		}
		t.Fatalf("OpenReadOnly missing=(%v,%v)", database, err)
	}
	if after := readOnlyDirectorySnapshot(t, directory); !reflect.DeepEqual(after, before) {
		t.Fatalf("missing open changed directory: before=%+v after=%+v", before, after)
	}
}

func TestOpenReadOnlyValidatesCurrentSchemaAndCannotWriteWithoutMutation(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "gamebox.sqlite")
	writable, err := Open(context.Background(), path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := writable.Exec(`INSERT INTO invite_codes(code_hash,created_at) VALUES (?,?)`, strings.Repeat("a", 64), 1); err != nil {
		_ = writable.Close()
		t.Fatal(err)
	}
	if err := writable.Close(); err != nil {
		t.Fatal(err)
	}
	before := readOnlyDirectorySnapshot(t, directory)

	readOnly, err := OpenReadOnly(context.Background(), path)
	if err != nil {
		t.Fatalf("OpenReadOnly: %v", err)
	}
	var queryOnly int
	if err := readOnly.QueryRow(`PRAGMA query_only`).Scan(&queryOnly); err != nil || queryOnly != 1 {
		_ = readOnly.Close()
		t.Fatalf("query_only=%d err=%v", queryOnly, err)
	}
	if _, err := readOnly.Exec(`UPDATE invite_codes SET created_at=2`); err == nil {
		_ = readOnly.Close()
		t.Fatal("read-only database accepted a write")
	}
	var migrationCount, invites int
	if err := readOnly.QueryRow(`SELECT COUNT(*) FROM schema_migrations`).Scan(&migrationCount); err != nil || migrationCount != len(migrations) {
		_ = readOnly.Close()
		t.Fatalf("migrations=%d err=%v", migrationCount, err)
	}
	if err := readOnly.QueryRow(`SELECT COUNT(*) FROM invite_codes`).Scan(&invites); err != nil || invites != 1 {
		_ = readOnly.Close()
		t.Fatalf("invites=%d err=%v", invites, err)
	}
	if err := readOnly.Close(); err != nil {
		t.Fatal(err)
	}
	if after := readOnlyDirectorySnapshot(t, directory); !reflect.DeepEqual(after, before) {
		t.Fatalf("read-only open changed filesystem: before=%+v after=%+v", before, after)
	}
}

func TestOpenReadOnlySeesCommittedLiveWALWithoutCreatingSidecars(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "gamebox.sqlite")
	writable, err := Open(context.Background(), path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = writable.Close() })
	hash := strings.Repeat("b", 64)
	if _, err := writable.Exec(`INSERT INTO invite_codes(code_hash,created_at) VALUES (?,?)`, hash, 2); err != nil {
		t.Fatal(err)
	}
	before := readOnlyDirectorySnapshot(t, directory)
	for _, sidecar := range []string{"gamebox.sqlite-wal", "gamebox.sqlite-shm"} {
		if _, exists := before[sidecar]; !exists {
			t.Fatalf("live writable store is missing %s: %+v", sidecar, before)
		}
	}

	readOnly, err := OpenReadOnly(context.Background(), path)
	if err != nil {
		t.Fatalf("OpenReadOnly live WAL: %v", err)
	}
	var createdAt int64
	if err := readOnly.QueryRow(`SELECT created_at FROM invite_codes WHERE code_hash=?`, hash).Scan(&createdAt); err != nil || createdAt != 2 {
		_ = readOnly.Close()
		t.Fatalf("live WAL row created_at=%d err=%v", createdAt, err)
	}
	if err := readOnly.Close(); err != nil {
		t.Fatal(err)
	}
	after := readOnlyDirectorySnapshot(t, directory)
	if !reflect.DeepEqual(after, before) {
		t.Fatalf("read-only live WAL open changed source bytes or metadata: before=%+v after=%+v", before, after)
	}
}

func TestOpenReadOnlyLiveWALSnapshotCleansPrivateTemporaryCopy(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "gamebox.sqlite")
	writable, err := Open(context.Background(), path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = writable.Close() })
	hash := strings.Repeat("c", 64)
	if _, err := writable.Exec(`INSERT INTO invite_codes(code_hash,created_at) VALUES (?,?)`, hash, 3); err != nil {
		t.Fatal(err)
	}
	snapshotParent := t.TempDir()
	readOnly, err := openReadOnly(context.Background(), path, readOnlyHooks{snapshotParent: snapshotParent})
	if err != nil {
		t.Fatalf("openReadOnly: %v", err)
	}
	entries, err := os.ReadDir(snapshotParent)
	if err != nil || len(entries) != 1 || !entries[0].IsDir() {
		_ = readOnly.Close()
		t.Fatalf("temporary snapshot entries=%v err=%v", entries, err)
	}
	if info, err := entries[0].Info(); err != nil || info.Mode().Perm() != 0o700 {
		_ = readOnly.Close()
		t.Fatalf("temporary snapshot directory mode=%v err=%v", info, err)
	}
	snapshotFiles, err := os.ReadDir(filepath.Join(snapshotParent, entries[0].Name()))
	if err != nil || len(snapshotFiles) == 0 {
		_ = readOnly.Close()
		t.Fatalf("temporary snapshot files=%v err=%v", snapshotFiles, err)
	}
	for _, entry := range snapshotFiles {
		info, infoErr := entry.Info()
		if infoErr != nil || !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 {
			_ = readOnly.Close()
			t.Fatalf("temporary snapshot file %q mode=%v err=%v", entry.Name(), info, infoErr)
		}
	}
	if err := readOnly.Close(); err != nil {
		t.Fatal(err)
	}
	entries, err = os.ReadDir(snapshotParent)
	if err != nil || len(entries) != 0 {
		t.Fatalf("temporary snapshot leaked after close: entries=%v err=%v", entries, err)
	}
}

func TestOpenReadOnlyRetriesWhenLiveWALChangesDuringCopy(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "gamebox.sqlite")
	writable, err := Open(context.Background(), path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = writable.Close() })
	hash := strings.Repeat("d", 64)
	if _, err := writable.Exec(`INSERT INTO invite_codes(code_hash,created_at) VALUES (?,?)`, hash, 4); err != nil {
		t.Fatal(err)
	}
	snapshotParent := t.TempDir()
	changed := false
	readOnly, err := openReadOnly(context.Background(), path, readOnlyHooks{
		snapshotParent: snapshotParent,
		afterSourceCopy: func() error {
			if changed {
				return nil
			}
			changed = true
			_, err := writable.Exec(`UPDATE invite_codes SET created_at=5 WHERE code_hash=?`, hash)
			return err
		},
	})
	if err != nil {
		t.Fatalf("openReadOnly retry: %v", err)
	}
	var createdAt int64
	if err := readOnly.QueryRow(`SELECT created_at FROM invite_codes WHERE code_hash=?`, hash).Scan(&createdAt); err != nil || createdAt != 5 {
		_ = readOnly.Close()
		t.Fatalf("retried snapshot created_at=%d err=%v", createdAt, err)
	}
	if err := readOnly.Close(); err != nil {
		t.Fatal(err)
	}
	if entries, readErr := os.ReadDir(snapshotParent); readErr != nil || len(entries) != 0 {
		t.Fatalf("retry leaked failed or successful snapshot: entries=%v err=%v", entries, readErr)
	}
}

func TestOpenReadOnlyLiveWALBusyFailureAndCancellationCleanTemporaryCopies(t *testing.T) {
	t.Run("bounded busy failure", func(t *testing.T) {
		directory := t.TempDir()
		path := filepath.Join(directory, "gamebox.sqlite")
		writable, err := Open(context.Background(), path)
		if err != nil {
			t.Fatal(err)
		}
		defer writable.Close()
		hash := strings.Repeat("e", 64)
		if _, err := writable.Exec(`INSERT INTO invite_codes(code_hash,created_at) VALUES (?,?)`, hash, 5); err != nil {
			t.Fatal(err)
		}
		snapshotParent := t.TempDir()
		database, err := openReadOnly(context.Background(), path, readOnlyHooks{
			snapshotParent: snapshotParent,
			afterSourceCopy: func() error {
				_, err := writable.Exec(`UPDATE invite_codes SET created_at=created_at+1 WHERE code_hash=?`, hash)
				return err
			},
		})
		if database != nil || !errors.Is(err, ErrReadOnlySnapshotBusy) {
			if database != nil {
				_ = database.Close()
			}
			t.Fatalf("busy openReadOnly=(%v,%v)", database, err)
		}
		if strings.Contains(err.Error(), directory) || strings.Contains(err.Error(), snapshotParent) {
			t.Fatalf("busy error leaks path: %v", err)
		}
		if entries, readErr := os.ReadDir(snapshotParent); readErr != nil || len(entries) != 0 {
			t.Fatalf("busy failure leaked snapshot: entries=%v err=%v", entries, readErr)
		}
	})

	t.Run("cancellation after snapshot copy", func(t *testing.T) {
		directory := t.TempDir()
		path := filepath.Join(directory, "gamebox.sqlite")
		writable, err := Open(context.Background(), path)
		if err != nil {
			t.Fatal(err)
		}
		defer writable.Close()
		if _, err := writable.Exec(`INSERT INTO invite_codes(code_hash,created_at) VALUES (?,?)`, strings.Repeat("f", 64), 6); err != nil {
			t.Fatal(err)
		}
		ctx, cancel := context.WithCancel(context.Background())
		snapshotParent := t.TempDir()
		database, err := openReadOnly(ctx, path, readOnlyHooks{
			snapshotParent: snapshotParent,
			afterSourceCopy: func() error {
				cancel()
				return nil
			},
		})
		if database != nil || !errors.Is(err, context.Canceled) {
			if database != nil {
				_ = database.Close()
			}
			t.Fatalf("canceled openReadOnly=(%v,%v)", database, err)
		}
		if entries, readErr := os.ReadDir(snapshotParent); readErr != nil || len(entries) != 0 {
			t.Fatalf("cancellation leaked snapshot: entries=%v err=%v", entries, readErr)
		}
	})
}

func TestOpenReadOnlyRejectsLiveWALReplacementAndCleansSnapshot(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "gamebox.sqlite")
	writable, err := Open(context.Background(), path)
	if err != nil {
		t.Fatal(err)
	}
	defer writable.Close()
	if _, err := writable.Exec(`INSERT INTO invite_codes(code_hash,created_at) VALUES (?,?)`, strings.Repeat("1", 64), 7); err != nil {
		t.Fatal(err)
	}
	snapshotParent := t.TempDir()
	replaced := false
	database, err := openReadOnly(context.Background(), path, readOnlyHooks{
		snapshotParent: snapshotParent,
		afterSourceCopy: func() error {
			if replaced {
				return nil
			}
			replaced = true
			backup := path + "-wal-original"
			if err := os.Rename(path+"-wal", backup); err != nil {
				return err
			}
			return os.Symlink(backup, path+"-wal")
		},
	})
	if database != nil || err == nil {
		if database != nil {
			_ = database.Close()
		}
		t.Fatalf("replaced WAL openReadOnly=(%v,%v)", database, err)
	}
	if entries, readErr := os.ReadDir(snapshotParent); readErr != nil || len(entries) != 0 {
		t.Fatalf("replacement leaked snapshot: entries=%v err=%v", entries, readErr)
	}
}

func TestOpenReadOnlyRejectsUnmigratedAndInsecureFilesWithoutFixingThem(t *testing.T) {
	t.Run("unmigrated", func(t *testing.T) {
		directory := t.TempDir()
		path := filepath.Join(directory, "unmigrated.sqlite")
		raw, err := sql.Open("sqlite", "file:"+escapeURIPath(path))
		if err != nil {
			t.Fatal(err)
		}
		if _, err := raw.Exec(`CREATE TABLE placeholder (id INTEGER PRIMARY KEY)`); err != nil {
			_ = raw.Close()
			t.Fatal(err)
		}
		if err := raw.Close(); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(path, 0o600); err != nil {
			t.Fatal(err)
		}
		assertReadOnlyOpenFailsWithoutMutation(t, directory, path)
	})

	t.Run("incompatible migration ledger", func(t *testing.T) {
		directory := t.TempDir()
		path := filepath.Join(directory, "incompatible.sqlite")
		raw, err := sql.Open("sqlite", "file:"+escapeURIPath(path))
		if err != nil {
			t.Fatal(err)
		}
		if _, err := raw.Exec(`
CREATE TABLE schema_migrations (
  version INTEGER PRIMARY KEY,
  applied_at INTEGER NOT NULL
);
INSERT INTO schema_migrations(version,applied_at) VALUES (1,1)`); err != nil {
			_ = raw.Close()
			t.Fatal(err)
		}
		if err := raw.Close(); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(path, 0o600); err != nil {
			t.Fatal(err)
		}
		before := readOnlyDirectorySnapshot(t, directory)
		database, err := OpenReadOnly(context.Background(), path)
		if database != nil || !errors.Is(err, ErrIncompatibleMigrationLedger) {
			if database != nil {
				_ = database.Close()
			}
			t.Fatalf("OpenReadOnly incompatible=(%v,%v)", database, err)
		}
		if after := readOnlyDirectorySnapshot(t, directory); !reflect.DeepEqual(after, before) {
			t.Fatalf("incompatible open changed filesystem: before=%+v after=%+v", before, after)
		}
	})

	t.Run("insecure mode", func(t *testing.T) {
		directory := t.TempDir()
		path := filepath.Join(directory, "insecure.sqlite")
		database, err := Open(context.Background(), path)
		if err != nil {
			t.Fatal(err)
		}
		if err := database.Close(); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(path, 0o644); err != nil {
			t.Fatal(err)
		}
		assertReadOnlyOpenFailsWithoutMutation(t, directory, path)
	})

	t.Run("symlink", func(t *testing.T) {
		directory := t.TempDir()
		target := filepath.Join(directory, "target.sqlite")
		database, err := Open(context.Background(), target)
		if err != nil {
			t.Fatal(err)
		}
		if err := database.Close(); err != nil {
			t.Fatal(err)
		}
		path := filepath.Join(directory, "link.sqlite")
		if err := os.Symlink(target, path); err != nil {
			t.Fatal(err)
		}
		assertReadOnlyOpenFailsWithoutMutation(t, directory, path)
	})
}

type readOnlyFileSnapshot struct {
	Mode    os.FileMode
	Size    int64
	ModTime int64
	Hash    [sha256.Size]byte
	Link    string
}

func readOnlyDirectorySnapshot(t *testing.T, directory string) map[string]readOnlyFileSnapshot {
	t.Helper()
	entries, err := os.ReadDir(directory)
	if err != nil {
		t.Fatal(err)
	}
	result := make(map[string]readOnlyFileSnapshot, len(entries)+1)
	directoryInfo, err := os.Stat(directory)
	if err != nil {
		t.Fatal(err)
	}
	result["."] = readOnlyFileSnapshot{Mode: directoryInfo.Mode(), Size: directoryInfo.Size(), ModTime: directoryInfo.ModTime().UnixNano()}
	for _, entry := range entries {
		path := filepath.Join(directory, entry.Name())
		info, err := os.Lstat(path)
		if err != nil {
			t.Fatal(err)
		}
		snapshot := readOnlyFileSnapshot{Mode: info.Mode(), Size: info.Size(), ModTime: info.ModTime().UnixNano()}
		if info.Mode().IsRegular() {
			contents, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			snapshot.Hash = sha256.Sum256(contents)
		} else if info.Mode()&os.ModeSymlink != 0 {
			snapshot.Link, err = os.Readlink(path)
			if err != nil {
				t.Fatal(err)
			}
		}
		result[entry.Name()] = snapshot
	}
	return result
}

func assertReadOnlyOpenFailsWithoutMutation(t *testing.T, directory, path string) {
	t.Helper()
	before := readOnlyDirectorySnapshot(t, directory)
	database, err := OpenReadOnly(context.Background(), path)
	if database != nil || err == nil {
		if database != nil {
			_ = database.Close()
		}
		t.Fatalf("OpenReadOnly=(%v,%v)", database, err)
	}
	if after := readOnlyDirectorySnapshot(t, directory); !reflect.DeepEqual(after, before) {
		t.Fatalf("failed read-only open changed filesystem: before=%+v after=%+v", before, after)
	}
}

func TestOpenReadOnlyRejectsCanceledAndInvalidInputs(t *testing.T) {
	canceled, cancel := context.WithCancel(context.Background())
	cancel()
	if database, err := OpenReadOnly(canceled, filepath.Join(t.TempDir(), "missing.sqlite")); database != nil || !errors.Is(err, context.Canceled) {
		if database != nil {
			_ = database.Close()
		}
		t.Fatalf("canceled OpenReadOnly=(%v,%v)", database, err)
	}
	for _, path := range []string{"", " ", ":memory:"} {
		if database, err := OpenReadOnly(context.Background(), path); database != nil || err == nil {
			if database != nil {
				_ = database.Close()
			}
			t.Fatalf("OpenReadOnly(%q)=(%v,%v)", path, database, err)
		}
	}
}
