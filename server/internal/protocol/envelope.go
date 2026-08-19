package protocol

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"math/big"
	"strconv"
)

const Version1 = 1
const maxSafeJSONInteger int64 = 9_007_199_254_740_991

var allowedEnvelopeFields = map[string]struct{}{
	"protocolVersion":  {},
	"gameId":           {},
	"matchId":          {},
	"revision":         {},
	"expectedRevision": {},
	"type":             {},
	"actionId":         {},
	"payload":          {},
}

type Envelope struct {
	ProtocolVersion  int             `json:"protocolVersion"`
	GameID           string          `json:"gameId,omitempty"`
	MatchID          string          `json:"matchId,omitempty"`
	Revision         *int64          `json:"revision,omitempty"`
	ExpectedRevision *int64          `json:"expectedRevision,omitempty"`
	Type             string          `json:"type"`
	ActionID         string          `json:"actionId,omitempty"`
	Payload          json.RawMessage `json:"payload"`
}

func Decode(data []byte) (Envelope, error) {
	fields, err := inspectEnvelopeJSON(data)
	if err != nil {
		return Envelope{}, err
	}

	var envelope Envelope
	if err := json.Unmarshal(data, &envelope); err != nil {
		return Envelope{}, fmt.Errorf("decode envelope: %w", err)
	}
	if err := validateEnvelopePresence(envelope, fields); err != nil {
		return Envelope{}, err
	}
	if err := envelope.Validate(); err != nil {
		return Envelope{}, err
	}
	return envelope, nil
}

func inspectEnvelopeJSON(data []byte) (map[string]any, error) {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	opening, err := decoder.Token()
	if err != nil {
		return nil, fmt.Errorf("decode envelope: %w", err)
	}
	if delimiter, ok := opening.(json.Delim); !ok || delimiter != '{' {
		return nil, errors.New("envelope must be a JSON object")
	}

	fields := make(map[string]any)
	keys := make([]string, 0, len(allowedEnvelopeFields))
	for decoder.More() {
		token, err := decoder.Token()
		if err != nil {
			return nil, fmt.Errorf("decode envelope key: %w", err)
		}
		key, ok := token.(string)
		if !ok {
			return nil, errors.New("envelope key must be a string")
		}
		if _, ok := allowedEnvelopeFields[key]; !ok {
			return nil, fmt.Errorf("unknown or non-canonical envelope field %q", key)
		}
		if _, duplicate := fields[key]; duplicate {
			return nil, fmt.Errorf("duplicate envelope field %q", key)
		}
		var value any
		if err := decoder.Decode(&value); err != nil {
			return nil, fmt.Errorf("decode envelope field %q: %w", key, err)
		}
		fields[key] = value
		keys = append(keys, key)
	}
	closing, err := decoder.Token()
	if err != nil {
		return nil, fmt.Errorf("decode envelope closing delimiter: %w", err)
	}
	if delimiter, ok := closing.(json.Delim); !ok || delimiter != '}' {
		return nil, errors.New("envelope must end with a JSON object delimiter")
	}
	if err := requireEnd(decoder); err != nil {
		return nil, err
	}
	if err := validateAllJSONNumberTokens(data); err != nil {
		return nil, err
	}

	rawKeys := rawTopLevelKeys(data)
	if len(rawKeys) != len(keys) {
		return nil, errors.New("could not verify canonical envelope keys")
	}
	for index, key := range keys {
		if rawKeys[index] != key {
			return nil, fmt.Errorf("envelope field %q must use its canonical spelling", key)
		}
	}
	return fields, nil
}

func rawTopLevelKeys(data []byte) []string {
	keys := make([]string, 0, len(allowedEnvelopeFields))
	depth := 0
	inString := false
	escaped := false
	expectingKey := false
	keyStart := -1
	for index, character := range data {
		if inString {
			if escaped {
				escaped = false
				continue
			}
			if character == '\\' {
				escaped = true
				continue
			}
			if character == '"' {
				inString = false
				if keyStart >= 0 {
					keys = append(keys, string(data[keyStart+1:index]))
					keyStart = -1
				}
			}
			continue
		}
		switch character {
		case '{', '[':
			depth++
			if depth == 1 && character == '{' {
				expectingKey = true
			}
		case '}', ']':
			depth--
		case '"':
			inString = true
			if depth == 1 && expectingKey {
				keyStart = index
			}
		case ':':
			if depth == 1 {
				expectingKey = false
			}
		case ',':
			if depth == 1 {
				expectingKey = true
			}
		}
	}
	return keys
}

func validateAllJSONNumberTokens(data []byte) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	for {
		token, err := decoder.Token()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return fmt.Errorf("scan JSON number tokens: %w", err)
		}
		if number, ok := token.(json.Number); ok {
			if err := validateJSONNumber(number); err != nil {
				return err
			}
		}
	}
}

func validateJSONNumber(number json.Number) error {
	value, err := strconv.ParseFloat(number.String(), 64)
	if err != nil || math.IsInf(value, 0) || math.IsNaN(value) {
		return fmt.Errorf("number %q is not finite in both runtimes", number)
	}
	rational, ok := new(big.Rat).SetString(number.String())
	if !ok {
		return fmt.Errorf("number %q is not a canonical JSON number", number)
	}
	if rational.IsInt() {
		absolute := new(big.Int).Abs(new(big.Int).Set(rational.Num()))
		if absolute.Cmp(big.NewInt(maxSafeJSONInteger)) > 0 {
			return fmt.Errorf("integer %q exceeds the safe JSON range", number)
		}
	}
	return nil
}

func validateEnvelopePresence(envelope Envelope, fields map[string]any) error {
	for _, required := range []string{"protocolVersion", "type", "payload"} {
		if _, ok := fields[required]; !ok {
			return fmt.Errorf("%s is required", required)
		}
	}
	for _, optional := range []string{"gameId", "matchId", "revision", "expectedRevision", "actionId"} {
		if value, ok := fields[optional]; ok && value == nil {
			return fmt.Errorf("%s must not be null", optional)
		}
	}
	for _, identifier := range []string{"gameId", "matchId", "actionId"} {
		if value, ok := fields[identifier]; ok {
			text, isString := value.(string)
			if !isString || text == "" {
				return fmt.Errorf("%s must be a non-empty string", identifier)
			}
		}
	}

	_, hasGame := fields["gameId"]
	_, hasMatch := fields["matchId"]
	if hasGame != hasMatch {
		return errors.New("gameId and matchId must appear together")
	}
	if envelope.Type == TypePlatformConnect && hasGame {
		return errors.New("platform.connect must omit gameId and matchId")
	}
	return nil
}

func requireEnd(decoder *json.Decoder) error {
	var extra any
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("decode envelope: trailing JSON value")
		}
		return fmt.Errorf("decode envelope trailing data: %w", err)
	}
	return nil
}

func (envelope Envelope) Validate() error {
	if envelope.ProtocolVersion != Version1 {
		return fmt.Errorf("unsupported protocolVersion %d", envelope.ProtocolVersion)
	}
	if envelope.Type == "" {
		return errors.New("type is required")
	}
	if _, ok := knownTypes[envelope.Type]; !ok {
		return fmt.Errorf("unknown type %q", envelope.Type)
	}
	if envelope.Revision != nil && envelope.ExpectedRevision != nil {
		return errors.New("revision and expectedRevision are mutually exclusive")
	}
	if envelope.Revision != nil && *envelope.Revision < 0 {
		return errors.New("revision must not be negative")
	}
	if envelope.Revision != nil && *envelope.Revision > maxSafeJSONInteger {
		return errors.New("revision exceeds the safe JSON integer range")
	}
	if envelope.ExpectedRevision != nil && *envelope.ExpectedRevision < 0 {
		return errors.New("expectedRevision must not be negative")
	}
	if envelope.ExpectedRevision != nil && *envelope.ExpectedRevision > maxSafeJSONInteger {
		return errors.New("expectedRevision exceeds the safe JSON integer range")
	}
	if len(envelope.Payload) == 0 || bytes.Equal(bytes.TrimSpace(envelope.Payload), []byte("null")) {
		return errors.New("payload is required and must not be null")
	}
	var payload map[string]json.RawMessage
	if err := json.Unmarshal(envelope.Payload, &payload); err != nil || payload == nil {
		return errors.New("payload must be a JSON object")
	}

	if envelope.Type == TypePlatformConnect {
		if envelope.GameID != "" || envelope.MatchID != "" {
			return errors.New("platform.connect must not contain gameId or matchId")
		}
	} else if envelope.Type == TypePlatformError && envelope.GameID == "" && envelope.MatchID == "" {
		// A handshake error can occur before a match is identified.
	} else if envelope.GameID == "" || envelope.MatchID == "" {
		return errors.New("match-bound message requires gameId and matchId")
	}

	if isClientAction(envelope.Type) {
		if envelope.ActionID == "" {
			return errors.New("client action requires actionId")
		}
		if envelope.ExpectedRevision == nil {
			return errors.New("client action requires expectedRevision")
		}
		if envelope.Revision != nil {
			return errors.New("client action must not contain revision")
		}
		return nil
	}

	if isRevisionlessControl(envelope.Type) {
		if envelope.Revision != nil || envelope.ExpectedRevision != nil || envelope.ActionID != "" {
			return errors.New("control message must not contain revision, expectedRevision, or actionId")
		}
		return nil
	}

	if envelope.Type == TypePlatformError && envelope.GameID == "" && envelope.MatchID == "" {
		if envelope.Revision != nil || envelope.ExpectedRevision != nil || envelope.ActionID != "" {
			return errors.New("unbound platform.error must not contain match action fields")
		}
		return nil
	}

	if envelope.Revision == nil {
		return errors.New("bound server message requires revision")
	}
	if envelope.ExpectedRevision != nil {
		return errors.New("server message must not contain expectedRevision")
	}
	return nil
}
