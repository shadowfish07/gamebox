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

// Store is safe for concurrent use. A directory-sync failure poisons it because
// the rename may already have made a record visible after the caller saw error.
type Store struct {
	mu       sync.RWMutex
	root     string
	ops      FileOps
	records  []Record
	poisoned bool
}

// Open removes only uncommitted journal and manifest temporary files, then
// replays the complete contiguous verified chain. The manifest is intentionally
// ignored: callers must rebuild their state from the returned records.
func Open(root string, ops FileOps) (*Store, []Record, error) {
	if root == "" {
		return nil, nil, errors.New("journal root is required")
	}
	if err := os.MkdirAll(root, 0o700); err != nil {
		return nil, nil, fmt.Errorf("create journal root: %w", err)
	}
	if ops == nil {
		ops = osFileOps{}
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		return nil, nil, fmt.Errorf("read journal root: %w", err)
	}
	fileNames := make([]string, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
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
			if !recordFileName.MatchString(name) {
				return nil, nil, fmt.Errorf("invalid committed journal filename %q", name)
			}
			fileNames = append(fileNames, name)
		}
	}
	sort.Strings(fileNames)
	records := make([]Record, 0, len(fileNames))
	for index, name := range fileNames {
		expectedSequence := int64(index + 1)
		fileSequence, _ := strconv.ParseInt(name[:16], 10, 64)
		if fileSequence != expectedSequence {
			return nil, nil, fmt.Errorf("journal sequence gap or reorder at %q: got %d, want %d", name, fileSequence, expectedSequence)
		}
		data, err := os.ReadFile(filepath.Join(root, name))
		if err != nil {
			return nil, nil, fmt.Errorf("read record %q: %w", name, err)
		}
		record, err := decodeRecord(data)
		if err != nil {
			return nil, nil, fmt.Errorf("decode record %q: %w", name, err)
		}
		if record.JournalSequence != expectedSequence {
			return nil, nil, fmt.Errorf("record %q sequence = %d, want %d", name, record.JournalSequence, expectedSequence)
		}
		if expectedSequence > 1 && record.PreviousHash != records[len(records)-1].Hash {
			return nil, nil, fmt.Errorf("record %q previous hash does not chain", name)
		}
		records = append(records, record)
	}
	store := &Store{root: root, ops: ops, records: records}
	return store, cloneRecords(records), nil
}

// Append assigns the next sequence and commits it using write+file-sync, atomic
// rename, then directory sync. It exposes the record only after all boundaries
// succeed. A post-rename directory-sync failure requires Open before retrying.
func (store *Store) Append(ctx context.Context, draft Draft) (Record, error) {
	if err := ctx.Err(); err != nil {
		return Record{}, err
	}
	store.mu.Lock()
	defer store.mu.Unlock()
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

// WriteManifestProjection atomically persists non-authoritative room location
// data. It always reflects the last verified journal sequence; callers replay
// records from Open instead of trusting this projection during recovery.
func (store *Store) WriteManifestProjection(roomID, gameID, endpoint string, formatVersion int) error {
	store.mu.Lock()
	defer store.mu.Unlock()
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
		var payload map[string]json.RawMessage
		if err := json.Unmarshal(record.Payload, &payload); err != nil {
			return 0, fmt.Errorf("room.created payload: %w", err)
		}
		rawCreatedAt, ok := payload["createdAt"]
		if !ok {
			return 0, errors.New("room.created payload has no createdAt")
		}
		if !positiveCanonicalInteger.Match(rawCreatedAt) {
			return 0, errors.New("room.created payload createdAt must be a positive canonical integer")
		}
		createdAt, err := strconv.ParseInt(string(rawCreatedAt), 10, 64)
		if err != nil || createdAt <= 0 {
			return 0, errors.New("room.created payload createdAt must be a positive canonical integer")
		}
		return createdAt, nil
	}
	return 0, errors.New("journal has no room.created record")
}

func recordFilename(sequence int64) string { return fmt.Sprintf("%016d.json", sequence) }

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
