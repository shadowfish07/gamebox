// Package matches owns durable platform match lifecycle operations.
package matches

import (
	"encoding/json"
	"time"

	"me.zqydev/gamebox/server/internal/games"
)

const (
	StatusActive    = "active"
	StatusCancelled = "cancelled"
	StatusFinished  = "finished"
	StatusAbandoned = "abandoned"

	ResultFive        = "five"
	ResultResignation = "resignation"
	ResultDraw        = "draw"

	ColorBlack Color = "black"
	ColorWhite Color = "white"
)

// Color is a persisted player color allocated by the platform when a match is
// created. Individual games may interpret the two values through their rules.
type Color string

// Match is the durable platform portion of a game match.
type Match struct {
	ID           string
	GameID       string
	Status       string
	Revision     int64
	Result       *string
	WinnerUserID *string
	CreatedAt    time.Time
	UpdatedAt    time.Time
	FinishedAt   *time.Time
}

// Player records stable platform seating and the randomly assigned color.
// Seat zero is always the initiator and seat one is always the opponent.
type Player struct {
	UserID   string
	Nickname string
	Seat     int
	Color    Color
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

// ActionRequest is the authenticated platform action boundary. Payload is
// interpreted strictly by the selected game's rules, while identity, action
// idempotency, and expectedRevision are enforced by Service.
type ActionRequest struct {
	MatchID          string
	ActorUserID      string
	ActionID         string
	ExpectedRevision int64
	Type             string
	Payload          json.RawMessage
}

// Snapshot is a consistent durable match view. Game is rebuilt from accepted
// game events; terminal platform metadata such as resignation remains on
// Match rather than being forged into a game-owned state document.
type Snapshot struct {
	Match   Match
	Players []Player
	Game    games.Snapshot
}
