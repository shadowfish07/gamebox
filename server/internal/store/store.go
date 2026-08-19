package store

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"fmt"
	"net/url"
	"os"
	"strings"
	"sync/atomic"
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
	if err := ctx.Err(); err != nil {
		return nil, fmt.Errorf("store: open database: %w", err)
	}
	if strings.TrimSpace(path) == "" {
		return nil, errors.New("store: database path is empty")
	}
	if path == ":memory:" {
		return nil, errors.New("store: in-memory databases do not support durable WAL mode")
	}
	if err := secureSQLiteFiles(path); err != nil {
		return nil, fmt.Errorf("store: secure database files: %w", err)
	}

	dsn := "file:" + escapeURIPath(path) +
		"?_journal_mode=WAL&_foreign_keys=on&_busy_timeout=5000&_txlock=immediate"
	baseConnector, err := sqlite.NewConnector(dsn)
	if err != nil {
		return nil, fmt.Errorf("store: configure database: %w", err)
	}
	db := sql.OpenDB(cancelableConnector{Connector: baseConnector})
	db.SetMaxOpenConns(maxConnections)
	db.SetMaxIdleConns(maxConnections)

	if err := pingContext(ctx, db); err != nil {
		return nil, closeAfterError(db, fmt.Errorf("store: ping database: %w", err))
	}
	if err := migrate(ctx, db); err != nil {
		return nil, closeAfterError(db, fmt.Errorf("store: migrate database: %w", err))
	}
	if err := secureSQLiteSidecars(path); err != nil {
		return nil, closeAfterError(db, fmt.Errorf("store: secure database sidecars: %w", err))
	}
	return db, nil
}

func pingContext(ctx context.Context, db *sql.DB) error {
	retryCtx, cancel := context.WithTimeout(ctx, connectionRetryLimit)
	defer cancel()

	retryDelay := 5 * time.Millisecond
	for {
		err := db.PingContext(retryCtx)
		if err == nil || !isSQLiteBusy(err) {
			return err
		}

		delay := time.NewTimer(retryDelay)
		select {
		case <-retryCtx.Done():
			delay.Stop()
			return retryCtx.Err()
		case <-delay.C:
		}
		if retryDelay < 100*time.Millisecond {
			retryDelay *= 2
		}
	}
}

type cancelableConnector struct {
	driver.Connector
}

type connectionResult struct {
	conn driver.Conn
	err  error
}

var activeConnectorWorkers atomic.Int64

func (c cancelableConnector) Connect(ctx context.Context) (driver.Conn, error) {
	result := make(chan connectionResult, 1)
	activeConnectorWorkers.Add(1)
	go func() {
		defer activeConnectorWorkers.Add(-1)
		conn, err := c.Connector.Connect(ctx)
		result <- connectionResult{conn: conn, err: err}
	}()

	select {
	case opened := <-result:
		return opened.conn, opened.err
	case <-ctx.Done():
		activeConnectorWorkers.Add(1)
		go func() {
			defer activeConnectorWorkers.Add(-1)
			closeLateConnection(result)
		}()
		return nil, ctx.Err()
	}
}

func closeLateConnection(result <-chan connectionResult) {
	opened := <-result
	if opened.conn != nil {
		_ = opened.conn.Close()
	}
}

func isSQLiteBusy(err error) bool {
	var sqliteErr *sqlite.Error
	return errors.As(err, &sqliteErr) && sqliteErr.Code()&0xff == sqliteBusyCode
}

func escapeURIPath(path string) string {
	return (&url.URL{Path: path}).EscapedPath()
}

func secureSQLiteFiles(path string) error {
	if err := secureDatabaseFile(path); err != nil {
		return err
	}
	return secureSQLiteSidecars(path)
}

func secureDatabaseFile(path string) error {
	for {
		info, err := os.Lstat(path)
		switch {
		case errors.Is(err, os.ErrNotExist):
			file, createErr := os.OpenFile(path, os.O_RDWR|os.O_CREATE|os.O_EXCL, 0o600)
			if errors.Is(createErr, os.ErrExist) {
				continue
			}
			if createErr != nil {
				return fmt.Errorf("create database: %w", createErr)
			}
			return secureOpenFile(path, file)
		case err != nil:
			return fmt.Errorf("inspect database: %w", err)
		case !info.Mode().IsRegular():
			return fmt.Errorf("database path is not a regular file")
		}

		file, err := os.Open(path)
		if err != nil {
			return fmt.Errorf("open database for permission check: %w", err)
		}
		return secureOpenFile(path, file)
	}
}

func secureSQLiteSidecars(path string) error {
	for _, suffix := range []string{"-wal", "-shm"} {
		if err := secureExistingFile(path + suffix); err != nil {
			return fmt.Errorf("secure %s sidecar: %w", strings.TrimPrefix(suffix, "-"), err)
		}
	}
	return nil
}

func secureExistingFile(path string) error {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("inspect file: %w", err)
	}
	if !info.Mode().IsRegular() {
		return errors.New("path is not a regular file")
	}
	file, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("open file for permission check: %w", err)
	}
	return secureOpenFile(path, file)
}

func secureOpenFile(path string, file *os.File) (err error) {
	defer func() {
		if closeErr := file.Close(); closeErr != nil {
			err = errors.Join(err, fmt.Errorf("close secured file: %w", closeErr))
		}
	}()

	openedInfo, err := file.Stat()
	if err != nil {
		return fmt.Errorf("inspect opened file: %w", err)
	}
	pathInfo, err := os.Lstat(path)
	if err != nil {
		return fmt.Errorf("reinspect file path: %w", err)
	}
	if !openedInfo.Mode().IsRegular() || !pathInfo.Mode().IsRegular() || !os.SameFile(openedInfo, pathInfo) {
		return errors.New("file changed during permission check")
	}
	if err := file.Chmod(0o600); err != nil {
		return fmt.Errorf("set file mode 0600: %w", err)
	}
	return nil
}

func closeAfterError(db *sql.DB, cause error) error {
	if err := db.Close(); err != nil {
		return errors.Join(cause, fmt.Errorf("store: close database after failure: %w", err))
	}
	return cause
}
