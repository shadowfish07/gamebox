package store

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"embed"
	"encoding/hex"
	"errors"
	"fmt"
	"sort"
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
}

func migrate(ctx context.Context, db *sql.DB) error {
	if err := validateMigrationRegistry(migrations); err != nil {
		return err
	}

	loaded := make([]loadedMigration, 0, len(migrations))
	for _, item := range migrations {
		contents, err := migrationFiles.ReadFile(item.path)
		if err != nil {
			return fmt.Errorf("read migration %d: %w", item.version, err)
		}
		loaded = append(loaded, newLoadedMigration(item.version, string(contents)))
	}
	return migrateLoaded(ctx, db, loaded)
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

	applied, err := readAppliedMigrations(ctx, tx)
	if err != nil {
		return err
	}
	expected := make(map[int]loadedMigration, len(loaded))
	for _, item := range loaded {
		expected[item.version] = item
	}
	appliedVersions := make([]int, 0, len(applied))
	for version := range applied {
		appliedVersions = append(appliedVersions, version)
	}
	sort.Ints(appliedVersions)
	for _, version := range appliedVersions {
		checksum := applied[version]
		item, ok := expected[version]
		if !ok {
			return fmt.Errorf("database contains unknown migration version %d", version)
		}
		if checksum != item.checksum {
			return fmt.Errorf("migration %d checksum mismatch", version)
		}
	}

	for _, item := range loaded {
		if _, ok := applied[item.version]; ok {
			continue
		}
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

func readAppliedMigrations(ctx context.Context, tx *sql.Tx) (map[int]string, error) {
	rows, err := tx.QueryContext(ctx, `SELECT version, checksum FROM schema_migrations ORDER BY version`)
	if err != nil {
		return nil, fmt.Errorf("read migration ledger: %w", err)
	}
	defer rows.Close()

	applied := make(map[int]string)
	for rows.Next() {
		var version int
		var checksum string
		if err := rows.Scan(&version, &checksum); err != nil {
			return nil, fmt.Errorf("scan migration ledger: %w", err)
		}
		applied[version] = checksum
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate migration ledger: %w", err)
	}
	return applied, nil
}
