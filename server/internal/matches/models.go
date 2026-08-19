// Package matches owns durable platform match lifecycle operations.
package matches

import (
	"encoding/json"
	"time"
)

const (
	StatusActive    = "active"
	StatusCancelled = "cancelled"

	ColorBlack Color = "black"
	ColorWhite Color = "white"
)

// Color is a persisted player color allocated by the platform when a match is
// created. Individual games may interpret the two values through their rules.
type Color string

// Match is the durable platform portion of a game match.
type Match struct {
	ID        string
	GameID    string
	Status    string
	Revision  int64
	CreatedAt time.Time
	UpdatedAt time.Time
}

// Player records stable platform seating and the randomly assigned color.
// Seat zero is always the initiator and seat one is always the opponent.
type Player struct {
	UserID string
	Seat   int
	Color  Color
}

// Event is a committed match event suitable for publication after the
// service method returns. Payload owns its bytes.
type Event struct {
	MatchID     string
	Revision    int64
	Type        string
	ActionID    *string
	ActorUserID *string
	Payload     json.RawMessage
	CreatedAt   time.Time
}
