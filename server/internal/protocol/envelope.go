package protocol

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"math"
	"math/big"
	"strconv"
)

const Version1 = 1
const maxSafeJSONInteger int64 = 9_007_199_254_740_991

const (
	MaxMessageBytes     = 64 * 1024
	MaxJSONDepth        = 32
	MaxNumberTokenBytes = 128
)

const (
	codeInvalidJSON        = "invalid_json"
	codeInvalidEnvelope    = "invalid_envelope"
	codeUnsupportedVersion = "unsupported_version"
	codeUnsafeNumber       = "unsafe_number"
	codeMessageTooLarge    = "message_too_large"
	codeJSONTooDeep        = "json_too_deep"
	codeNumberTokenTooLong = "number_token_too_long"
)

var protocolErrorMessages = map[string]string{
	codeInvalidJSON:        "Message is not valid JSON",
	codeInvalidEnvelope:    "Message envelope is invalid",
	codeUnsupportedVersion: "Protocol version is not supported",
	codeUnsafeNumber:       "JSON number is not cross-runtime safe",
	codeMessageTooLarge:    "Message exceeds the size limit",
	codeJSONTooDeep:        "JSON exceeds the nesting limit",
	codeNumberTokenTooLong: "JSON number token exceeds the size limit",
}

type ProtocolError struct {
	Code    string
	Message string
}

func (failure *ProtocolError) Error() string {
	return failure.Code + ": " + failure.Message
}

func protocolFailure(code string) error {
	return &ProtocolError{Code: code, Message: protocolErrorMessages[code]}
}

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
	if err := validateJSONBoundsAndNumbers(data); err != nil {
		return Envelope{}, err
	}
	fields, err := inspectEnvelopeJSON(data)
	if err != nil {
		return Envelope{}, err
	}

	var envelope Envelope
	if err := json.Unmarshal(data, &envelope); err != nil {
		return Envelope{}, protocolFailure(codeInvalidJSON)
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
		return nil, protocolFailure(codeInvalidJSON)
	}
	if delimiter, ok := opening.(json.Delim); !ok || delimiter != '{' {
		return nil, protocolFailure(codeInvalidEnvelope)
	}

	fields := make(map[string]any)
	keys := make([]string, 0, len(allowedEnvelopeFields))
	for decoder.More() {
		token, err := decoder.Token()
		if err != nil {
			return nil, protocolFailure(codeInvalidJSON)
		}
		key, ok := token.(string)
		if !ok {
			return nil, protocolFailure(codeInvalidEnvelope)
		}
		if _, ok := allowedEnvelopeFields[key]; !ok {
			return nil, protocolFailure(codeInvalidEnvelope)
		}
		if _, duplicate := fields[key]; duplicate {
			return nil, protocolFailure(codeInvalidEnvelope)
		}
		var value any
		if err := decoder.Decode(&value); err != nil {
			return nil, protocolFailure(codeInvalidJSON)
		}
		fields[key] = value
		keys = append(keys, key)
	}
	closing, err := decoder.Token()
	if err != nil {
		return nil, protocolFailure(codeInvalidJSON)
	}
	if delimiter, ok := closing.(json.Delim); !ok || delimiter != '}' {
		return nil, protocolFailure(codeInvalidEnvelope)
	}
	if err := requireEnd(decoder); err != nil {
		return nil, err
	}
	rawKeys := rawTopLevelKeys(data)
	if len(rawKeys) != len(keys) {
		return nil, protocolFailure(codeInvalidEnvelope)
	}
	for index, key := range keys {
		if rawKeys[index] != key {
			return nil, protocolFailure(codeInvalidEnvelope)
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

func validateJSONBoundsAndNumbers(data []byte) error {
	if len(data) > MaxMessageBytes {
		return protocolFailure(codeMessageTooLarge)
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	depth := 0
	for {
		token, err := decoder.Token()
		if errors.Is(err, io.EOF) {
			if depth != 0 {
				return protocolFailure(codeInvalidJSON)
			}
			return nil
		}
		if err != nil {
			return protocolFailure(codeInvalidJSON)
		}
		if delimiter, ok := token.(json.Delim); ok {
			switch delimiter {
			case '{', '[':
				depth++
				if depth > MaxJSONDepth {
					return protocolFailure(codeJSONTooDeep)
				}
			case '}', ']':
				depth--
				if depth < 0 {
					return protocolFailure(codeInvalidJSON)
				}
			}
		}
		if number, ok := token.(json.Number); ok {
			if len(number.String()) > MaxNumberTokenBytes {
				return protocolFailure(codeNumberTokenTooLong)
			}
			if err := validateJSONNumber(number); err != nil {
				return err
			}
		}
	}
}

func validateJSONNumber(number json.Number) error {
	value, err := strconv.ParseFloat(number.String(), 64)
	if err != nil || math.IsInf(value, 0) || math.IsNaN(value) {
		return protocolFailure(codeUnsafeNumber)
	}
	rational, ok := new(big.Rat).SetString(number.String())
	if !ok {
		return protocolFailure(codeUnsafeNumber)
	}
	if !rational.IsInt() && math.Trunc(value) == value {
		return protocolFailure(codeUnsafeNumber)
	}
	if rational.IsInt() {
		absolute := new(big.Int).Abs(new(big.Int).Set(rational.Num()))
		if absolute.Cmp(big.NewInt(maxSafeJSONInteger)) > 0 {
			return protocolFailure(codeUnsafeNumber)
		}
	}
	return nil
}

func validateEnvelopePresence(envelope Envelope, fields map[string]any) error {
	for _, required := range []string{"protocolVersion", "type", "payload"} {
		if _, ok := fields[required]; !ok {
			return protocolFailure(codeInvalidEnvelope)
		}
	}
	for _, optional := range []string{"gameId", "matchId", "revision", "expectedRevision", "actionId"} {
		if value, ok := fields[optional]; ok && value == nil {
			return protocolFailure(codeInvalidEnvelope)
		}
	}
	for _, identifier := range []string{"gameId", "matchId", "actionId"} {
		if value, ok := fields[identifier]; ok {
			text, isString := value.(string)
			if !isString || text == "" {
				return protocolFailure(codeInvalidEnvelope)
			}
		}
	}

	_, hasGame := fields["gameId"]
	_, hasMatch := fields["matchId"]
	if hasGame != hasMatch {
		return protocolFailure(codeInvalidEnvelope)
	}
	if envelope.Type == TypePlatformConnect && hasGame {
		return protocolFailure(codeInvalidEnvelope)
	}
	return nil
}

func requireEnd(decoder *json.Decoder) error {
	var extra any
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		return protocolFailure(codeInvalidJSON)
	}
	return nil
}

func (envelope Envelope) Validate() error {
	if envelope.ProtocolVersion != Version1 {
		return protocolFailure(codeUnsupportedVersion)
	}
	if envelope.Type == "" {
		return protocolFailure(codeInvalidEnvelope)
	}
	if _, ok := knownTypes[envelope.Type]; !ok {
		return protocolFailure(codeInvalidEnvelope)
	}
	if envelope.Revision != nil && envelope.ExpectedRevision != nil {
		return protocolFailure(codeInvalidEnvelope)
	}
	if envelope.Revision != nil && *envelope.Revision < 0 {
		return protocolFailure(codeInvalidEnvelope)
	}
	if envelope.Revision != nil && *envelope.Revision > maxSafeJSONInteger {
		return protocolFailure(codeUnsafeNumber)
	}
	if envelope.ExpectedRevision != nil && *envelope.ExpectedRevision < 0 {
		return protocolFailure(codeInvalidEnvelope)
	}
	if envelope.ExpectedRevision != nil && *envelope.ExpectedRevision > maxSafeJSONInteger {
		return protocolFailure(codeUnsafeNumber)
	}
	if len(envelope.Payload) == 0 || bytes.Equal(bytes.TrimSpace(envelope.Payload), []byte("null")) {
		return protocolFailure(codeInvalidEnvelope)
	}
	var payload map[string]json.RawMessage
	if err := json.Unmarshal(envelope.Payload, &payload); err != nil || payload == nil {
		return protocolFailure(codeInvalidEnvelope)
	}

	if envelope.Type == TypePlatformConnect {
		if envelope.GameID != "" || envelope.MatchID != "" {
			return protocolFailure(codeInvalidEnvelope)
		}
	} else if envelope.Type == TypePlatformError && envelope.GameID == "" && envelope.MatchID == "" {
		// A handshake error can occur before a match is identified.
	} else if envelope.GameID == "" || envelope.MatchID == "" {
		return protocolFailure(codeInvalidEnvelope)
	}

	if isClientAction(envelope.Type) {
		if envelope.ActionID == "" {
			return protocolFailure(codeInvalidEnvelope)
		}
		if envelope.ExpectedRevision == nil {
			return protocolFailure(codeInvalidEnvelope)
		}
		if envelope.Revision != nil {
			return protocolFailure(codeInvalidEnvelope)
		}
		return nil
	}

	if isRevisionlessControl(envelope.Type) {
		if envelope.Revision != nil || envelope.ExpectedRevision != nil || envelope.ActionID != "" {
			return protocolFailure(codeInvalidEnvelope)
		}
		return nil
	}

	if envelope.Type == TypePlatformError && envelope.GameID == "" && envelope.MatchID == "" {
		if envelope.Revision != nil || envelope.ExpectedRevision != nil || envelope.ActionID != "" {
			return protocolFailure(codeInvalidEnvelope)
		}
		return nil
	}

	if envelope.Revision == nil {
		return protocolFailure(codeInvalidEnvelope)
	}
	if envelope.ExpectedRevision != nil {
		return protocolFailure(codeInvalidEnvelope)
	}
	return nil
}
