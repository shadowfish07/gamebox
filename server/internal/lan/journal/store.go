package journal

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"sync"
)

var (
	ErrReopenRequired        = errors.New("journal must be reopened and replayed")
	ErrJournalLocked         = errors.New("journal root is already locked")
	ErrJournalClosed         = errors.New("journal store is closed")
	ErrJournalSequenceGap    = errors.New("journal sequence gap")
	ErrJournalCorrupt        = errors.New("journal content is corrupt")
	recordFileName           = regexp.MustCompile(`^[0-9]{16}\.json$`)
	temporaryFileName        = regexp.MustCompile(`^[0-9]{16}\.json\.tmp$`)
	positiveCanonicalInteger = regexp.MustCompile(`^[1-9][0-9]*$`)
)

// FileOps isolates the fallible durable-write boundaries for deterministic tests.
type FileOps interface {
	WriteFileSync(path string, data []byte, mode fs.FileMode) error
	Rename(oldPath, newPath string) error
	SyncDir(path string) error
}

type committedRecordReader func(root, name string, limit int) ([]byte, error)

// Store is safe for concurrent use. A directory-sync failure poisons it because
// the rename may already have made a record visible after the caller saw error.
type Store struct {
	mu          sync.RWMutex
	root        string
	ops         FileOps
	records     []Record
	poisoned    bool
	closed      bool
	lockFile    *os.File
	releaseLock func(*os.File) error
}

// Open acquires the lifetime root lock before removing only uncommitted journal
// and manifest temporary files, then replays the complete contiguous verified
// chain. The manifest is intentionally ignored: callers must rebuild their
// state from the returned records.
func Open(root string, ops FileOps) (*Store, []Record, error) {
	return openWithCommittedRecordReader(root, ops, readCommittedRecord)
}

func openWithCommittedRecordReader(root string, ops FileOps, readRecord committedRecordReader) (*Store, []Record, error) {
	if root == "" {
		return nil, nil, errors.New("journal root is required")
	}
	if readRecord == nil {
		return nil, nil, errors.New("committed record reader is required")
	}
	if err := os.MkdirAll(root, 0o700); err != nil {
		return nil, nil, fmt.Errorf("create journal root: %w", err)
	}
	lockFile, err := acquireJournalRootLock(root)
	if err != nil {
		return nil, nil, err
	}
	opened := false
	defer func() {
		if !opened {
			_ = releaseJournalRootLock(lockFile)
		}
	}()
	if ops == nil {
		ops = osFileOps{}
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		return nil, nil, fmt.Errorf("read journal root: %w", err)
	}
	fileNames := make([]string, 0, len(entries))
	for _, entry := range entries {
		name := entry.Name()
		if recordFileName.MatchString(name) {
			fileNames = append(fileNames, name)
			continue
		}
		if entry.IsDir() {
			continue
		}
		if name == "manifest.json.tmp" || temporaryFileName.MatchString(name) {
			if err := os.Remove(filepath.Join(root, name)); err != nil {
				return nil, nil, fmt.Errorf("remove uncommitted temp %q: %w", name, err)
			}
			continue
		}
		if name == "manifest.json" {
			continue
		}
		if filepath.Ext(name) == ".json" {
			return nil, nil, fmt.Errorf("%w: invalid committed journal filename %q", ErrJournalCorrupt, name)
		}
	}
	sort.Strings(fileNames)
	records := make([]Record, 0, len(fileNames))
	for index, name := range fileNames {
		expectedSequence := int64(index + 1)
		fileSequence, _ := strconv.ParseInt(name[:16], 10, 64)
		if fileSequence != expectedSequence {
			return nil, nil, fmt.Errorf("%w: %w or reorder at %q: got %d, want %d", ErrJournalCorrupt, ErrJournalSequenceGap, name, fileSequence, expectedSequence)
		}
		data, err := readRecord(root, name, maxRecordBytes)
		if err != nil {
			return nil, nil, fmt.Errorf("read record %q: %w", name, err)
		}
		record, err := decodeRecord(data)
		if err != nil {
			return nil, nil, fmt.Errorf("%w: decode record %q: %w", ErrJournalCorrupt, name, err)
		}
		if record.JournalSequence != expectedSequence {
			return nil, nil, fmt.Errorf("%w: record %q sequence = %d, want %d", ErrJournalCorrupt, name, record.JournalSequence, expectedSequence)
		}
		if expectedSequence > 1 && record.PreviousHash != records[len(records)-1].Hash {
			return nil, nil, fmt.Errorf("%w: record %q previous hash does not chain", ErrJournalCorrupt, name)
		}
		records = append(records, record)
	}
	store := &Store{root: root, ops: ops, records: records, lockFile: lockFile, releaseLock: releaseJournalRootLock}
	opened = true
	return store, cloneRecords(records), nil
}

// Append assigns the next sequence and commits it using write+file-sync, atomic
// rename, then directory sync. It exposes the record only after all boundaries
// succeed. A post-rename directory-sync failure requires Open before retrying.
func (store *Store) Append(ctx context.Context, draft Draft) (Record, error) {
	store.mu.Lock()
	defer store.mu.Unlock()
	if store.closed {
		return Record{}, ErrJournalClosed
	}
	if store.poisoned {
		return Record{}, ErrReopenRequired
	}
	if err := ctx.Err(); err != nil {
		return Record{}, err
	}
	sequence := int64(len(store.records) + 1)
	previousHash := ""
	if sequence > 1 {
		previousHash = store.records[len(store.records)-1].Hash
	}
	record, err := makeRecord(sequence, previousHash, draft)
	if err != nil {
		return Record{}, err
	}
	data, err := canonicalRecord(record)
	if err != nil {
		return Record{}, fmt.Errorf("encode record: %w", err)
	}
	if len(data) > maxRecordBytes {
		return Record{}, fmt.Errorf("encode record: exceeds %d byte limit", maxRecordBytes)
	}
	finalPath := filepath.Join(store.root, recordFilename(sequence))
	temporaryPath := finalPath + ".tmp"
	if err := store.ops.WriteFileSync(temporaryPath, data, 0o600); err != nil {
		_ = os.Remove(temporaryPath)
		return Record{}, fmt.Errorf("write and sync temporary record: %w", err)
	}
	if err := ctx.Err(); err != nil {
		_ = os.Remove(temporaryPath)
		return Record{}, err
	}
	if err := store.ops.Rename(temporaryPath, finalPath); err != nil {
		_ = os.Remove(temporaryPath)
		return Record{}, fmt.Errorf("rename committed record: %w", err)
	}
	if err := store.ops.SyncDir(store.root); err != nil {
		store.poisoned = true
		return Record{}, fmt.Errorf("sync journal directory: %w", err)
	}
	store.records = append(store.records, record)
	return cloneRecord(record), nil
}

// Records returns an independent snapshot of the durable, acknowledged chain.
func (store *Store) Records() []Record {
	store.mu.RLock()
	defer store.mu.RUnlock()
	return cloneRecords(store.records)
}

// Close releases the lifetime advisory root lock. It is safe to call more than
// once; once closed, the store remains readable but refuses further mutations.
func (store *Store) Close() error {
	store.mu.Lock()
	defer store.mu.Unlock()
	if store.closed {
		return nil
	}
	lockFile := store.lockFile
	if lockFile == nil {
		store.closed = true
		return nil
	}
	releaseLock := store.releaseLock
	if releaseLock == nil {
		releaseLock = releaseJournalRootLock
	}
	if err := releaseLock(lockFile); err != nil {
		return err
	}
	store.lockFile = nil
	store.closed = true
	return nil
}

// WriteManifestProjection atomically persists non-authoritative room location
// data. It always reflects the last verified journal sequence; callers replay
// records from Open instead of trusting this projection during recovery.
func (store *Store) WriteManifestProjection(roomID, gameID, endpoint string, formatVersion int) error {
	store.mu.Lock()
	defer store.mu.Unlock()
	if store.closed {
		return ErrJournalClosed
	}
	if store.poisoned {
		return ErrReopenRequired
	}
	if roomID == "" || gameID == "" || endpoint == "" || formatVersion <= 0 {
		return errors.New("manifest room ID, game ID, endpoint, and format version are required")
	}
	createdAt, err := createdAtFromRecords(store.records)
	if err != nil {
		return err
	}
	manifest := manifestProjection{
		SchemaVersion:        schemaVersion,
		RoomID:               roomID,
		GameID:               gameID,
		CreatedAt:            createdAt,
		Endpoint:             endpoint,
		JournalFormatVersion: formatVersion,
		JournalSequence:      int64(len(store.records)),
	}
	data, err := json.Marshal(manifest)
	if err != nil {
		return fmt.Errorf("encode manifest: %w", err)
	}
	temporaryPath := filepath.Join(store.root, "manifest.json.tmp")
	finalPath := filepath.Join(store.root, "manifest.json")
	if err := store.ops.WriteFileSync(temporaryPath, data, 0o600); err != nil {
		_ = os.Remove(temporaryPath)
		return fmt.Errorf("write and sync temporary manifest: %w", err)
	}
	if err := store.ops.Rename(temporaryPath, finalPath); err != nil {
		_ = os.Remove(temporaryPath)
		return fmt.Errorf("rename manifest: %w", err)
	}
	if err := store.ops.SyncDir(store.root); err != nil {
		store.poisoned = true
		return fmt.Errorf("sync manifest directory: %w", err)
	}
	return nil
}

type manifestProjection struct {
	SchemaVersion        int    `json:"schemaVersion"`
	RoomID               string `json:"roomId"`
	GameID               string `json:"gameId"`
	CreatedAt            int64  `json:"createdAt"`
	Endpoint             string `json:"endpoint"`
	JournalFormatVersion int    `json:"journalFormatVersion"`
	JournalSequence      int64  `json:"journalSequence"`
}

func createdAtFromRecords(records []Record) (int64, error) {
	for _, record := range records {
		if record.Type != "room.created" {
			continue
		}
		createdAt, err := roomCreatedAt(record.Payload)
		if err != nil {
			return 0, fmt.Errorf("room.created payload: %w", err)
		}
		return createdAt, nil
	}
	return 0, errors.New("journal has no room.created record")
}

func recordFilename(sequence int64) string { return fmt.Sprintf("%016d.json", sequence) }

func readFileBounded(path string, limit int) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	return readOpenedFileBounded(file, limit)
}

func readOpenedFileBounded(file io.Reader, limit int) ([]byte, error) {
	data, err := io.ReadAll(io.LimitReader(file, int64(limit)+1))
	if err != nil {
		return data, err
	}
	if len(data) > limit {
		return data, fmt.Errorf("%w: exceeds %d byte limit", ErrJournalCorrupt, limit)
	}
	return data, nil
}

func cloneRecords(records []Record) []Record {
	clones := make([]Record, len(records))
	for index, record := range records {
		clones[index] = cloneRecord(record)
	}
	return clones
}

type osFileOps struct{}

func (osFileOps) WriteFileSync(path string, data []byte, mode fs.FileMode) (returnErr error) {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, mode)
	if err != nil {
		return err
	}
	defer func() {
		if closeErr := file.Close(); returnErr == nil && closeErr != nil {
			returnErr = closeErr
		}
	}()
	for written := 0; written < len(data); {
		count, err := file.Write(data[written:])
		if err != nil {
			return err
		}
		if count == 0 {
			return io.ErrShortWrite
		}
		written += count
	}
	return file.Sync()
}

func (osFileOps) Rename(oldPath, newPath string) error { return os.Rename(oldPath, newPath) }

func (osFileOps) SyncDir(path string) error {
	directory, err := os.Open(path)
	if err != nil {
		return err
	}
	defer directory.Close()
	return directory.Sync()
}
