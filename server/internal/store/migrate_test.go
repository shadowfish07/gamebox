package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
)

const initialMigrationVersion = 1

func TestOpenAndMigrate(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "game box #1?.sqlite")

	db := openDatabase(t, ctx, path)
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("database was not created at the exact requested path %q: %v", path, err)
	}
	assertPoolSettings(t, db)
	assertConnectionPragmas(t, ctx, db)
	if idle := db.Stats().Idle; idle != 8 {
		t.Fatalf("idle connections after returning full pool = %d, want 8", idle)
	}
	assertSchema(t, db)
	assertConstraints(t, db)

	before := schemaSnapshot(t, db)
	var firstAppliedAt int64
	if err := db.QueryRow(`SELECT applied_at FROM schema_migrations WHERE version = ?`, initialMigrationVersion).Scan(&firstAppliedAt); err != nil {
		t.Fatalf("read first migration record: %v", err)
	}
	if err := db.Close(); err != nil {
		t.Fatalf("close first database handle: %v", err)
	}

	db = openDatabase(t, ctx, path)
	t.Cleanup(func() { _ = db.Close() })
	assertConnectionPragmas(t, ctx, db)
	if after := schemaSnapshot(t, db); !slices.Equal(before, after) {
		t.Fatalf("schema changed after repeated migration\nbefore: %q\nafter:  %q", before, after)
	}

	var migrationCount int
	var secondAppliedAt int64
	if err := db.QueryRow(`SELECT COUNT(*), MIN(applied_at) FROM schema_migrations WHERE version = ?`, initialMigrationVersion).Scan(&migrationCount, &secondAppliedAt); err != nil {
		t.Fatalf("read repeated migration record: %v", err)
	}
	if migrationCount != 1 {
		t.Fatalf("migration version %d has %d records, want 1", initialMigrationVersion, migrationCount)
	}
	if secondAppliedAt != firstAppliedAt {
		t.Fatalf("repeated migration changed applied_at from %d to %d", firstAppliedAt, secondAppliedAt)
	}
	if secondAppliedAt <= 0 {
		t.Fatalf("migration applied_at = %d, want a Unix timestamp", secondAppliedAt)
	}
}

func TestConcurrentOpenAppliesMigrationOnce(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "concurrent.sqlite")
	const workers = 8

	start := make(chan struct{})
	errorsByWorker := make(chan error, workers)
	var wg sync.WaitGroup
	for worker := 0; worker < workers; worker++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			db, err := Open(ctx, path)
			if err != nil {
				errorsByWorker <- err
				return
			}
			if err := db.Close(); err != nil {
				errorsByWorker <- err
			}
		}()
	}
	close(start)
	wg.Wait()
	close(errorsByWorker)
	for err := range errorsByWorker {
		t.Errorf("concurrent Open: %v", err)
	}
	if t.Failed() {
		return
	}

	db := openDatabase(t, ctx, path)
	defer db.Close()
	var count int
	if err := db.QueryRow(`SELECT COUNT(*) FROM schema_migrations WHERE version = ?`, initialMigrationVersion).Scan(&count); err != nil {
		t.Fatalf("count migration records: %v", err)
	}
	if count != 1 {
		t.Fatalf("migration version %d has %d records, want 1", initialMigrationVersion, count)
	}
}

func TestFailedMigrationIsAtomicAndRetryable(t *testing.T) {
	t.Parallel()

	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "atomic.sqlite")
	dsn := "file:" + escapeURIPath(path) +
		"?_journal_mode=WAL&_foreign_keys=on&_busy_timeout=5000&_txlock=immediate"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		t.Fatalf("open raw database: %v", err)
	}
	defer db.Close()
	db.SetMaxOpenConns(8)
	db.SetMaxIdleConns(8)
	if err := db.PingContext(ctx); err != nil {
		t.Fatalf("ping raw database: %v", err)
	}

	const version = 99
	err = applyMigration(ctx, db, version, `
CREATE TABLE should_rollback (id INTEGER PRIMARY KEY);
INSERT INTO table_that_does_not_exist(id) VALUES (1);
`)
	if err == nil {
		t.Fatal("broken migration unexpectedly succeeded")
	}
	for _, table := range []string{"schema_migrations", "should_rollback"} {
		var count int
		if queryErr := db.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?`, table).Scan(&count); queryErr != nil {
			t.Fatalf("inspect table %q after rollback: %v", table, queryErr)
		}
		if count != 0 {
			t.Errorf("table %q survived failed migration", table)
		}
	}

	if err := applyMigration(ctx, db, version, `CREATE TABLE retry_succeeded (id INTEGER PRIMARY KEY);`); err != nil {
		t.Fatalf("retry migration: %v", err)
	}
	var recorded int
	if err := db.QueryRow(`SELECT COUNT(*) FROM schema_migrations WHERE version = ?`, version).Scan(&recorded); err != nil {
		t.Fatalf("read retried migration: %v", err)
	}
	if recorded != 1 {
		t.Fatalf("retried migration records = %d, want 1", recorded)
	}
}

func TestOpenRejectsNonDurableDatabasePaths(t *testing.T) {
	t.Parallel()

	for _, path := range []string{"", "   ", ":memory:"} {
		t.Run(fmt.Sprintf("path=%q", path), func(t *testing.T) {
			db, err := Open(context.Background(), path)
			if db != nil {
				_ = db.Close()
				t.Fatalf("Open(%q) returned a database", path)
			}
			if err == nil {
				t.Fatalf("Open(%q) unexpectedly succeeded", path)
			}
		})
	}
}

func TestOpenHonorsCanceledContext(t *testing.T) {
	t.Parallel()

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	db, err := Open(ctx, filepath.Join(t.TempDir(), "canceled.sqlite"))
	if db != nil {
		_ = db.Close()
		t.Fatal("Open returned a database for a canceled context")
	}
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("Open error = %v, want context.Canceled", err)
	}
}

func openDatabase(t *testing.T, ctx context.Context, path string) *sql.DB {
	t.Helper()

	db, err := Open(ctx, path)
	if err != nil {
		t.Fatalf("Open(%q): %v", path, err)
	}
	return db
}

func assertPoolSettings(t *testing.T, db *sql.DB) {
	t.Helper()

	stats := db.Stats()
	if stats.MaxOpenConnections != 8 {
		t.Fatalf("MaxOpenConnections = %d, want 8", stats.MaxOpenConnections)
	}
}

func assertConnectionPragmas(t *testing.T, ctx context.Context, db *sql.DB) {
	t.Helper()

	connections := make([]*sql.Conn, 0, 8)
	defer func() {
		for _, conn := range connections {
			_ = conn.Close()
		}
	}()

	// Holding all eight connections concurrently proves that DSN-level PRAGMAs
	// are applied to every connection, rather than only the first pooled one.
	for i := 0; i < 8; i++ {
		conn, err := db.Conn(ctx)
		if err != nil {
			t.Fatalf("acquire connection %d: %v", i, err)
		}
		connections = append(connections, conn)

		var journalMode string
		var foreignKeys, busyTimeout int
		if err := conn.QueryRowContext(ctx, `PRAGMA journal_mode`).Scan(&journalMode); err != nil {
			t.Fatalf("connection %d journal_mode: %v", i, err)
		}
		if err := conn.QueryRowContext(ctx, `PRAGMA foreign_keys`).Scan(&foreignKeys); err != nil {
			t.Fatalf("connection %d foreign_keys: %v", i, err)
		}
		if err := conn.QueryRowContext(ctx, `PRAGMA busy_timeout`).Scan(&busyTimeout); err != nil {
			t.Fatalf("connection %d busy_timeout: %v", i, err)
		}
		if !strings.EqualFold(journalMode, "wal") {
			t.Errorf("connection %d journal_mode = %q, want wal", i, journalMode)
		}
		if foreignKeys != 1 {
			t.Errorf("connection %d foreign_keys = %d, want 1", i, foreignKeys)
		}
		if busyTimeout != 5000 {
			t.Errorf("connection %d busy_timeout = %d, want 5000", i, busyTimeout)
		}
	}
}

func assertSchema(t *testing.T, db *sql.DB) {
	t.Helper()

	wantTables := []string{
		"active_game_slots",
		"invite_codes",
		"launch_tickets",
		"match_events",
		"match_players",
		"matches",
		"refresh_tokens",
		"resume_tokens",
		"schema_migrations",
		"users",
	}
	gotTables := objectNames(t, db, "table")
	if !slices.Equal(gotTables, wantTables) {
		t.Fatalf("tables = %q, want %q", gotTables, wantTables)
	}

	wantIndexes := map[string][]string{
		"idx_launch_tickets_expires_at":         {"expires_at"},
		"idx_match_events_match_id_revision":    {"match_id", "revision"},
		"idx_matches_status_both_offline_since": {"status", "both_offline_since"},
		"idx_resume_tokens_expires_at":          {"expires_at"},
	}
	for name, wantColumns := range wantIndexes {
		var count int
		if err := db.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = ?`, name).Scan(&count); err != nil {
			t.Fatalf("find index %q: %v", name, err)
		}
		if count != 1 {
			t.Errorf("index %q count = %d, want 1", name, count)
			continue
		}
		rows, err := db.Query(`SELECT name FROM pragma_index_info(?) ORDER BY seqno`, name)
		if err != nil {
			t.Fatalf("inspect index %q: %v", name, err)
		}
		var gotColumns []string
		for rows.Next() {
			var column string
			if err := rows.Scan(&column); err != nil {
				_ = rows.Close()
				t.Fatalf("scan index %q: %v", name, err)
			}
			gotColumns = append(gotColumns, column)
		}
		if err := rows.Close(); err != nil {
			t.Fatalf("close index %q rows: %v", name, err)
		}
		if !slices.Equal(gotColumns, wantColumns) {
			t.Errorf("index %q columns = %q, want %q", name, gotColumns, wantColumns)
		}
	}

	wantConstraintFragments := map[string][]string{
		"users": {
			"id TEXT PRIMARY KEY",
			"nickname TEXT NOT NULL",
			"normalized_nickname TEXT NOT NULL UNIQUE",
			"enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0,1))",
			"last_seen_at INTEGER",
			"created_at INTEGER NOT NULL",
			"updated_at INTEGER NOT NULL",
		},
		"invite_codes": {
			"code_hash TEXT PRIMARY KEY",
			"created_at INTEGER NOT NULL",
			"consumed_by TEXT REFERENCES users(id)",
			"consumed_at INTEGER",
			"CHECK ((consumed_by IS NULL) = (consumed_at IS NULL))",
		},
		"refresh_tokens": {
			"token_hash TEXT PRIMARY KEY",
			"user_id TEXT NOT NULL REFERENCES users(id)",
			"expires_at INTEGER NOT NULL",
			"revoked_at INTEGER",
			"created_at INTEGER NOT NULL",
		},
		"matches": {
			"id TEXT PRIMARY KEY",
			"game_id TEXT NOT NULL",
			"status TEXT NOT NULL CHECK (status IN ('active','cancelled','finished','abandoned'))",
			"revision INTEGER NOT NULL DEFAULT 0",
			"both_offline_since INTEGER",
			"result TEXT",
			"winner_user_id TEXT REFERENCES users(id)",
			"created_at INTEGER NOT NULL",
			"updated_at INTEGER NOT NULL",
			"finished_at INTEGER",
		},
		"match_players": {
			"match_id TEXT NOT NULL REFERENCES matches(id)",
			"user_id TEXT NOT NULL REFERENCES users(id)",
			"seat INTEGER NOT NULL CHECK (seat IN (0,1))",
			"color TEXT NOT NULL CHECK (color IN ('black','white'))",
			"PRIMARY KEY (match_id, user_id)",
			"UNIQUE (match_id, seat)",
			"UNIQUE (match_id, color)",
		},
		"match_events": {
			"match_id TEXT NOT NULL REFERENCES matches(id)",
			"revision INTEGER NOT NULL",
			"event_type TEXT NOT NULL",
			"action_id TEXT",
			"actor_user_id TEXT REFERENCES users(id)",
			"payload_json TEXT NOT NULL",
			"created_at INTEGER NOT NULL",
			"PRIMARY KEY (match_id, revision)",
			"UNIQUE (match_id, actor_user_id, action_id)",
		},
		"active_game_slots": {
			"game_id TEXT NOT NULL",
			"user_id TEXT NOT NULL REFERENCES users(id)",
			"match_id TEXT NOT NULL REFERENCES matches(id)",
			"PRIMARY KEY (game_id, user_id)",
			"UNIQUE (game_id, match_id, user_id)",
		},
		"launch_tickets": {
			"token_hash TEXT PRIMARY KEY",
			"match_id TEXT NOT NULL REFERENCES matches(id)",
			"user_id TEXT NOT NULL REFERENCES users(id)",
			"game_id TEXT NOT NULL",
			"expires_at INTEGER NOT NULL",
			"consumed_at INTEGER",
			"created_at INTEGER NOT NULL",
		},
		"resume_tokens": {
			"token_hash TEXT PRIMARY KEY",
			"match_id TEXT NOT NULL REFERENCES matches(id)",
			"user_id TEXT NOT NULL REFERENCES users(id)",
			"expires_at INTEGER NOT NULL",
			"last_used_at INTEGER NOT NULL",
			"revoked_at INTEGER",
			"created_at INTEGER NOT NULL",
		},
	}
	for table, fragments := range wantConstraintFragments {
		var definition string
		if err := db.QueryRow(`SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?`, table).Scan(&definition); err != nil {
			t.Fatalf("read %s definition: %v", table, err)
		}
		normalizedDefinition := normalizeSQL(definition)
		for _, fragment := range fragments {
			if !strings.Contains(normalizedDefinition, normalizeSQL(fragment)) {
				t.Errorf("table %s missing constraint %q in %q", table, fragment, normalizedDefinition)
			}
		}
	}

	var migrationSQL string
	if err := db.QueryRow(`SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'schema_migrations'`).Scan(&migrationSQL); err != nil {
		t.Fatalf("read schema_migrations definition: %v", err)
	}
	normalized := normalizeSQL(migrationSQL)
	for _, fragment := range []string{"version integer primary key", "applied_at integer not null"} {
		if !strings.Contains(normalized, fragment) {
			t.Errorf("schema_migrations missing %q in %q", fragment, normalized)
		}
	}
}

func assertConstraints(t *testing.T, db *sql.DB) {
	t.Helper()

	mustExec(t, db, `INSERT INTO users(id,nickname,normalized_nickname,created_at,updated_at) VALUES ('u1','Alice','alice',1,1)`)
	mustExec(t, db, `INSERT INTO users(id,nickname,normalized_nickname,created_at,updated_at) VALUES ('u2','Bob','bob',1,1)`)
	mustFail(t, db, `INSERT INTO users(id,nickname,normalized_nickname,created_at,updated_at) VALUES ('u3','ALICE','alice',1,1)`)
	mustFail(t, db, `INSERT INTO users(id,nickname,normalized_nickname,enabled,created_at,updated_at) VALUES ('u3','Eve','eve',2,1,1)`)

	mustFail(t, db, `INSERT INTO invite_codes(code_hash,created_at,consumed_by) VALUES ('bad-pair',1,'u1')`)
	mustFail(t, db, `INSERT INTO invite_codes(code_hash,created_at,consumed_by,consumed_at) VALUES ('bad-fk',1,'missing',2)`)
	mustFail(t, db, `INSERT INTO refresh_tokens(token_hash,user_id,expires_at,created_at) VALUES ('refresh','missing',2,1)`)

	mustExec(t, db, `INSERT INTO matches(id,game_id,status,created_at,updated_at) VALUES ('m1','gomoku','active',1,1)`)
	mustFail(t, db, `INSERT INTO matches(id,game_id,status,created_at,updated_at) VALUES ('m-bad','gomoku','pending',1,1)`)
	mustFail(t, db, `INSERT INTO matches(id,game_id,status,winner_user_id,created_at,updated_at) VALUES ('m-fk','gomoku','finished','missing',1,1)`)

	mustExec(t, db, `INSERT INTO match_players(match_id,user_id,seat,color) VALUES ('m1','u1',0,'black')`)
	mustFail(t, db, `INSERT INTO match_players(match_id,user_id,seat,color) VALUES ('m1','u2',0,'white')`)
	mustFail(t, db, `INSERT INTO match_players(match_id,user_id,seat,color) VALUES ('m1','u2',1,'black')`)
	mustFail(t, db, `INSERT INTO match_players(match_id,user_id,seat,color) VALUES ('m1','u2',2,'white')`)
	mustFail(t, db, `INSERT INTO match_players(match_id,user_id,seat,color) VALUES ('m1','u2',1,'red')`)

	mustExec(t, db, `INSERT INTO match_events(match_id,revision,event_type,action_id,actor_user_id,payload_json,created_at) VALUES ('m1',1,'move','a1','u1','{}',1)`)
	mustFail(t, db, `INSERT INTO match_events(match_id,revision,event_type,action_id,actor_user_id,payload_json,created_at) VALUES ('m1',1,'move','a2','u2','{}',1)`)
	mustFail(t, db, `INSERT INTO match_events(match_id,revision,event_type,action_id,actor_user_id,payload_json,created_at) VALUES ('m1',2,'move','a1','u1','{}',1)`)

	mustExec(t, db, `INSERT INTO active_game_slots(game_id,user_id,match_id) VALUES ('gomoku','u1','m1')`)
	mustFail(t, db, `INSERT INTO active_game_slots(game_id,user_id,match_id) VALUES ('gomoku','u1','m1')`)
	mustFail(t, db, `INSERT INTO active_game_slots(game_id,user_id,match_id) VALUES ('gomoku','missing','m1')`)

	mustFail(t, db, `INSERT INTO launch_tickets(token_hash,match_id,user_id,game_id,expires_at,created_at) VALUES ('launch','missing','u1','gomoku',2,1)`)
	mustFail(t, db, `INSERT INTO resume_tokens(token_hash,match_id,user_id,expires_at,last_used_at,created_at) VALUES ('resume','m1','missing',2,1,1)`)
}

func objectNames(t *testing.T, db *sql.DB, objectType string) []string {
	t.Helper()

	rows, err := db.Query(`SELECT name FROM sqlite_master WHERE type = ? AND name NOT LIKE 'sqlite_%' ORDER BY name`, objectType)
	if err != nil {
		t.Fatalf("list %s objects: %v", objectType, err)
	}
	defer rows.Close()

	var names []string
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			t.Fatalf("scan %s name: %v", objectType, err)
		}
		names = append(names, name)
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("iterate %s names: %v", objectType, err)
	}
	return names
}

func schemaSnapshot(t *testing.T, db *sql.DB) []string {
	t.Helper()

	rows, err := db.Query(`SELECT type || ':' || name || ':' || COALESCE(sql, '') FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name`)
	if err != nil {
		t.Fatalf("snapshot schema: %v", err)
	}
	defer rows.Close()

	var snapshot []string
	for rows.Next() {
		var definition string
		if err := rows.Scan(&definition); err != nil {
			t.Fatalf("scan schema snapshot: %v", err)
		}
		snapshot = append(snapshot, definition)
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("iterate schema snapshot: %v", err)
	}
	return snapshot
}

func normalizeSQL(value string) string {
	return strings.ToLower(strings.Join(strings.Fields(value), " "))
}

func mustExec(t *testing.T, db *sql.DB, query string) {
	t.Helper()
	if _, err := db.Exec(query); err != nil {
		t.Fatalf("query unexpectedly failed: %s: %v", query, err)
	}
}

func mustFail(t *testing.T, db *sql.DB, query string) {
	t.Helper()
	if _, err := db.Exec(query); err == nil {
		t.Fatalf("query unexpectedly succeeded: %s", query)
	}
}
