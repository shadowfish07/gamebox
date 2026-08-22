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
	schemaVersion          = 1
	maxPayloadBytes        = 1 << 20
	maxRecordMetadataBytes = 4 << 10
	maxRecordOverheadBytes = 64 << 10
	maxRecordBytes         = maxPayloadBytes + maxRecordOverheadBytes
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

func makeRecord(sequence int64, previousHash string, draft Draft) (Record, error) {
	if err := validateDraftInput(draft); err != nil {
		return Record{}, fmt.Errorf("%w: %v", ErrInvalidDraft, err)
	}
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
	if len(encoded)+len(`,"hash":"`)+sha256.Size*2+1 > maxRecordBytes {
		return Record{}, fmt.Errorf("%w: record exceeds %d byte limit", ErrInvalidDraft, maxRecordBytes)
	}
	digest := sha256.Sum256(encoded)
	record.Hash = hex.EncodeToString(digest[:])
	return record, nil
}

func validateDraftInput(draft Draft) error {
	if len(draft.Payload) == 0 || len(draft.Payload) > maxPayloadBytes {
		return fmt.Errorf("payload exceeds %d byte limit", maxPayloadBytes)
	}
	if err := validateBoundedMetadata(draft.Type, draft.ActionID); err != nil {
		return err
	}
	if draft.Type != "room.created" {
		return nil
	}
	_, err := roomCreatedAt(draft.Payload)
	if err != nil {
		return fmt.Errorf("room.created payload: %w", err)
	}
	return nil
}

// roomCreatedAt validates the durable room-created contract against the
// original payload bytes. Callers use it before canonicalization; replay uses
// it again after strict record decoding so either path rejects the same event.
func roomCreatedAt(payload json.RawMessage) (int64, error) {
	fields, err := strictObjectFields(payload)
	if err != nil {
		return 0, err
	}
	rawCreatedAt, ok := fields["createdAt"]
	if !ok || !positiveCanonicalInteger.Match(rawCreatedAt) {
		return 0, errors.New("createdAt must be a positive canonical integer")
	}
	createdAt, err := strconv.ParseInt(string(rawCreatedAt), 10, 64)
	if err != nil || createdAt <= 0 {
		return 0, errors.New("createdAt must be a positive canonical integer")
	}
	return createdAt, nil
}

func canonicalRecord(record Record) ([]byte, error) {
	if !isCanonicalHash(record.Hash) {
		return nil, fmt.Errorf("hash is not canonical lower-case SHA-256")
	}
	encoded := newCappedJSONBuffer(maxRecordBytes)
	if err := writeCanonicalRecord(&encoded, record, true); err != nil {
		return nil, err
	}
	return encoded.Bytes(), nil
}

func canonicalRecordWithoutHash(record Record) ([]byte, error) {
	encoded := newCappedJSONBuffer(maxRecordBytes - len(`,"hash":`) - sha256.Size*2 - 2)
	if err := writeCanonicalRecord(&encoded, record, false); err != nil {
		return nil, err
	}
	return encoded.Bytes(), nil
}

func writeCanonicalRecord(encoded *cappedJSONBuffer, record Record, includeHash bool) error {
	if err := encoded.WriteString(`{"schemaVersion":`); err != nil {
		return err
	}
	if err := encoded.WriteString(strconv.Itoa(record.SchemaVersion)); err != nil {
		return err
	}
	if err := encoded.WriteString(`,"journalSequence":`); err != nil {
		return err
	}
	if err := encoded.WriteString(strconv.FormatInt(record.JournalSequence, 10)); err != nil {
		return err
	}
	if err := encoded.WriteString(`,"gameRevision":`); err != nil {
		return err
	}
	if record.GameRevision == nil {
		if err := encoded.WriteString("null"); err != nil {
			return err
		}
	} else if err := encoded.WriteString(strconv.FormatInt(*record.GameRevision, 10)); err != nil {
		return err
	}
	if err := encoded.WriteString(`,"type":`); err != nil {
		return err
	}
	if err := writeJSONString(encoded, record.Type); err != nil {
		return err
	}
	if err := encoded.WriteString(`,"actionId":`); err != nil {
		return err
	}
	if record.ActionID == nil {
		if err := encoded.WriteString("null"); err != nil {
			return err
		}
	} else if err := writeJSONString(encoded, *record.ActionID); err != nil {
		return err
	}
	if err := encoded.WriteString(`,"payload":`); err != nil {
		return err
	}
	if err := encoded.Write(record.Payload); err != nil {
		return err
	}
	if err := encoded.WriteString(`,"previousHash":`); err != nil {
		return err
	}
	if err := writeJSONString(encoded, record.PreviousHash); err != nil {
		return err
	}
	if includeHash {
		if err := encoded.WriteString(`,"hash":`); err != nil {
			return err
		}
		if err := writeJSONString(encoded, record.Hash); err != nil {
			return err
		}
	}
	return encoded.WriteByte('}')
}

func canonicalPayload(raw json.RawMessage) (json.RawMessage, error) {
	if len(raw) == 0 || len(raw) > maxPayloadBytes {
		return nil, fmt.Errorf("exceeds %d byte limit", maxPayloadBytes)
	}
	if !utf8.Valid(raw) {
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
	return json.RawMessage(canonical), nil
}

// encodeCanonicalJSON uses one decimal spelling for every JSON number: no
// exponent, no leading plus/zeroes, no fractional trailing zeroes, and zero is
// always "0". This keeps numerically equal payloads on one hash-chain byte form.
func encodeCanonicalJSON(value any) ([]byte, error) {
	encoded := newCappedJSONBuffer(maxPayloadBytes)
	if err := writeCanonicalJSON(&encoded, value); err != nil {
		return nil, err
	}
	return encoded.Bytes(), nil
}

func writeCanonicalJSON(encoded *cappedJSONBuffer, value any) error {
	switch value := value.(type) {
	case nil:
		return encoded.WriteString("null")
	case bool:
		if value {
			return encoded.WriteString("true")
		}
		return encoded.WriteString("false")
	case string:
		return writeJSONString(encoded, value)
	case json.Number:
		number, err := canonicalNumber(string(value))
		if err != nil {
			return err
		}
		return encoded.Write(number)
	case []any:
		if err := encoded.WriteByte('['); err != nil {
			return err
		}
		for index, item := range value {
			if index > 0 {
				if err := encoded.WriteByte(','); err != nil {
					return err
				}
			}
			if err := writeCanonicalJSON(encoded, item); err != nil {
				return err
			}
		}
		return encoded.WriteByte(']')
	case map[string]any:
		keys := make([]string, 0, len(value))
		for key := range value {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		if err := encoded.WriteByte('{'); err != nil {
			return err
		}
		for index, key := range keys {
			if index > 0 {
				if err := encoded.WriteByte(','); err != nil {
					return err
				}
			}
			if err := writeJSONString(encoded, key); err != nil {
				return err
			}
			if err := encoded.WriteByte(':'); err != nil {
				return err
			}
			if err := writeCanonicalJSON(encoded, value[key]); err != nil {
				return err
			}
		}
		return encoded.WriteByte('}')
	default:
		return fmt.Errorf("unsupported decoded JSON type %T", value)
	}
}

// writeJSONString uses the journal's canonical escaping: short escapes for
// backspace/tab/newline/form-feed/carriage-return, lower-case \u00xx for the
// remaining controls, and lower-case escapes for HTML-sensitive and line
// separator runes. Other valid UTF-8 bytes are emitted verbatim.
func writeJSONString(encoded *cappedJSONBuffer, value string) error {
	if !utf8.ValidString(value) {
		return errors.New("JSON string is not UTF-8")
	}
	if err := encoded.WriteByte('"'); err != nil {
		return err
	}
	start := 0
	flush := func(end int) error {
		if start == end {
			return nil
		}
		if err := encoded.WriteString(value[start:end]); err != nil {
			return err
		}
		start = end
		return nil
	}
	for index := 0; index < len(value); {
		current := value[index]
		var escape string
		width := 1
		switch current {
		case '"':
			escape = `\"`
		case '\\':
			escape = `\\`
		case '\b':
			escape = `\b`
		case '\t':
			escape = `\t`
		case '\n':
			escape = `\n`
		case '\f':
			escape = `\f`
		case '\r':
			escape = `\r`
		case '<':
			escape = `\u003c`
		case '>':
			escape = `\u003e`
		case '&':
			escape = `\u0026`
		default:
			if current < 0x20 {
				escape = fmt.Sprintf(`\u00%02x`, current)
			} else if index+2 < len(value) && current == 0xe2 && value[index+1] == 0x80 && (value[index+2] == 0xa8 || value[index+2] == 0xa9) {
				if value[index+2] == 0xa8 {
					escape = `\u2028`
				} else {
					escape = `\u2029`
				}
				width = 3
			}
		}
		if escape == "" {
			index++
			continue
		}
		if err := flush(index); err != nil {
			return err
		}
		if err := encoded.WriteString(escape); err != nil {
			return err
		}
		index += width
		start = index
	}
	if err := flush(len(value)); err != nil {
		return err
	}
	return encoded.WriteByte('"')
}

type cappedJSONBuffer struct {
	bytes.Buffer
	limit int
}

func newCappedJSONBuffer(limit int) cappedJSONBuffer {
	return cappedJSONBuffer{limit: limit}
}

func (buffer *cappedJSONBuffer) Write(data []byte) error {
	if len(data) > buffer.limit-buffer.Len() {
		return fmt.Errorf("exceeds %d byte limit", buffer.limit)
	}
	_, err := buffer.Buffer.Write(data)
	return err
}

func (buffer *cappedJSONBuffer) WriteString(value string) error {
	if len(value) > buffer.limit-buffer.Len() {
		return fmt.Errorf("exceeds %d byte limit", buffer.limit)
	}
	_, err := buffer.Buffer.WriteString(value)
	return err
}

func (buffer *cappedJSONBuffer) WriteByte(value byte) error {
	if buffer.Len() == buffer.limit {
		return fmt.Errorf("exceeds %d byte limit", buffer.limit)
	}
	return buffer.Buffer.WriteByte(value)
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
	if err := validateBoundedMetadata(record.Type, record.ActionID); err != nil {
		return err
	}
	if strings.TrimSpace(record.Type) == "" {
		return errors.New("type is required")
	}
	if record.Type == "game.event" {
		if record.GameRevision == nil || *record.GameRevision <= 0 {
			return errors.New("game event requires a positive game revision")
		}
	} else if record.GameRevision != nil {
		return errors.New("only game events may contain game revision")
	}
	if record.Type == "room.created" {
		if _, err := roomCreatedAt(record.Payload); err != nil {
			return fmt.Errorf("room.created payload: %w", err)
		}
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

func validateBoundedMetadata(recordType string, actionID *string) error {
	if !utf8.ValidString(recordType) {
		return errors.New("type is not UTF-8")
	}
	if len(recordType) > maxRecordMetadataBytes {
		return fmt.Errorf("type exceeds %d byte limit", maxRecordMetadataBytes)
	}
	if actionID != nil {
		if !utf8.ValidString(*actionID) {
			return errors.New("action ID is not UTF-8")
		}
		if len(*actionID) > maxRecordMetadataBytes {
			return fmt.Errorf("action ID exceeds %d byte limit", maxRecordMetadataBytes)
		}
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
