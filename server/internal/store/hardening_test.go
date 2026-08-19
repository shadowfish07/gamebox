package store

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"testing/fstest"
	"time"
)

func TestCancelableConnectorBoundsPhysicalAttemptsAcrossInstances(t *testing.T) {
	const requests = 100
	baselineGoroutines := runtime.NumGoroutine()
	base := &countingBlockingConnector{release: make(chan struct{})}

	start := make(chan struct{})
	errorsByRequest := make(chan error, requests)
	var callers sync.WaitGroup
	for request := 0; request < requests; request++ {
		callers.Add(1)
		go func() {
			defer callers.Done()
			<-start
			ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
			defer cancel()
			connector := cancelableConnector{Connector: base}
			conn, err := connector.Connect(ctx)
			if conn != nil {
				_ = conn.Close()
				errorsByRequest <- errors.New("canceled connector returned a connection")
				return
			}
			if !errors.Is(err, context.DeadlineExceeded) {
				errorsByRequest <- fmt.Errorf("Connect error = %v, want context deadline", err)
			}
		}()
	}
	close(start)
	callers.Wait()
	close(errorsByRequest)
	for err := range errorsByRequest {
		t.Error(err)
	}

	if started := base.started.Load(); started > maxConnections {
		t.Errorf("physical Connect attempts = %d, want <= %d", started, maxConnections)
	}
	if active := activeConnectorWorkers.Load(); active > maxConnections {
		t.Errorf("active connector workers = %d, want <= %d", active, maxConnections)
	}
	if maximum := base.maximum.Load(); maximum > maxConnections {
		t.Errorf("maximum concurrent physical Connect calls = %d, want <= %d", maximum, maxConnections)
	}
	// The hundred canceled callers have returned. Only the bounded physical
	// workers (plus a small test/runtime allowance) may remain.
	if goroutines := runtime.NumGoroutine(); goroutines > baselineGoroutines+maxConnections+8 {
		t.Errorf("goroutines after cancellation = %d, baseline %d; connector spawned unbounded cleanup workers", goroutines, baselineGoroutines)
	}

	close(base.release)
	waitForConnectorWorkers(t, 2*time.Second)
	if got, want := base.closed.Load(), base.started.Load(); got != want {
		t.Fatalf("closed late connections = %d, want %d", got, want)
	}
	if t.Failed() {
		return
	}

	// Permits are global across connector instances and must all be reusable.
	fast := cancelableConnector{Connector: immediateConnector{}}
	for i := 0; i < maxConnections*2; i++ {
		conn, err := fast.Connect(context.Background())
		if err != nil {
			t.Fatalf("Connect after releasing permits %d: %v", i, err)
		}
		if err := conn.Close(); err != nil {
			t.Fatalf("close connection %d: %v", i, err)
		}
	}
}

type countingBlockingConnector struct {
	release    chan struct{}
	started    atomic.Int64
	concurrent atomic.Int64
	maximum    atomic.Int64
	closed     atomic.Int64
}

func (c *countingBlockingConnector) Connect(context.Context) (driver.Conn, error) {
	c.started.Add(1)
	concurrent := c.concurrent.Add(1)
	for {
		maximum := c.maximum.Load()
		if concurrent <= maximum || c.maximum.CompareAndSwap(maximum, concurrent) {
			break
		}
	}
	<-c.release
	c.concurrent.Add(-1)
	return &countedConn{closed: &c.closed}, nil
}

func (*countingBlockingConnector) Driver() driver.Driver { return blockingDriver{} }

type immediateConnector struct{}

func (immediateConnector) Connect(context.Context) (driver.Conn, error) {
	return &countedConn{}, nil
}

func (immediateConnector) Driver() driver.Driver { return blockingDriver{} }

type countedConn struct {
	closed    *atomic.Int64
	closeOnce sync.Once
}

func (*countedConn) Prepare(string) (driver.Stmt, error) {
	return nil, errors.New("not implemented")
}

func (c *countedConn) Close() error {
	c.closeOnce.Do(func() {
		if c.closed != nil {
			c.closed.Add(1)
		}
	})
	return nil
}

func (*countedConn) Begin() (driver.Tx, error) {
	return nil, errors.New("not implemented")
}

func TestOpenRejectsDatabaseFileReplacementAfterPreflight(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "gamebox.sqlite")
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatalf("create original database: %v", err)
	}
	original := path + ".original"

	db, err := open(context.Background(), path, openHooks{afterPreflight: func() {
		if renameErr := os.Rename(path, original); renameErr != nil {
			t.Fatalf("rename original database: %v", renameErr)
		}
		if writeErr := os.WriteFile(path, nil, 0o600); writeErr != nil {
			t.Fatalf("create replacement database: %v", writeErr)
		}
	}})
	if db != nil {
		_ = db.Close()
		t.Fatal("Open returned a replacement database")
	}
	if err == nil || !strings.Contains(err.Error(), "database file identity changed") {
		t.Fatalf("replacement error = %v, want stable file identity diagnostic", err)
	}
	assertFileMode(t, original, 0o600)
}

func TestOpenRejectsParentReplacementAfterPreflight(t *testing.T) {
	root := t.TempDir()
	parent := filepath.Join(root, "database")
	if err := os.Mkdir(parent, 0o700); err != nil {
		t.Fatalf("create database parent: %v", err)
	}
	path := filepath.Join(parent, "gamebox.sqlite")
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatalf("create original database: %v", err)
	}
	originalParent := parent + ".original"

	db, err := open(context.Background(), path, openHooks{afterPreflight: func() {
		if renameErr := os.Rename(parent, originalParent); renameErr != nil {
			t.Fatalf("rename original parent: %v", renameErr)
		}
		if mkdirErr := os.Mkdir(parent, 0o700); mkdirErr != nil {
			t.Fatalf("create replacement parent: %v", mkdirErr)
		}
		if writeErr := os.WriteFile(path, nil, 0o600); writeErr != nil {
			t.Fatalf("create database in replacement parent: %v", writeErr)
		}
	}})
	if db != nil {
		_ = db.Close()
		t.Fatal("Open returned a database from a replacement parent")
	}
	if err == nil || !strings.Contains(err.Error(), "database parent identity changed") {
		t.Fatalf("parent replacement error = %v, want stable parent identity diagnostic", err)
	}
}

func TestOpenRequiresPrivateDirectParent(t *testing.T) {
	root := t.TempDir()
	untrusted := filepath.Join(root, "untrusted")
	if err := os.Mkdir(untrusted, 0o777); err != nil {
		t.Fatalf("create untrusted parent: %v", err)
	}
	if err := os.Chmod(untrusted, 0o777); err != nil {
		t.Fatalf("chmod untrusted parent: %v", err)
	}
	if db, err := Open(context.Background(), filepath.Join(untrusted, "gamebox.sqlite")); !errors.Is(err, ErrInsecureDatabaseParent) || db != nil {
		if db != nil {
			_ = db.Close()
		}
		t.Fatalf("Open writable-parent error = %v, want ErrInsecureDatabaseParent", err)
	}
	assertFileMode(t, untrusted, 0o777)

	sticky := filepath.Join(root, "sticky")
	if err := os.Mkdir(sticky, 0o777); err != nil {
		t.Fatalf("create sticky parent: %v", err)
	}
	if err := os.Chmod(sticky, os.ModeSticky|0o777); err != nil {
		t.Fatalf("chmod sticky parent: %v", err)
	}
	if db, err := Open(context.Background(), filepath.Join(sticky, "gamebox.sqlite")); !errors.Is(err, ErrInsecureDatabaseParent) || db != nil {
		if db != nil {
			_ = db.Close()
		}
		t.Fatalf("Open sticky-parent error = %v, want ErrInsecureDatabaseParent", err)
	}

	private := filepath.Join(sticky, "private")
	if err := os.Mkdir(private, 0o700); err != nil {
		t.Fatalf("create private child: %v", err)
	}
	if err := os.Chmod(private, 0o700); err != nil {
		t.Fatalf("chmod private child: %v", err)
	}
	path := filepath.Join(private, "gamebox.sqlite")
	db, err := Open(context.Background(), path)
	if err != nil {
		t.Fatalf("Open in private child of sticky ancestor: %v", err)
	}
	tx, err := db.Begin()
	if err != nil {
		_ = db.Close()
		t.Fatalf("begin private-child sidecar transaction: %v", err)
	}
	if _, err := tx.Exec(`INSERT INTO users(id,nickname,normalized_nickname,created_at,updated_at) VALUES ('private-user','Private User','private-user',1,1)`); err != nil {
		_ = tx.Rollback()
		_ = db.Close()
		t.Fatalf("write private-child sidecar transaction: %v", err)
	}
	for _, securedPath := range []string{path, path + "-wal", path + "-shm"} {
		assertFileMode(t, securedPath, 0o600)
	}
	if err := tx.Rollback(); err != nil {
		_ = db.Close()
		t.Fatalf("rollback private-child transaction: %v", err)
	}
	if err := db.Close(); err != nil {
		t.Fatalf("close private-child database: %v", err)
	}
}

func TestOpenAndOpenReadOnlyRejectForeignOwnedDirectParentWithoutMutation(t *testing.T) {
	root := t.TempDir()
	parent := filepath.Join(root, "foreign-parent")
	if err := os.Mkdir(parent, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(parent, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(parent, "gamebox.sqlite")
	foreignUID := uint32(os.Geteuid()) + 1
	security := fileSecurityHooks{statPath: func(requested string) (os.FileInfo, error) {
		info, err := os.Stat(requested)
		if err != nil || requested != parent {
			return info, err
		}
		return fileInfoWithOwner(t, info, foreignUID), nil
	}}

	beforeMissing := readOnlyDirectorySnapshot(t, parent)
	database, err := open(context.Background(), path, openHooks{security: security})
	if database != nil || !errors.Is(err, ErrInsecureDatabaseParent) {
		if database != nil {
			_ = database.Close()
		}
		t.Fatalf("foreign-owned Open=(%v,%v)", database, err)
	}
	if after := readOnlyDirectorySnapshot(t, parent); !reflect.DeepEqual(after, beforeMissing) {
		t.Fatalf("foreign-owned Open mutated parent: before=%+v after=%+v", beforeMissing, after)
	}

	database, err = Open(context.Background(), path)
	if err != nil {
		t.Fatal(err)
	}
	if err := database.Close(); err != nil {
		t.Fatal(err)
	}
	beforeExisting := readOnlyDirectorySnapshot(t, parent)
	snapshotParent := t.TempDir()
	database, err = openReadOnly(context.Background(), path, readOnlyHooks{security: security, snapshotParent: snapshotParent})
	if database != nil || !errors.Is(err, ErrInsecureDatabaseParent) {
		if database != nil {
			_ = database.Close()
		}
		t.Fatalf("foreign-owned OpenReadOnly=(%v,%v)", database, err)
	}
	if after := readOnlyDirectorySnapshot(t, parent); !reflect.DeepEqual(after, beforeExisting) {
		t.Fatalf("foreign-owned OpenReadOnly mutated source: before=%+v after=%+v", beforeExisting, after)
	}
	if entries, readErr := os.ReadDir(snapshotParent); readErr != nil || len(entries) != 0 {
		t.Fatalf("foreign-owned OpenReadOnly leaked temp: entries=%v err=%v", entries, readErr)
	}
}

func TestOpenReadOnlyRejectsParentOwnerABADuringLiveWALCopy(t *testing.T) {
	directory := t.TempDir()
	path := filepath.Join(directory, "gamebox.sqlite")
	writable, err := Open(context.Background(), path)
	if err != nil {
		t.Fatal(err)
	}
	defer writable.Close()
	if _, err := writable.Exec(`INSERT INTO invite_codes(code_hash,created_at) VALUES (?,?)`, strings.Repeat("9", 64), 9); err != nil {
		t.Fatal(err)
	}
	before := readOnlyDirectorySnapshot(t, directory)
	foreignUID := uint32(os.Geteuid()) + 1
	var exposeForeign atomic.Bool
	var foreignObservations atomic.Int64
	security := fileSecurityHooks{statPath: func(requested string) (os.FileInfo, error) {
		info, err := os.Stat(requested)
		if err != nil || requested != directory || !exposeForeign.CompareAndSwap(true, false) {
			return info, err
		}
		foreignObservations.Add(1)
		return fileInfoWithOwner(t, info, foreignUID), nil
	}}
	snapshotParent := t.TempDir()
	readOnly, err := openReadOnly(context.Background(), path, readOnlyHooks{
		security:       security,
		snapshotParent: snapshotParent,
		afterSourceCopy: func() error {
			exposeForeign.Store(true)
			return nil
		},
	})
	if readOnly != nil || !errors.Is(err, ErrInsecureDatabaseParent) {
		if readOnly != nil {
			_ = readOnly.Close()
		}
		t.Fatalf("owner ABA OpenReadOnly=(%v,%v)", readOnly, err)
	}
	if foreignObservations.Load() != 1 || exposeForeign.Load() {
		t.Fatalf("owner ABA observations=%d pending=%t", foreignObservations.Load(), exposeForeign.Load())
	}
	if after := readOnlyDirectorySnapshot(t, directory); !reflect.DeepEqual(after, before) {
		t.Fatalf("owner ABA check mutated source: before=%+v after=%+v", before, after)
	}
	if entries, readErr := os.ReadDir(snapshotParent); readErr != nil || len(entries) != 0 {
		t.Fatalf("owner ABA leaked temp: entries=%v err=%v", entries, readErr)
	}
}

func TestOpenAndOpenReadOnlyAllowCurrentOwnedPrivateParentUnderTmp(t *testing.T) {
	directory, err := os.MkdirTemp("/tmp", "gamebox-current-owner-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(directory) })
	if err := os.Chmod(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(directory, "gamebox.sqlite")
	database, err := Open(context.Background(), path)
	if err != nil {
		t.Fatalf("Open current-owned /tmp child: %v", err)
	}
	if err := database.Close(); err != nil {
		t.Fatal(err)
	}
	readOnly, err := OpenReadOnly(context.Background(), path)
	if err != nil {
		t.Fatalf("OpenReadOnly current-owned /tmp child: %v", err)
	}
	if err := readOnly.Close(); err != nil {
		t.Fatal(err)
	}
}

type ownerOverrideFileInfo struct {
	os.FileInfo
	stat syscall.Stat_t
}

func (info ownerOverrideFileInfo) Sys() any { return &info.stat }

func fileInfoWithOwner(t *testing.T, info os.FileInfo, uid uint32) os.FileInfo {
	t.Helper()
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		t.Fatalf("file info sys=%T, want *syscall.Stat_t", info.Sys())
	}
	cloned := *stat
	cloned.Uid = uid
	return ownerOverrideFileInfo{FileInfo: info, stat: cloned}
}

func TestOpenRejectsHardlinkedDatabaseWithoutChangingTarget(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	target := filepath.Join(dir, "unrelated")
	path := filepath.Join(dir, "gamebox.sqlite")
	if err := os.WriteFile(target, nil, 0o644); err != nil {
		t.Fatalf("create unrelated hardlink target: %v", err)
	}
	if err := os.Chmod(target, 0o644); err != nil {
		t.Fatalf("chmod unrelated hardlink target: %v", err)
	}
	if err := os.Link(target, path); err != nil {
		t.Fatalf("create database hardlink: %v", err)
	}

	db, err := Open(context.Background(), path)
	if db != nil {
		_ = db.Close()
		t.Fatal("Open returned a hardlinked database")
	}
	if err == nil {
		t.Fatal("Open accepted a hardlinked database")
	}
	assertFileMode(t, target, 0o644)
}

func TestMigrationLedgerMustBeRegistryPrefix(t *testing.T) {
	loaded := []loadedMigration{
		newLoadedMigration(1, `CREATE TABLE migration_one (id INTEGER PRIMARY KEY);`),
		newLoadedMigration(2, `CREATE TABLE migration_two (id INTEGER PRIMARY KEY);`),
		newLoadedMigration(3, `CREATE TABLE migration_three (id INTEGER PRIMARY KEY);`),
	}
	tests := []struct {
		name        string
		versions    []int
		wantMessage string
	}{
		{name: "only second", versions: []int{2}, wantMessage: "migration ledger is not a registry prefix: expected version 1, found 2"},
		{name: "middle hole", versions: []int{1, 3}, wantMessage: "migration ledger is not a registry prefix: expected version 2, found 3"},
		{name: "unknown extra", versions: []int{1, 2, 4}, wantMessage: "unknown migration version 4"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			db := openRawDatabase(t, filepath.Join(t.TempDir(), "prefix.sqlite"))
			defer db.Close()
			createMigrationLedger(t, db)
			for _, version := range test.versions {
				checksum := strings.Repeat("f", 64)
				for _, item := range loaded {
					if item.version == version {
						checksum = item.checksum
					}
				}
				mustExec(t, db, `INSERT INTO schema_migrations(version, checksum, applied_at) VALUES (?, ?, 1)`, version, checksum)
			}

			err := migrateLoaded(context.Background(), db, loaded)
			if err == nil || !strings.Contains(err.Error(), test.wantMessage) {
				t.Fatalf("migrateLoaded error = %v, want %q", err, test.wantMessage)
			}
			var created int
			if err := db.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='migration_one'`).Scan(&created); err != nil {
				t.Fatalf("inspect backwards migration: %v", err)
			}
			if created != 0 {
				t.Fatal("migration runner filled a missing prefix backwards")
			}
		})
	}
}

func TestMigrationLedgerValidPrefixAppliesOnlySuffix(t *testing.T) {
	loaded := []loadedMigration{
		newLoadedMigration(1, `CREATE TABLE migration_one (id INTEGER PRIMARY KEY);`),
		newLoadedMigration(2, `CREATE TABLE migration_two (id INTEGER PRIMARY KEY);`),
		newLoadedMigration(3, `CREATE TABLE migration_three (id INTEGER PRIMARY KEY);`),
	}
	db := openRawDatabase(t, filepath.Join(t.TempDir(), "valid-prefix.sqlite"))
	defer db.Close()
	createMigrationLedger(t, db)
	mustExec(t, db, loaded[0].script)
	mustExec(t, db, `INSERT INTO schema_migrations(version, checksum, applied_at) VALUES (1, ?, 1)`, loaded[0].checksum)

	if err := migrateLoaded(context.Background(), db, loaded); err != nil {
		t.Fatalf("migrate valid prefix: %v", err)
	}
	var count int
	if err := db.QueryRow(`SELECT COUNT(*) FROM schema_migrations`).Scan(&count); err != nil {
		t.Fatalf("count applied suffix: %v", err)
	}
	if count != 3 {
		t.Fatalf("migration ledger count = %d, want 3", count)
	}
}

func TestEmbeddedMigrationRegistryCompleteness(t *testing.T) {
	t.Parallel()

	validFS := fstest.MapFS{
		"migrations/001_one.sql": {Data: []byte("SELECT 1;")},
		"migrations/002_two.sql": {Data: []byte("SELECT 2;")},
		"migrations/readme.txt":  {Data: []byte("ignored")},
	}
	tests := []struct {
		name     string
		registry []migration
		wantErr  bool
	}{
		{name: "complete", registry: []migration{{version: 1, path: "migrations/001_one.sql"}, {version: 2, path: "migrations/002_two.sql"}}},
		{name: "unregistered sql", registry: []migration{{version: 1, path: "migrations/001_one.sql"}}, wantErr: true},
		{name: "duplicate path", registry: []migration{{version: 1, path: "migrations/001_one.sql"}, {version: 2, path: "migrations/001_one.sql"}}, wantErr: true},
		{name: "missing path", registry: []migration{{version: 1, path: "migrations/001_one.sql"}, {version: 2, path: "migrations/003_missing.sql"}}, wantErr: true},
		{name: "noncanonical path", registry: []migration{{version: 1, path: "migrations/../migrations/001_one.sql"}, {version: 2, path: "migrations/002_two.sql"}}, wantErr: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			err := validateEmbeddedMigrationRegistry(test.registry, validFS)
			if (err != nil) != test.wantErr {
				t.Fatalf("validateEmbeddedMigrationRegistry error = %v, wantErr %v", err, test.wantErr)
			}
		})
	}
	if err := validateEmbeddedMigrationRegistry(migrations, migrationFiles); err != nil {
		t.Fatalf("production embedded registry: %v", err)
	}
}

func TestOldTwoColumnMigrationLedgerIsExplicitlyIncompatible(t *testing.T) {
	t.Parallel()

	db := openRawDatabase(t, filepath.Join(t.TempDir(), "old-ledger.sqlite"))
	defer db.Close()
	mustExec(t, db, `CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL)`)
	mustExec(t, db, `INSERT INTO schema_migrations(version, applied_at) VALUES (1, 1)`)
	err := migrateLoaded(context.Background(), db, []loadedMigration{newLoadedMigration(1, `SELECT 1;`)})
	if !errors.Is(err, ErrIncompatibleMigrationLedger) {
		t.Fatalf("old ledger error = %v, want ErrIncompatibleMigrationLedger", err)
	}
	if got, want := err.Error(), ErrIncompatibleMigrationLedger.Error(); got != want {
		t.Fatalf("old ledger diagnostic = %q, want fixed %q", got, want)
	}
}

func openRawDatabase(t *testing.T, path string) *sql.DB {
	t.Helper()
	dsn := "file:" + escapeURIPath(path) + "?_journal_mode=WAL&_foreign_keys=on&_busy_timeout=5000&_txlock=immediate"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		t.Fatalf("open raw database: %v", err)
	}
	if err := db.Ping(); err != nil {
		_ = db.Close()
		t.Fatalf("ping raw database: %v", err)
	}
	return db
}

func createMigrationLedger(t *testing.T, db *sql.DB) {
	t.Helper()
	mustExec(t, db, `CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, checksum TEXT NOT NULL, applied_at INTEGER NOT NULL)`)
}
