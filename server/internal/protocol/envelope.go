package protocol

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
)

const Version1 = 1

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
	var envelope Envelope
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&envelope); err != nil {
		return Envelope{}, fmt.Errorf("decode envelope: %w", err)
	}
	if err := requireEnd(decoder); err != nil {
		return Envelope{}, err
	}
	if err := rejectExplicitNullEnvelopeFields(data); err != nil {
		return Envelope{}, err
	}
	if err := envelope.Validate(); err != nil {
		return Envelope{}, err
	}
	return envelope, nil
}

func rejectExplicitNullEnvelopeFields(data []byte) error {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		return fmt.Errorf("inspect envelope fields: %w", err)
	}
	for _, field := range []string{"gameId", "matchId", "revision", "expectedRevision", "actionId"} {
		if raw, ok := fields[field]; ok && bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
			return fmt.Errorf("%s must not be null", field)
		}
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
	if envelope.ExpectedRevision != nil && *envelope.ExpectedRevision < 0 {
		return errors.New("expectedRevision must not be negative")
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
