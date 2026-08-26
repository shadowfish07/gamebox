package protocol

import (
	"bytes"
	"encoding/json"
	"errors"
	"strconv"
	"unicode/utf8"

	"github.com/google/uuid"
)

const (
	TypePlatformConnect           = "platform.connect"
	TypePlatformConnected         = "platform.connected"
	TypePlatformPing              = "platform.ping"
	TypePlatformPong              = "platform.pong"
	TypePlatformPresenceChanged   = "platform.presence.changed"
	TypePlatformSnapshot          = "platform.snapshot"
	TypePlatformSnapshotRequested = "platform.snapshot.requested"
	TypePlatformError             = "platform.error"
	TypePlatformMatchCancelled    = "platform.match.cancelled"
	TypePlatformMatchAbandoned    = "platform.match.abandoned"
	TypePlatformMatchResult       = "platform.match.result"
	TypeGomokuMoveRequested       = "gomoku.move.requested"
	TypeGomokuMoveAccepted        = "gomoku.move.accepted"
	TypeGomokuResignRequested     = "gomoku.resign.requested"
	TypeGomokuResigned            = "gomoku.resigned"
	CapabilityPlayerPresence      = "player_presence_v1"
)

var knownTypes = map[string]struct{}{
	TypePlatformConnect:           {},
	TypePlatformConnected:         {},
	TypePlatformPing:              {},
	TypePlatformPong:              {},
	TypePlatformPresenceChanged:   {},
	TypePlatformSnapshot:          {},
	TypePlatformSnapshotRequested: {},
	TypePlatformError:             {},
	TypePlatformMatchCancelled:    {},
	TypePlatformMatchAbandoned:    {},
	TypePlatformMatchResult:       {},
	TypeGomokuMoveRequested:       {},
	TypeGomokuMoveAccepted:        {},
	TypeGomokuResignRequested:     {},
	TypeGomokuResigned:            {},
}

func isClientAction(messageType string) bool {
	return messageType == TypeGomokuMoveRequested || messageType == TypeGomokuResignRequested
}

func isRevisionlessControl(messageType string) bool {
	switch messageType {
	case TypePlatformConnect, TypePlatformPong, TypePlatformSnapshotRequested:
		return true
	default:
		return false
	}
}

// DecodeClient applies the envelope bounds first and then validates the exact
// set of messages and payload keys a client is permitted to send. Server-only
// message types never cross this boundary.
func DecodeClient(data []byte) (Envelope, error) {
	envelope, err := Decode(data)
	if err != nil {
		return Envelope{}, err
	}
	if err := validateClientMessage(envelope); err != nil {
		return Envelope{}, err
	}
	return envelope, nil
}

// DecodeLANClient preserves the public client contract while allowing the LAN
// transport's initial connect to prove both the one-time launch credential and
// its durable resume binding in one room transaction.
func DecodeLANClient(data []byte) (Envelope, error) {
	envelope, err := Decode(data)
	if err != nil {
		return Envelope{}, err
	}
	if envelope.Type != TypePlatformConnect {
		if err := validateClientMessage(envelope); err != nil {
			return Envelope{}, err
		}
		return envelope, nil
	}
	fields, err := exactPayloadFields(envelope.Payload, map[string]struct{}{"launchTicket": {}, "resumeToken": {}})
	if err != nil || len(fields) == 0 || len(fields) > 2 {
		return Envelope{}, protocolFailure(codeInvalidEnvelope)
	}
	if _, launch := fields["launchTicket"]; launch && len(fields) != 2 {
		return Envelope{}, protocolFailure(codeInvalidEnvelope)
	}
	if _, resume := fields["resumeToken"]; !resume {
		return Envelope{}, protocolFailure(codeInvalidEnvelope)
	}
	for _, raw := range fields {
		var token string
		if json.Unmarshal(raw, &token) != nil || token == "" || len(token) > 256 || !utf8.ValidString(token) {
			return Envelope{}, protocolFailure(codeInvalidEnvelope)
		}
	}
	return envelope, nil
}

func validateClientMessage(envelope Envelope) error {
	switch envelope.Type {
	case TypePlatformConnect:
		fields, err := exactPayloadFields(envelope.Payload, map[string]struct{}{"launchTicket": {}, "resumeToken": {}, "capabilities": {}})
		if err != nil || len(fields) < 1 || len(fields) > 2 {
			return protocolFailure(codeInvalidEnvelope)
		}
		credentials := 0
		for _, key := range []string{"launchTicket", "resumeToken"} {
			if raw, ok := fields[key]; ok {
				credentials++
				var token string
				if json.Unmarshal(raw, &token) != nil || token == "" || len(token) > 256 || !utf8.ValidString(token) {
					return protocolFailure(codeInvalidEnvelope)
				}
			}
		}
		if credentials != 1 {
			return protocolFailure(codeInvalidEnvelope)
		}
		if raw, ok := fields["capabilities"]; ok {
			var capabilities []string
			if json.Unmarshal(raw, &capabilities) != nil || len(capabilities) != 1 || capabilities[0] != CapabilityPlayerPresence {
				return protocolFailure(codeInvalidEnvelope)
			}
		}
		return nil
	case TypePlatformPong:
		fields, err := exactPayloadFields(envelope.Payload, map[string]struct{}{"nonce": {}})
		if err != nil || len(fields) != 1 {
			return protocolFailure(codeInvalidEnvelope)
		}
		var nonce string
		if json.Unmarshal(fields["nonce"], &nonce) != nil || !canonicalUUID(nonce) {
			return protocolFailure(codeInvalidEnvelope)
		}
		return validateClientBinding(envelope, false)
	case TypePlatformSnapshotRequested:
		fields, err := exactPayloadFields(envelope.Payload, map[string]struct{}{"currentRevision": {}})
		if err != nil || len(fields) != 1 {
			return protocolFailure(codeInvalidEnvelope)
		}
		if _, err := strictNonnegativeInt64(fields["currentRevision"]); err != nil {
			return protocolFailure(codeInvalidEnvelope)
		}
		return validateClientBinding(envelope, false)
	case TypeGomokuMoveRequested:
		if err := validateClientBinding(envelope, true); err != nil {
			return err
		}
		fields, err := exactPayloadFields(envelope.Payload, map[string]struct{}{"x": {}, "y": {}})
		if err != nil || len(fields) != 2 {
			return protocolFailure(codeInvalidEnvelope)
		}
		if _, err := strictInteger(fields["x"]); err != nil {
			return protocolFailure(codeInvalidEnvelope)
		}
		if _, err := strictInteger(fields["y"]); err != nil {
			return protocolFailure(codeInvalidEnvelope)
		}
		return nil
	case TypeGomokuResignRequested:
		if err := validateClientBinding(envelope, true); err != nil {
			return err
		}
		fields, err := exactPayloadFields(envelope.Payload, map[string]struct{}{})
		if err != nil || len(fields) != 0 {
			return protocolFailure(codeInvalidEnvelope)
		}
		return nil
	default:
		return protocolFailure(codeInvalidEnvelope)
	}
}

func validateClientBinding(envelope Envelope, action bool) error {
	if envelope.GameID != "gomoku" || !canonicalUUID(envelope.MatchID) {
		return protocolFailure(codeInvalidEnvelope)
	}
	if action && !canonicalUUID(envelope.ActionID) {
		return protocolFailure(codeInvalidEnvelope)
	}
	return nil
}

func canonicalUUID(value string) bool {
	parsed, err := uuid.Parse(value)
	return err == nil && parsed.String() == value && parsed.Variant() == uuid.RFC4122
}

func exactPayloadFields(data []byte, allowed map[string]struct{}) (map[string]json.RawMessage, error) {
	decoder := json.NewDecoder(bytes.NewReader(data))
	opening, err := decoder.Token()
	if err != nil || opening != json.Delim('{') {
		return nil, errors.New("invalid payload")
	}
	fields := make(map[string]json.RawMessage, len(allowed))
	keys := make([]string, 0, len(allowed))
	for decoder.More() {
		token, err := decoder.Token()
		if err != nil {
			return nil, err
		}
		key, ok := token.(string)
		if !ok {
			return nil, errors.New("invalid payload")
		}
		if _, ok := allowed[key]; !ok {
			return nil, errors.New("invalid payload")
		}
		if _, duplicate := fields[key]; duplicate {
			return nil, errors.New("invalid payload")
		}
		var raw json.RawMessage
		if err := decoder.Decode(&raw); err != nil {
			return nil, err
		}
		fields[key] = append(json.RawMessage(nil), raw...)
		keys = append(keys, key)
	}
	closing, err := decoder.Token()
	if err != nil || closing != json.Delim('}') {
		return nil, errors.New("invalid payload")
	}
	if err := requireEnd(decoder); err != nil {
		return nil, err
	}
	rawKeys := rawTopLevelKeys(data)
	if len(rawKeys) != len(keys) {
		return nil, errors.New("invalid payload")
	}
	for index := range keys {
		if rawKeys[index] != keys[index] {
			return nil, errors.New("invalid payload")
		}
	}
	return fields, nil
}

func strictInteger(raw json.RawMessage) (int64, error) {
	if len(raw) == 0 || len(raw) > 32 {
		return 0, errors.New("invalid integer")
	}
	for index, character := range raw {
		if character == '-' && index == 0 {
			continue
		}
		if character < '0' || character > '9' {
			return 0, errors.New("invalid integer")
		}
	}
	if raw[0] == '-' && len(raw) == 1 || len(raw) > 1 && raw[0] == '0' || len(raw) > 2 && raw[0] == '-' && raw[1] == '0' {
		return 0, errors.New("invalid integer")
	}
	value, err := strconv.ParseInt(string(raw), 10, 64)
	if err != nil || value < -maxSafeJSONInteger || value > maxSafeJSONInteger {
		return 0, errors.New("invalid integer")
	}
	return value, nil
}

func strictNonnegativeInt64(raw json.RawMessage) (int64, error) {
	value, err := strictInteger(raw)
	if err != nil || value < 0 {
		return 0, errors.New("invalid integer")
	}
	return value, nil
}
