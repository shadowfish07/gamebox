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
	if len(after) != len(before) {
		t.Fatalf("read-only live WAL open changed directory entries: before=%+v after=%+v", before, after)
	}
	for name := range before {
		if _, exists := after[name]; !exists {
			t.Fatalf("read-only live WAL open removed %s", name)
		}
	}
	if after["."] != before["."] || after["gamebox.sqlite"] != before["gamebox.sqlite"] {
		t.Fatalf("read-only live WAL open changed directory or main database: before=%+v after=%+v", before, after)
	}
	for _, sidecar := range []string{"gamebox.sqlite-wal", "gamebox.sqlite-shm"} {
		if after[sidecar].Mode != before[sidecar].Mode || after[sidecar].Size != before[sidecar].Size {
			t.Fatalf("read-only live WAL open changed %s shape: before=%+v after=%+v", sidecar, before[sidecar], after[sidecar])
		}
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
