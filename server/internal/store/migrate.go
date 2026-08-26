package store

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"embed"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	pathpkg "path"
	"strings"
)

//go:embed migrations/*.sql
var migrationFiles embed.FS

type migration struct {
	version int
	path    string
}

type loadedMigration struct {
	version  int
	script   string
	checksum string
}

var migrations = []migration{
	{version: 1, path: "migrations/001_initial.sql"},
	{version: 2, path: "migrations/002_match_history_indexes.sql"},
	{version: 3, path: "migrations/003_match_player_nickname.sql"},
}

// ErrIncompatibleMigrationLedger tells operators that a pre-release database
// predating checksum tracking must be recreated instead of silently upgraded.
var ErrIncompatibleMigrationLedger = errors.New("migration ledger is incompatible; recreate the pre-release database")

func migrate(ctx context.Context, db *sql.DB) error {
	loaded, err := loadRegisteredMigrations()
	if err != nil {
		return err
	}
	return migrateLoaded(ctx, db, loaded)
}

func loadRegisteredMigrations() ([]loadedMigration, error) {
	if err := validateMigrationRegistry(migrations); err != nil {
		return nil, err
	}
	if err := validateEmbeddedMigrationRegistry(migrations, migrationFiles); err != nil {
		return nil, err
	}

	loaded := make([]loadedMigration, 0, len(migrations))
	for _, item := range migrations {
		contents, err := migrationFiles.ReadFile(item.path)
		if err != nil {
			return nil, fmt.Errorf("read migration %d: %w", item.version, err)
		}
		loaded = append(loaded, newLoadedMigration(item.version, string(contents)))
	}
	return loaded, nil
}

func validateCurrentMigrations(ctx context.Context, db *sql.DB) (err error) {
	loaded, err := loadRegisteredMigrations()
	if err != nil {
		return err
	}
	transaction, err := db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return fmt.Errorf("begin read-only migration validation: %w", err)
	}
	defer func() {
		if rollbackErr := transaction.Rollback(); rollbackErr != nil && !errors.Is(rollbackErr, sql.ErrTxDone) && err == nil {
			err = fmt.Errorf("rollback read-only migration validation: %w", rollbackErr)
		}
	}()
	if err := validateMigrationLedgerSchema(ctx, transaction); err != nil {
		return err
	}
	applied, err := readAppliedMigrations(ctx, transaction)
	if err != nil {
		return err
	}
	if err := validateAppliedMigrations(applied, loaded); err != nil {
		return err
	}
	if len(applied) != len(loaded) {
		return errors.New("database migrations are incomplete")
	}
	if err := transaction.Commit(); err != nil {
		return fmt.Errorf("commit read-only migration validation: %w", err)
	}
	return nil
}

func validateMigrationRegistry(registry []migration) error {
	previousVersion := 0
	for index, item := range registry {
		if item.version <= 0 {
			return fmt.Errorf("migration registry entry %d has nonpositive version", index)
		}
		if index > 0 && item.version <= previousVersion {
			return fmt.Errorf("migration registry is not strictly increasing at entry %d", index)
		}
		if item.path == "" {
			return fmt.Errorf("migration registry entry %d has empty path", index)
		}
		previousVersion = item.version
	}
	return nil
}

func validateEmbeddedMigrationRegistry(registry []migration, migrationFS fs.FS) error {
	registered := make(map[string]struct{}, len(registry))
	for index, item := range registry {
		if pathpkg.Clean(item.path) != item.path || pathpkg.Dir(item.path) != "migrations" || pathpkg.Ext(item.path) != ".sql" {
			return fmt.Errorf("migration registry entry %d has noncanonical SQL path", index)
		}
		if _, exists := registered[item.path]; exists {
			return fmt.Errorf("migration registry entry %d repeats an embedded path", index)
		}
		info, err := fs.Stat(migrationFS, item.path)
		if err != nil {
			return fmt.Errorf("migration registry entry %d does not name an embedded file", index)
		}
		if !info.Mode().IsRegular() {
			return fmt.Errorf("migration registry entry %d does not name a regular file", index)
		}
		registered[item.path] = struct{}{}
	}

	entries, err := fs.ReadDir(migrationFS, "migrations")
	if err != nil {
		return fmt.Errorf("read embedded migration directory: %w", err)
	}
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".sql") {
			continue
		}
		migrationPath := pathpkg.Join("migrations", entry.Name())
		if _, exists := registered[migrationPath]; !exists {
			return fmt.Errorf("embedded SQL migration %q is not registered", migrationPath)
		}
	}
	return nil
}

func newLoadedMigration(version int, script string) loadedMigration {
	digest := sha256.Sum256([]byte(script))
	return loadedMigration{
		version:  version,
		script:   script,
		checksum: hex.EncodeToString(digest[:]),
	}
}

func applyMigration(ctx context.Context, db *sql.DB, version int, script string) error {
	if version <= 0 {
		return errors.New("migration version must be positive")
	}
	return migrateLoaded(ctx, db, []loadedMigration{newLoadedMigration(version, script)})
}

func migrateLoaded(ctx context.Context, db *sql.DB, loaded []loadedMigration) (err error) {
	for index, item := range loaded {
		if item.version <= 0 || (index > 0 && item.version <= loaded[index-1].version) {
			return errors.New("loaded migrations are not strictly increasing positive versions")
		}
	}

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin migrations: %w", err)
	}
	defer func() {
		if rollbackErr := tx.Rollback(); rollbackErr != nil && !errors.Is(rollbackErr, sql.ErrTxDone) {
			err = errors.Join(err, fmt.Errorf("rollback migrations: %w", rollbackErr))
		}
	}()

	if _, err := tx.ExecContext(ctx, `
CREATE TABLE IF NOT EXISTS schema_migrations (
  version INTEGER PRIMARY KEY,
  checksum TEXT NOT NULL,
  applied_at INTEGER NOT NULL
)`); err != nil {
		return fmt.Errorf("create migration ledger: %w", err)
	}
	if err := validateMigrationLedgerSchema(ctx, tx); err != nil {
		return err
	}

	applied, err := readAppliedMigrations(ctx, tx)
	if err != nil {
		return err
	}
	if err := validateAppliedMigrations(applied, loaded); err != nil {
		return err
	}

	for _, item := range loaded[len(applied):] {
		if _, err := tx.ExecContext(ctx, item.script); err != nil {
			return fmt.Errorf("apply migration %d: %w", item.version, err)
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO schema_migrations(version, checksum, applied_at) VALUES (?, ?, unixepoch())`, item.version, item.checksum); err != nil {
			return fmt.Errorf("record migration %d: %w", item.version, err)
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit migrations: %w", err)
	}
	return nil
}

func validateAppliedMigrations(applied []appliedMigration, loaded []loadedMigration) error {
	for index, actual := range applied {
		if index >= len(loaded) {
			return fmt.Errorf("database contains unknown migration version %d", actual.version)
		}
		expected := loaded[index]
		if actual.version != expected.version {
			if containsMigrationVersion(loaded, actual.version) {
				return fmt.Errorf("migration ledger is not a registry prefix: expected version %d, found %d", expected.version, actual.version)
			}
			return fmt.Errorf("database contains unknown migration version %d", actual.version)
		}
		if actual.checksum != expected.checksum {
			return fmt.Errorf("migration %d checksum mismatch", actual.version)
		}
	}
	return nil
}

type appliedMigration struct {
	version  int
	checksum string
}

func readAppliedMigrations(ctx context.Context, tx *sql.Tx) ([]appliedMigration, error) {
	rows, err := tx.QueryContext(ctx, `SELECT version, checksum FROM schema_migrations ORDER BY version`)
	if err != nil {
		return nil, fmt.Errorf("read migration ledger: %w", err)
	}
	defer rows.Close()

	var applied []appliedMigration
	for rows.Next() {
		var item appliedMigration
		if err := rows.Scan(&item.version, &item.checksum); err != nil {
			return nil, fmt.Errorf("scan migration ledger: %w", err)
		}
		applied = append(applied, item)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate migration ledger: %w", err)
	}
	return applied, nil
}

func containsMigrationVersion(loaded []loadedMigration, version int) bool {
	for _, item := range loaded {
		if item.version == version {
			return true
		}
	}
	return false
}

func validateMigrationLedgerSchema(ctx context.Context, tx *sql.Tx) error {
	rows, err := tx.QueryContext(ctx, `PRAGMA table_info(schema_migrations)`)
	if err != nil {
		return fmt.Errorf("inspect migration ledger schema: %w", err)
	}
	defer rows.Close()

	type column struct {
		name     string
		typeName string
		notNull  int
		primary  int
	}
	var columns []column
	for rows.Next() {
		var item column
		var sequence int
		var defaultValue any
		if err := rows.Scan(&sequence, &item.name, &item.typeName, &item.notNull, &defaultValue, &item.primary); err != nil {
			return fmt.Errorf("scan migration ledger schema: %w", err)
		}
		columns = append(columns, item)
	}
	if err := rows.Err(); err != nil {
		return fmt.Errorf("iterate migration ledger schema: %w", err)
	}

	want := []column{
		{name: "version", typeName: "INTEGER", notNull: 0, primary: 1},
		{name: "checksum", typeName: "TEXT", notNull: 1, primary: 0},
		{name: "applied_at", typeName: "INTEGER", notNull: 1, primary: 0},
	}
	if len(columns) != len(want) {
		return ErrIncompatibleMigrationLedger
	}
	for index := range want {
		if columns[index] != want[index] {
			return ErrIncompatibleMigrationLedger
		}
	}
	return nil
}
