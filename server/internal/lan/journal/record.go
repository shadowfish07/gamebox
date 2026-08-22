// Package journal persists the authoritative, append-only history of one LAN room.
package journal

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"unicode/utf8"
)

const (
	schemaVersion   = 1
	maxPayloadBytes = 1 << 20
)

var (
	ErrInvalidRecord = errors.New("invalid journal record")
	ErrInvalidDraft  = errors.New("invalid journal draft")
)

// Record is the durable, hash-chained representation of a room event.
type Record struct {
	SchemaVersion   int             `json:"schemaVersion"`
	JournalSequence int64           `json:"journalSequence"`
	GameRevision    *int64          `json:"gameRevision"`
	Type            string          `json:"type"`
	ActionID        *string         `json:"actionId"`
	Payload         json.RawMessage `json:"payload"`
	PreviousHash    string          `json:"previousHash"`
	Hash            string          `json:"hash"`
}

// Draft contains only fields supplied by the room state machine. Store assigns
// sequence and chain fields when it durably accepts the draft.
type Draft struct {
	GameRevision *int64
	Type         string
	ActionID     *string
	Payload      json.RawMessage
}

type recordWithoutHash struct {
	SchemaVersion   int             `json:"schemaVersion"`
	JournalSequence int64           `json:"journalSequence"`
	GameRevision    *int64          `json:"gameRevision"`
	Type            string          `json:"type"`
	ActionID        *string         `json:"actionId"`
	Payload         json.RawMessage `json:"payload"`
	PreviousHash    string          `json:"previousHash"`
}

func makeRecord(sequence int64, previousHash string, draft Draft) (Record, error) {
	payload, err := canonicalPayload(draft.Payload)
	if err != nil {
		return Record{}, fmt.Errorf("%w: payload: %v", ErrInvalidDraft, err)
	}
	record := Record{
		SchemaVersion:   schemaVersion,
		JournalSequence: sequence,
		GameRevision:    cloneInt64(draft.GameRevision),
		Type:            draft.Type,
		ActionID:        cloneString(draft.ActionID),
		Payload:         payload,
		PreviousHash:    previousHash,
	}
	if err := validateRecordFields(record); err != nil {
		return Record{}, fmt.Errorf("%w: %v", ErrInvalidDraft, err)
	}
	encoded, err := canonicalRecordWithoutHash(record)
	if err != nil {
		return Record{}, fmt.Errorf("%w: encode: %v", ErrInvalidDraft, err)
	}
	digest := sha256.Sum256(encoded)
	record.Hash = hex.EncodeToString(digest[:])
	return record, nil
}

func canonicalRecord(record Record) ([]byte, error) {
	withoutHash, err := canonicalRecordWithoutHash(record)
	if err != nil {
		return nil, err
	}
	if !isCanonicalHash(record.Hash) {
		return nil, fmt.Errorf("hash is not canonical lower-case SHA-256")
	}
	return append(append(withoutHash[:len(withoutHash)-1:len(withoutHash)-1], `,"hash":"`...), append([]byte(record.Hash), `"}`...)...), nil
}

func canonicalRecordWithoutHash(record Record) ([]byte, error) {
	return json.Marshal(recordWithoutHash{
		SchemaVersion:   record.SchemaVersion,
		JournalSequence: record.JournalSequence,
		GameRevision:    record.GameRevision,
		Type:            record.Type,
		ActionID:        record.ActionID,
		Payload:         record.Payload,
		PreviousHash:    record.PreviousHash,
	})
}

func canonicalPayload(raw json.RawMessage) (json.RawMessage, error) {
	if len(raw) == 0 || !utf8.Valid(raw) {
		return nil, errors.New("must be one UTF-8 JSON value")
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var value any
	if err := decoder.Decode(&value); err != nil {
		return nil, err
	}
	if err := requireEOF(decoder); err != nil {
		return nil, errors.New("contains a trailing JSON document")
	}
	canonical, err := json.Marshal(value)
	if err != nil {
		return nil, err
	}
	if len(canonical) > maxPayloadBytes {
		return nil, fmt.Errorf("exceeds %d byte limit", maxPayloadBytes)
	}
	return json.RawMessage(canonical), nil
}

func decodeRecord(data []byte) (Record, error) {
	fields, err := strictObjectFields(data)
	if err != nil {
		return Record{}, fmt.Errorf("%w: %v", ErrInvalidRecord, err)
	}
	required := map[string]struct{}{
		"schemaVersion": {}, "journalSequence": {}, "gameRevision": {}, "type": {},
		"actionId": {}, "payload": {}, "previousHash": {}, "hash": {},
	}
	if len(fields) != len(required) {
		return Record{}, fmt.Errorf("%w: expected exactly eight fields", ErrInvalidRecord)
	}
	for name := range fields {
		if _, ok := required[name]; !ok {
			return Record{}, fmt.Errorf("%w: unknown field %q", ErrInvalidRecord, name)
		}
	}
	var record Record
	if err := json.Unmarshal(data, &record); err != nil {
		return Record{}, fmt.Errorf("%w: %v", ErrInvalidRecord, err)
	}
	payload, err := canonicalPayload(record.Payload)
	if err != nil {
		return Record{}, fmt.Errorf("%w: payload: %v", ErrInvalidRecord, err)
	}
	if !bytes.Equal(payload, record.Payload) {
		return Record{}, fmt.Errorf("%w: payload is not canonical", ErrInvalidRecord)
	}
	if err := validateRecordFields(record); err != nil {
		return Record{}, fmt.Errorf("%w: %v", ErrInvalidRecord, err)
	}
	canonical, err := canonicalRecord(record)
	if err != nil {
		return Record{}, fmt.Errorf("%w: %v", ErrInvalidRecord, err)
	}
	if !bytes.Equal(data, canonical) {
		return Record{}, fmt.Errorf("%w: record JSON is not canonical", ErrInvalidRecord)
	}
	withoutHash, err := canonicalRecordWithoutHash(record)
	if err != nil {
		return Record{}, fmt.Errorf("%w: %v", ErrInvalidRecord, err)
	}
	digest := sha256.Sum256(withoutHash)
	if record.Hash != hex.EncodeToString(digest[:]) {
		return Record{}, fmt.Errorf("%w: current hash does not verify", ErrInvalidRecord)
	}
	return cloneRecord(record), nil
}

func validateRecordFields(record Record) error {
	if record.SchemaVersion != schemaVersion {
		return fmt.Errorf("schema version = %d, want %d", record.SchemaVersion, schemaVersion)
	}
	if record.JournalSequence <= 0 {
		return errors.New("journal sequence must be positive")
	}
	if !utf8.ValidString(record.Type) || strings.TrimSpace(record.Type) == "" {
		return errors.New("type is required")
	}
	if record.ActionID != nil && !utf8.ValidString(*record.ActionID) {
		return errors.New("action ID is not UTF-8")
	}
	if record.Type == "game.event" {
		if record.GameRevision == nil || *record.GameRevision <= 0 {
			return errors.New("game event requires a positive game revision")
		}
	} else if record.GameRevision != nil {
		return errors.New("only game events may contain game revision")
	}
	if record.JournalSequence == 1 {
		if record.PreviousHash != "" {
			return errors.New("first record must have an empty previous hash")
		}
	} else if !isCanonicalHash(record.PreviousHash) {
		return errors.New("previous hash is not canonical lower-case SHA-256")
	}
	return nil
}

func strictObjectFields(data []byte) (map[string]json.RawMessage, error) {
	if !utf8.Valid(data) {
		return nil, errors.New("record is not UTF-8")
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	token, err := decoder.Token()
	if err != nil {
		return nil, err
	}
	if delimiter, ok := token.(json.Delim); !ok || delimiter != '{' {
		return nil, errors.New("record must be a JSON object")
	}
	fields := make(map[string]json.RawMessage)
	for decoder.More() {
		token, err := decoder.Token()
		if err != nil {
			return nil, err
		}
		name, ok := token.(string)
		if !ok {
			return nil, errors.New("object field is not a string")
		}
		if _, exists := fields[name]; exists {
			return nil, fmt.Errorf("duplicate field %q", name)
		}
		var value json.RawMessage
		if err := decoder.Decode(&value); err != nil {
			return nil, err
		}
		fields[name] = value
	}
	if _, err := decoder.Token(); err != nil {
		return nil, err
	}
	if err := requireEOF(decoder); err != nil {
		return nil, errors.New("contains a trailing JSON document")
	}
	return fields, nil
}

func requireEOF(decoder *json.Decoder) error {
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		if err == nil {
			return errors.New("extra JSON value")
		}
		return err
	}
	return nil
}

func isCanonicalHash(value string) bool {
	if len(value) != sha256.Size*2 {
		return false
	}
	for _, char := range value {
		if !((char >= '0' && char <= '9') || (char >= 'a' && char <= 'f')) {
			return false
		}
	}
	return true
}

func cloneRecord(record Record) Record {
	record.GameRevision = cloneInt64(record.GameRevision)
	record.ActionID = cloneString(record.ActionID)
	record.Payload = append(json.RawMessage(nil), record.Payload...)
	return record
}

func cloneInt64(value *int64) *int64 {
	if value == nil {
		return nil
	}
	clone := *value
	return &clone
}

func cloneString(value *string) *string {
	if value == nil {
		return nil
	}
	clone := *value
	return &clone
}
