// Package results defines the source-neutral authoritative terminal projection
// shared by public and phone-hosted LAN matches.
package results

import "encoding/json"

type PlayerSnapshot struct {
	UserID   string `json:"userId"`
	Nickname string `json:"nickname"`
	Seat     int    `json:"seat"`
	Color    string `json:"color"`
}

type CanonicalEvent struct {
	Revision    int64           `json:"revision"`
	Type        string          `json:"type"`
	ActionID    *string         `json:"actionId"`
	ActorID     *string         `json:"actorId"`
	Payload     json.RawMessage `json:"payload"`
	CommittedAt int64           `json:"committedAt"`
}

type GameResult struct {
	SchemaVersion int               `json:"schemaVersion"`
	MatchID       string            `json:"matchId"`
	GameID        string            `json:"gameId"`
	Players       [2]PlayerSnapshot `json:"players"`
	WinnerUserID  *string           `json:"winnerUserId"`
	Result        string            `json:"result"`
	StartedAt     int64             `json:"startedAt"`
	FinishedAt    int64             `json:"finishedAt"`
	FinalRevision int64             `json:"finalRevision"`
	Events        []CanonicalEvent  `json:"events"`
}
