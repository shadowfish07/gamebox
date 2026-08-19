package store

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	sqlite "modernc.org/sqlite"
)

const (
	maxConnections       = 8
	sqliteBusyCode       = 5
	connectionRetryLimit = 5 * time.Second
)

// ErrInsecureDatabaseParent requires callers to place SQLite files in a
// direct parent that other users cannot write.
var ErrInsecureDatabaseParent = errors.New("database parent is group/world-writable; use a private directory")

// Open opens a durable SQLite database, verifies the connection, and applies
// all pending schema migrations before returning it to the caller.
func Open(ctx context.Context, path string) (*sql.DB, error) {
	return open(ctx, path, openHooks{})
}

// OpenReadOnly opens an existing, fully migrated database without repairing
// permissions, creating the database, changing journal mode, or applying
// migrations. The returned pool and every SQLite connection are read-only.
func OpenReadOnly(ctx context.Context, path string) (*sql.DB, error) {
	if ctx == nil {
		return nil, errors.New("store: read-only context is nil")
	}
	if err := ctx.Err(); err != nil {
		return nil, fmt.Errorf("store: open read-only database: %w", err)
	}
	if strings.TrimSpace(path) == "" {
		return nil, errors.New("store: read-only database path is empty")
	}
	if path == ":memory:" {
		return nil, errors.New("store: read-only database must be a durable file")
	}
	guard, liveWAL, err := inspectSQLiteFilesReadOnly(path)
	if err != nil {
		return nil, fmt.Errorf("store: inspect read-only database files: %w", err)
	}
	dsn := "file:" + escapeURIPath(path) + "?mode=ro&_foreign_keys=on&_busy_timeout=5000&_query_only=1"
	if !liveWAL {
		// store.Open checkpoints and removes WAL sidecars on the last close. An
		// immutable view of that closed file avoids SQLite creating a new empty
		// WAL/SHM pair merely to perform an administrative read.
		dsn += "&immutable=1"
	}
	baseConnector, err := sqlite.NewConnector(dsn)
	if err != nil {
		return nil, closeOpenResources(nil, guard, fmt.Errorf("store: configure read-only database: %w", err))
	}
	db := sql.OpenDB(cancelableConnector{Connector: baseConnector})
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	if err := pingContext(ctx, db); err != nil {
		return nil, closeOpenResources(db, guard, fmt.Errorf("store: ping read-only database: %w", err))
	}
	if err := validateCurrentMigrations(ctx, db); err != nil {
		return nil, closeOpenResources(db, guard, fmt.Errorf("store: validate read-only database: %w", err))
	}
	if err := guard.Verify(); err != nil {
		return nil, closeOpenResources(db, guard, fmt.Errorf("store: verify read-only database identity: %w", err))
	}
	currentLiveWAL, err := inspectSQLiteSidecarsReadOnly(path)
	if err != nil {
		return nil, closeOpenResources(db, guard, fmt.Errorf("store: inspect read-only database sidecars: %w", err))
	}
	if currentLiveWAL != liveWAL {
		return nil, closeOpenResources(db, guard, errors.New("store: read-only database sidecar set changed"))
	}
	if err := guard.Verify(); err != nil {
		return nil, closeOpenResources(db, guard, fmt.Errorf("store: reverify read-only database identity: %w", err))
	}
	if err := guard.Close(); err != nil {
		return nil, closeAfterError(db, fmt.Errorf("store: close read-only database file guard: %w", err))
	}
	return db, nil
}

type openHooks struct {
	afterPreflight func()
}

func open(ctx context.Context, path string, hooks openHooks) (*sql.DB, error) {
	if err := ctx.Err(); err != nil {
		return nil, fmt.Errorf("store: open database: %w", err)
	}
	if strings.TrimSpace(path) == "" {
		return nil, errors.New("store: database path is empty")
	}
	if path == ":memory:" {
		return nil, errors.New("store: in-memory databases do not support durable WAL mode")
	}
	guard, err := secureSQLiteFiles(path)
	if err != nil {
		return nil, fmt.Errorf("store: secure database files: %w", err)
	}
	if hooks.afterPreflight != nil {
		hooks.afterPreflight()
	}

	dsn := "file:" + escapeURIPath(path) +
		"?_journal_mode=WAL&_foreign_keys=on&_busy_timeout=5000&_txlock=immediate"
	baseConnector, err := sqlite.NewConnector(dsn)
	if err != nil {
		return nil, closeOpenResources(nil, guard, fmt.Errorf("store: configure database: %w", err))
	}
	db := sql.OpenDB(cancelableConnector{Connector: baseConnector})
	db.SetMaxOpenConns(maxConnections)
	db.SetMaxIdleConns(maxConnections)

	if err := pingContext(ctx, db); err != nil {
		return nil, closeOpenResources(db, guard, fmt.Errorf("store: ping database: %w", err))
	}
	if err := migrate(ctx, db); err != nil {
		return nil, closeOpenResources(db, guard, fmt.Errorf("store: migrate database: %w", err))
	}
	if err := guard.Verify(); err != nil {
		return nil, closeOpenResources(db, guard, fmt.Errorf("store: verify database identity: %w", err))
	}
	if err := secureSQLiteSidecars(path); err != nil {
		return nil, closeOpenResources(db, guard, fmt.Errorf("store: secure database sidecars: %w", err))
	}
	if err := guard.Verify(); err != nil {
		return nil, closeOpenResources(db, guard, fmt.Errorf("store: reverify database identity: %w", err))
	}
	if err := guard.Close(); err != nil {
		return nil, closeAfterError(db, fmt.Errorf("store: close database file guard: %w", err))
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

var (
	physicalConnectPermits = make(chan struct{}, maxConnections)
	activeConnectorWorkers atomic.Int64
)

func (c cancelableConnector) Connect(ctx context.Context) (driver.Conn, error) {
	select {
	case physicalConnectPermits <- struct{}{}:
	case <-ctx.Done():
		return nil, ctx.Err()
	}

	result := make(chan connectionResult)
	decision := make(chan bool)
	canceled := make(chan struct{})
	activeConnectorWorkers.Add(1)
	go func() {
		defer func() {
			activeConnectorWorkers.Add(-1)
			<-physicalConnectPermits
		}()
		conn, err := c.Connector.Connect(ctx)
		if err != nil && conn != nil {
			_ = conn.Close()
			conn = nil
		}
		opened := connectionResult{conn: conn, err: err}
		select {
		case result <- opened:
			if accepted := <-decision; !accepted && opened.conn != nil {
				_ = opened.conn.Close()
			}
		case <-canceled:
			if opened.conn != nil {
				_ = opened.conn.Close()
			}
		}
	}()

	select {
	case opened := <-result:
		accepted := ctx.Err() == nil
		decision <- accepted
		if !accepted {
			return nil, ctx.Err()
		}
		return opened.conn, opened.err
	case <-ctx.Done():
		close(canceled)
		return nil, ctx.Err()
	}
}

func isSQLiteBusy(err error) bool {
	var sqliteErr *sqlite.Error
	return errors.As(err, &sqliteErr) && sqliteErr.Code()&0xff == sqliteBusyCode
}

func escapeURIPath(path string) string {
	return (&url.URL{Path: path}).EscapedPath()
}

type databaseFileGuard struct {
	path       string
	parentPath string
	file       *os.File
	parent     *os.File
	fileInfo   os.FileInfo
	parentInfo os.FileInfo
}

func secureSQLiteFiles(path string) (*databaseFileGuard, error) {
	parentPath := filepath.Dir(path)
	parent, err := os.Open(parentPath)
	if err != nil {
		return nil, fmt.Errorf("open database parent: %w", err)
	}
	parentInfo, err := verifyParentPath(parentPath, parent, nil)
	if err != nil {
		_ = parent.Close()
		return nil, err
	}

	file, fileInfo, err := secureDatabaseFile(path)
	if err != nil {
		_ = parent.Close()
		return nil, err
	}
	guard := &databaseFileGuard{
		path:       path,
		parentPath: parentPath,
		file:       file,
		parent:     parent,
		fileInfo:   fileInfo,
		parentInfo: parentInfo,
	}
	if err := secureSQLiteSidecars(path); err != nil {
		return nil, closeOpenResources(nil, guard, err)
	}
	if err := guard.Verify(); err != nil {
		return nil, closeOpenResources(nil, guard, err)
	}
	return guard, nil
}

func inspectSQLiteFilesReadOnly(path string) (*databaseFileGuard, bool, error) {
	parentPath := filepath.Dir(path)
	parent, err := os.Open(parentPath)
	if err != nil {
		return nil, false, fmt.Errorf("open database parent: %w", err)
	}
	parentInfo, err := verifyParentPath(parentPath, parent, nil)
	if err != nil {
		_ = parent.Close()
		return nil, false, err
	}
	file, fileInfo, err := inspectExistingFileReadOnly(path)
	if err != nil {
		_ = parent.Close()
		return nil, false, err
	}
	guard := &databaseFileGuard{
		path: path, parentPath: parentPath, file: file, parent: parent,
		fileInfo: fileInfo, parentInfo: parentInfo,
	}
	liveWAL, err := inspectSQLiteSidecarsReadOnly(path)
	if err != nil {
		return nil, false, closeOpenResources(nil, guard, err)
	}
	if err := guard.Verify(); err != nil {
		return nil, false, closeOpenResources(nil, guard, err)
	}
	return guard, liveWAL, nil
}

func inspectSQLiteSidecarsReadOnly(path string) (bool, error) {
	present := [2]bool{}
	index := 0
	for _, suffix := range []string{"-wal", "-shm"} {
		file, _, err := inspectOptionalFileReadOnly(path + suffix)
		if err != nil {
			return false, fmt.Errorf("inspect %s sidecar: %w", strings.TrimPrefix(suffix, "-"), err)
		}
		if file != nil {
			present[index] = true
			if err := file.Close(); err != nil {
				return false, fmt.Errorf("close %s sidecar: %w", strings.TrimPrefix(suffix, "-"), err)
			}
		}
		index++
	}
	if present[0] != present[1] {
		return false, errors.New("database has an incomplete WAL sidecar set")
	}
	return present[0], nil
}

func inspectExistingFileReadOnly(path string) (*os.File, os.FileInfo, error) {
	file, info, err := inspectOptionalFileReadOnly(path)
	if err != nil {
		return nil, nil, err
	}
	if file == nil {
		return nil, nil, errors.New("database file does not exist")
	}
	return file, info, nil
}

func inspectOptionalFileReadOnly(path string) (*os.File, os.FileInfo, error) {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil, nil
	}
	if err != nil {
		return nil, nil, fmt.Errorf("inspect file: %w", err)
	}
	if !info.Mode().IsRegular() {
		return nil, nil, errors.New("path is not a regular file")
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, nil, fmt.Errorf("open file for read-only verification: %w", err)
	}
	openedInfo, err := file.Stat()
	if err != nil {
		_ = file.Close()
		return nil, nil, fmt.Errorf("inspect opened file: %w", err)
	}
	pathInfo, err := os.Lstat(path)
	if err != nil || !pathInfo.Mode().IsRegular() || !os.SameFile(openedInfo, pathInfo) {
		_ = file.Close()
		return nil, nil, errors.New("file changed during read-only verification")
	}
	if err := requireCurrentOwner(openedInfo, "file"); err != nil {
		_ = file.Close()
		return nil, nil, err
	}
	if err := requireSingleLink(openedInfo, "file"); err != nil {
		_ = file.Close()
		return nil, nil, err
	}
	if openedInfo.Mode().Perm() != 0o600 || pathInfo.Mode().Perm() != 0o600 {
		_ = file.Close()
		return nil, nil, errors.New("read-only file mode is not 0600")
	}
	return file, openedInfo, nil
}

func secureDatabaseFile(path string) (*os.File, os.FileInfo, error) {
	for {
		info, err := os.Lstat(path)
		switch {
		case errors.Is(err, os.ErrNotExist):
			file, createErr := os.OpenFile(path, os.O_RDWR|os.O_CREATE|os.O_EXCL, 0o600)
			if errors.Is(createErr, os.ErrExist) {
				continue
			}
			if createErr != nil {
				return nil, nil, fmt.Errorf("create database: %w", createErr)
			}
			securedInfo, secureErr := secureOpenFile(path, file)
			if secureErr != nil {
				_ = file.Close()
				return nil, nil, secureErr
			}
			return file, securedInfo, nil
		case err != nil:
			return nil, nil, fmt.Errorf("inspect database: %w", err)
		case !info.Mode().IsRegular():
			return nil, nil, errors.New("database path is not a regular file")
		}

		file, err := os.Open(path)
		if err != nil {
			return nil, nil, fmt.Errorf("open database for permission check: %w", err)
		}
		securedInfo, secureErr := secureOpenFile(path, file)
		if secureErr != nil {
			_ = file.Close()
			return nil, nil, secureErr
		}
		return file, securedInfo, nil
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
	_, secureErr := secureOpenFile(path, file)
	closeErr := file.Close()
	if secureErr != nil {
		return errors.Join(secureErr, closeErr)
	}
	if closeErr != nil {
		return fmt.Errorf("close secured file: %w", closeErr)
	}
	return nil
}

func secureOpenFile(path string, file *os.File) (os.FileInfo, error) {
	openedInfo, err := file.Stat()
	if err != nil {
		return nil, fmt.Errorf("inspect opened file: %w", err)
	}
	pathInfo, err := os.Lstat(path)
	if err != nil {
		return nil, fmt.Errorf("reinspect file path: %w", err)
	}
	if !openedInfo.Mode().IsRegular() || !pathInfo.Mode().IsRegular() || !os.SameFile(openedInfo, pathInfo) {
		return nil, errors.New("file changed during permission check")
	}
	if err := requireCurrentOwner(openedInfo, "file"); err != nil {
		return nil, err
	}
	if err := requireSingleLink(openedInfo, "file"); err != nil {
		return nil, err
	}
	if err := file.Chmod(0o600); err != nil {
		return nil, fmt.Errorf("set file mode 0600: %w", err)
	}
	securedInfo, err := file.Stat()
	if err != nil {
		return nil, fmt.Errorf("reinspect secured file: %w", err)
	}
	if securedInfo.Mode().Perm() != 0o600 {
		return nil, errors.New("secured file mode is not 0600")
	}
	return securedInfo, nil
}

func (g *databaseFileGuard) Verify() error {
	currentParent, err := verifyParentPath(g.parentPath, g.parent, g.parentInfo)
	if err != nil {
		return err
	}
	currentParentOwner, currentParentOwnerOK := ownerID(currentParent)
	originalParentOwner, originalParentOwnerOK := ownerID(g.parentInfo)
	if currentParent.Mode() != g.parentInfo.Mode() || !currentParentOwnerOK || !originalParentOwnerOK || currentParentOwner != originalParentOwner {
		return errors.New("database parent mode or owner changed")
	}

	openedInfo, err := g.file.Stat()
	if err != nil {
		return fmt.Errorf("inspect held database file: %w", err)
	}
	pathInfo, err := os.Lstat(g.path)
	if err != nil || !pathInfo.Mode().IsRegular() || !os.SameFile(openedInfo, pathInfo) {
		return errors.New("database file identity changed")
	}
	if openedInfo.Mode().Perm() != 0o600 || pathInfo.Mode().Perm() != 0o600 {
		return errors.New("database file mode changed")
	}
	if err := requireCurrentOwner(openedInfo, "database file"); err != nil {
		return err
	}
	if err := requireSingleLink(openedInfo, "database file"); err != nil {
		return err
	}
	currentOwner, currentOwnerOK := ownerID(openedInfo)
	originalOwner, originalOwnerOK := ownerID(g.fileInfo)
	if !currentOwnerOK || !originalOwnerOK || currentOwner != originalOwner {
		return errors.New("database file owner changed")
	}
	return nil
}

func verifyParentPath(path string, held *os.File, original os.FileInfo) (os.FileInfo, error) {
	heldInfo, err := held.Stat()
	if err != nil {
		return nil, fmt.Errorf("inspect held database parent: %w", err)
	}
	pathInfo, err := os.Stat(path)
	if err != nil || !pathInfo.IsDir() || !os.SameFile(heldInfo, pathInfo) {
		return nil, errors.New("database parent identity changed")
	}
	// SQLite creates its WAL and SHM beside the main file, so the immediate
	// parent is the security boundary. Writable ancestors (for example /tmp)
	// remain valid when this direct parent is a private directory.
	if heldInfo.Mode().Perm()&0o022 != 0 {
		return nil, ErrInsecureDatabaseParent
	}
	if original != nil && !os.SameFile(original, heldInfo) {
		return nil, errors.New("database parent identity changed")
	}
	return heldInfo, nil
}

func requireCurrentOwner(info os.FileInfo, label string) error {
	uid, ok := ownerID(info)
	if !ok {
		return fmt.Errorf("cannot verify %s owner", label)
	}
	if uid != uint32(os.Geteuid()) {
		return fmt.Errorf("%s is not owned by the current user", label)
	}
	return nil
}

func ownerID(info os.FileInfo) (uint32, bool) {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, false
	}
	return stat.Uid, true
}

func requireSingleLink(info os.FileInfo, label string) error {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return fmt.Errorf("cannot verify %s link count", label)
	}
	if stat.Nlink != 1 {
		return fmt.Errorf("%s has multiple hard links", label)
	}
	return nil
}

func (g *databaseFileGuard) Close() error {
	var err error
	if g.file != nil {
		if closeErr := g.file.Close(); closeErr != nil {
			err = errors.Join(err, fmt.Errorf("close held database file: %w", closeErr))
		}
		g.file = nil
	}
	if g.parent != nil {
		if closeErr := g.parent.Close(); closeErr != nil {
			err = errors.Join(err, fmt.Errorf("close held database parent: %w", closeErr))
		}
		g.parent = nil
	}
	return err
}

func closeOpenResources(db *sql.DB, guard *databaseFileGuard, cause error) error {
	err := cause
	if db != nil {
		if closeErr := db.Close(); closeErr != nil {
			err = errors.Join(err, fmt.Errorf("store: close database after failure: %w", closeErr))
		}
	}
	if guard != nil {
		if closeErr := guard.Close(); closeErr != nil {
			err = errors.Join(err, fmt.Errorf("store: close database file guard: %w", closeErr))
		}
	}
	return err
}

func closeAfterError(db *sql.DB, cause error) error {
	if err := db.Close(); err != nil {
		return errors.Join(cause, fmt.Errorf("store: close database after failure: %w", err))
	}
	return cause
}
