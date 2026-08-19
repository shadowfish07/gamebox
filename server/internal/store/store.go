package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"time"

	sqlite "modernc.org/sqlite"
)

const (
	maxConnections       = 8
	sqliteBusyCode       = 5
	connectionRetryLimit = 5 * time.Second
)

// Open opens a durable SQLite database, verifies the connection, and applies
// all pending schema migrations before returning it to the caller.
func Open(ctx context.Context, path string) (*sql.DB, error) {
	if strings.TrimSpace(path) == "" {
		return nil, errors.New("store: database path is empty")
	}
	if path == ":memory:" {
		return nil, errors.New("store: in-memory databases do not support durable WAL mode")
	}

	dsn := "file:" + escapeURIPath(path) +
		"?_journal_mode=WAL&_foreign_keys=on&_busy_timeout=5000&_txlock=immediate"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("store: open database: %w", err)
	}
	db.SetMaxOpenConns(maxConnections)
	db.SetMaxIdleConns(maxConnections)

	if err := pingContext(ctx, db); err != nil {
		return nil, closeAfterError(db, fmt.Errorf("store: ping database: %w", err))
	}
	if err := migrate(ctx, db); err != nil {
		return nil, closeAfterError(db, fmt.Errorf("store: migrate database: %w", err))
	}
	return db, nil
}

func pingContext(ctx context.Context, db *sql.DB) error {
	retryDeadline := time.NewTimer(connectionRetryLimit)
	defer retryDeadline.Stop()

	retryDelay := 5 * time.Millisecond
	for {
		err := db.PingContext(ctx)
		if err == nil || !isSQLiteBusy(err) {
			return err
		}

		delay := time.NewTimer(retryDelay)
		select {
		case <-ctx.Done():
			delay.Stop()
			return ctx.Err()
		case <-retryDeadline.C:
			delay.Stop()
			return err
		case <-delay.C:
		}
		if retryDelay < 100*time.Millisecond {
			retryDelay *= 2
		}
	}
}

func isSQLiteBusy(err error) bool {
	var sqliteErr *sqlite.Error
	return errors.As(err, &sqliteErr) && sqliteErr.Code()&0xff == sqliteBusyCode
}

func escapeURIPath(path string) string {
	return (&url.URL{Path: path}).EscapedPath()
}

func closeAfterError(db *sql.DB, cause error) error {
	if err := db.Close(); err != nil {
		return errors.Join(cause, fmt.Errorf("store: close database after failure: %w", err))
	}
	return cause
}
