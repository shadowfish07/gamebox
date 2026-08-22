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
	"sort"
	"strconv"
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
	canonical, err := encodeCanonicalJSON(value)
	if err != nil {
		return nil, err
	}
	if len(canonical) > maxPayloadBytes {
		return nil, fmt.Errorf("exceeds %d byte limit", maxPayloadBytes)
	}
	return json.RawMessage(canonical), nil
}

// encodeCanonicalJSON uses one decimal spelling for every JSON number: no
// exponent, no leading plus/zeroes, no fractional trailing zeroes, and zero is
// always "0". This keeps numerically equal payloads on one hash-chain byte form.
func encodeCanonicalJSON(value any) ([]byte, error) {
	switch value := value.(type) {
	case nil:
		return []byte("null"), nil
	case bool:
		if value {
			return []byte("true"), nil
		}
		return []byte("false"), nil
	case string:
		return json.Marshal(value)
	case json.Number:
		return canonicalNumber(string(value))
	case []any:
		var encoded bytes.Buffer
		encoded.WriteByte('[')
		for index, item := range value {
			if index > 0 {
				encoded.WriteByte(',')
			}
			child, err := encodeCanonicalJSON(item)
			if err != nil {
				return nil, err
			}
			encoded.Write(child)
		}
		encoded.WriteByte(']')
		return encoded.Bytes(), nil
	case map[string]any:
		keys := make([]string, 0, len(value))
		for key := range value {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		var encoded bytes.Buffer
		encoded.WriteByte('{')
		for index, key := range keys {
			if index > 0 {
				encoded.WriteByte(',')
			}
			encodedKey, err := json.Marshal(key)
			if err != nil {
				return nil, err
			}
			encoded.Write(encodedKey)
			encoded.WriteByte(':')
			child, err := encodeCanonicalJSON(value[key])
			if err != nil {
				return nil, err
			}
			encoded.Write(child)
		}
		encoded.WriteByte('}')
		return encoded.Bytes(), nil
	default:
		return nil, fmt.Errorf("unsupported decoded JSON type %T", value)
	}
}

func canonicalNumber(raw string) ([]byte, error) {
	negative := strings.HasPrefix(raw, "-")
	if negative {
		raw = raw[1:]
	}
	mantissa, exponentText, hasExponent := strings.Cut(raw, "e")
	if !hasExponent {
		mantissa, exponentText, hasExponent = strings.Cut(raw, "E")
	}
	exponent := int64(0)
	if hasExponent {
		var err error
		exponent, err = strconv.ParseInt(exponentText, 10, 64)
		if err != nil {
			return nil, fmt.Errorf("invalid numeric exponent")
		}
	}
	integerPart, fractionalPart, hasFraction := strings.Cut(mantissa, ".")
	if integerPart == "" || (hasFraction && fractionalPart == "") || !decimalDigits(integerPart) || (hasFraction && !decimalDigits(fractionalPart)) {
		return nil, fmt.Errorf("invalid JSON number")
	}
	digits := strings.TrimLeft(integerPart+fractionalPart, "0")
	if digits == "" {
		return []byte("0"), nil
	}
	if exponent > int64(maxPayloadBytes) || exponent < -int64(maxPayloadBytes) {
		return nil, fmt.Errorf("numeric exponent is too large")
	}
	scale := exponent - int64(len(fractionalPart))
	for strings.HasSuffix(digits, "0") {
		digits = digits[:len(digits)-1]
		if scale == int64(^uint64(0)>>1) {
			return nil, fmt.Errorf("numeric exponent is too large")
		}
		scale++
	}

	negativeLength := int64(0)
	if negative {
		negativeLength = 1
	}
	var length int64
	if scale >= 0 {
		if scale > int64(maxPayloadBytes) {
			return nil, fmt.Errorf("number exceeds %d byte limit", maxPayloadBytes)
		}
		length = negativeLength + int64(len(digits)) + scale
	} else {
		point := int64(len(digits)) + scale
		if point > 0 {
			length = negativeLength + int64(len(digits)) + 1
		} else {
			length = negativeLength + 2 + -point + int64(len(digits))
		}
	}
	if length > maxPayloadBytes {
		return nil, fmt.Errorf("number exceeds %d byte limit", maxPayloadBytes)
	}
	var encoded strings.Builder
	encoded.Grow(int(length))
	if negative {
		encoded.WriteByte('-')
	}
	if scale >= 0 {
		encoded.WriteString(digits)
		for range scale {
			encoded.WriteByte('0')
		}
		return []byte(encoded.String()), nil
	}
	point := int64(len(digits)) + scale
	if point > 0 {
		encoded.WriteString(digits[:point])
		encoded.WriteByte('.')
		encoded.WriteString(digits[point:])
		return []byte(encoded.String()), nil
	}
	encoded.WriteString("0.")
	for range -point {
		encoded.WriteByte('0')
	}
	encoded.WriteString(digits)
	return []byte(encoded.String()), nil
}

func decimalDigits(value string) bool {
	for _, character := range value {
		if character < '0' || character > '9' {
			return false
		}
	}
	return true
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
