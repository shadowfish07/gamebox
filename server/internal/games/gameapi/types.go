// Package gameapi contains the deliberately narrow boundary between the
// platform match service and individual game rule engines.
package gameapi

import (
	"encoding/json"
	"errors"
	"io"
)

var (
	// ErrInvalidAction is intentionally payload-agnostic so callers can safely
	// return it without exposing untrusted action or actor data.
	ErrInvalidAction = errors.New("invalid_request")
	// ErrInvalidEvent denotes a corrupt or unsupported persisted event stream.
	ErrInvalidEvent = errors.New("invalid_event")
	// ErrInvalidSnapshot denotes corrupt opaque game state.
	ErrInvalidSnapshot = errors.New("invalid_snapshot")
)

// Action is a platform envelope with a game-owned opaque payload.
type Action struct {
	Type    string
	Payload json.RawMessage
}

// Event is the durable, ordered platform envelope for a game-owned payload.
type Event struct {
	Revision int64
	Type     string
	ActorID  string
	Payload  json.RawMessage
}

// Snapshot carries only the platform revision and opaque game state. The
// state bytes are owned by the caller at input and by the rule engine at
// output; implementations must not retain or alias them.
type Snapshot struct {
	Revision int64
	State    json.RawMessage
}

// Rules is the complete cross-game rules boundary. It intentionally knows
// nothing about boards, colors, clocks, persistence, or transports.
type Rules interface {
	GameID() string
	PlayerLimit() int
	Rebuild(events []Event) (Snapshot, error)
	Apply(snapshot Snapshot, actorID string, action Action) (Event, Snapshot, error)
}

// RandomizedRules is an optional server-only action boundary for games whose
// accepted event contains fresh randomness. The platform serializes reader
// access, and Rebuild must remain deterministic from the persisted event.
type RandomizedRules interface {
	ApplyRandom(snapshot Snapshot, actorID string, action Action, randomSource io.Reader) (Event, Snapshot, error)
}

// Configurator binds immutable, persisted match configuration to a rules
// instance. Games without creation-time options do not implement it. The
// returned Rules value must be safe to reuse for the lifetime of one match.
type Configurator interface {
	Configure(config json.RawMessage) (Rules, error)
}

// SingleActiveMatchPolicy is optional per-game capability metadata. Platform
// code may honor it, but it is not part of every game's Rules contract.
type SingleActiveMatchPolicy interface {
	SingleActiveMatchPerUser() bool
}
