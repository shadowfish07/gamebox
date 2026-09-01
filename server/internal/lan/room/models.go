// Package room owns one authoritative, journal-backed LAN Gomoku room.
package room

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"time"

	"me.zqydev/gamebox/server/internal/games/gameapi"
	"me.zqydev/gamebox/server/internal/lan/journal"
)

var (
	ErrInvalidConfiguration = errors.New("invalid room configuration")
	ErrInvalidRequest       = errors.New("invalid_request")
	ErrRoomExists           = errors.New("room_exists")
	ErrRoomNotFound         = errors.New("room_not_found")
	ErrRoomLocked           = errors.New("room_locked")
	ErrJoinExpired          = errors.New("join_expired")
	ErrRoomKeyInvalid       = errors.New("room_key_invalid")
	ErrTicketInvalid        = errors.New("ticket_invalid")
	ErrResumeInvalid        = errors.New("resume_invalid")
	ErrStaleRevision        = errors.New("stale_revision")
	ErrActionConflict       = errors.New("action_conflict")
	ErrRoomNotCancellable   = errors.New("room_not_cancellable")
	ErrResultNotReady       = errors.New("result_not_ready")
	ErrResultHashMismatch   = errors.New("result_hash_mismatch")
	ErrRecoveryCorrupt      = errors.New("recovery_corrupt")
	ErrInternal             = errors.New("internal_error")
)

const (
	StatusEmpty     = "empty"
	StatusWaiting   = "waiting"
	StatusActive    = "active"
	StatusCancelled = "cancelled"
	StatusFinished  = "finished"

	ColorBlack Color = "black"
	ColorWhite Color = "white"

	ResultFive        = "five"
	ResultDraw        = "draw"
	ResultResignation = "resignation"
)

type Color string

// Config supplies storage and independently injectable entropy boundaries.
// TokenPepper is required when replaying an existing room and is always
// redacted from formatted output.
type Config struct {
	Root             string
	FileOps          journal.FileOps
	Clock            func() time.Time
	ColorRandom      io.Reader
	PlayerRandom     io.Reader
	CredentialRandom io.Reader
	TokenPepper      string
}

func (Config) String() string {
	return "room.Config{Root:<path> FileOps:<ops> Clock:<clock> ColorRandom:<reader> PlayerRandom:<reader> CredentialRandom:<reader> TokenPepper:<redacted>}"
}

func (config Config) GoString() string { return config.String() }

type CreateRequest struct {
	RoomID          string
	HostPlayerID    string
	HostNickname    string
	RoomKey         string
	TokenPepper     string
	HostResumeToken string
	JoinExpiresAt   int64
}

func (CreateRequest) String() string {
	return "CreateRequest{RoomID:<id> HostPlayerID:<id> HostNickname:<redacted> RoomKey:<redacted> TokenPepper:<redacted> HostResumeToken:<redacted> JoinExpiresAt:<time>}"
}

func (request CreateRequest) GoString() string { return request.String() }

type JoinRequest struct {
	RoomID               string
	Nickname             string
	JoinAttemptID        string
	CandidateResumeToken string
	RoomKey              string
}

func (JoinRequest) String() string {
	return "JoinRequest{RoomID:<id> Nickname:<redacted> JoinAttemptID:<id> CandidateResumeToken:<redacted> RoomKey:<redacted>}"
}

func (request JoinRequest) GoString() string { return request.String() }

type ConnectCredential struct {
	LaunchTicket string
	ResumeToken  string
}

func (credential ConnectCredential) String() string {
	return fmt.Sprintf("ConnectCredential{LaunchTicket:<redacted:%t> ResumeToken:<redacted:%t>}", credential.LaunchTicket != "", credential.ResumeToken != "")
}

func (credential ConnectCredential) GoString() string { return credential.String() }

type ActionRequest struct {
	PlayerID         string
	ActionID         string
	ExpectedRevision int64
	Type             string
	Payload          json.RawMessage
}

type Player struct {
	PlayerID string `json:"playerId"`
	Nickname string `json:"nickname"`
	Seat     int    `json:"seat"`
	Color    Color  `json:"color"`
}

type LaunchTicket struct {
	PlayerID  string `json:"playerId"`
	Token     string `json:"launchTicket"`
	ExpiresAt int64  `json:"expiresAt"`
}

func (ticket LaunchTicket) String() string {
	return fmt.Sprintf("LaunchTicket{PlayerID:%q Token:<redacted> ExpiresAt:%d}", ticket.PlayerID, ticket.ExpiresAt)
}

func (ticket LaunchTicket) GoString() string { return ticket.String() }

type ConnectionCredential struct {
	RoomID   string `json:"roomId"`
	PlayerID string `json:"playerId"`
}

type Event struct {
	RoomID        string          `json:"roomId"`
	Revision      int64           `json:"revision"`
	Type          string          `json:"type"`
	ActionID      string          `json:"actionId,omitempty"`
	ActorPlayerID string          `json:"actorPlayerId,omitempty"`
	Payload       json.RawMessage `json:"payload"`
	CommittedAt   int64           `json:"committedAt"`
}

// GameResult is the Task-3-local terminal projection. ResultHash is the exact
// lower-case SHA-256 hash of the committed room.finished journal record.
type GameResult struct {
	ResultHash     string  `json:"resultHash"`
	WinnerPlayerID *string `json:"winnerPlayerId"`
	Reason         string  `json:"reason"`
	Revision       int64   `json:"revision"`
}

type Snapshot struct {
	RoomID                      string           `json:"roomId"`
	GameID                      string           `json:"gameId"`
	Status                      string           `json:"status"`
	Revision                    int64            `json:"revision"`
	Players                     []Player         `json:"players"`
	Game                        gameapi.Snapshot `json:"game"`
	Result                      *GameResult      `json:"result,omitempty"`
	ResultAcknowledgedPlayerIDs []string         `json:"resultAcknowledgedPlayerIds"`
	JoinExpiresAt               int64            `json:"joinExpiresAt,omitempty"`
}

type CreatedRoom struct {
	Snapshot Snapshot `json:"snapshot"`
}

type JoinedPlayer struct {
	Player       Player       `json:"player"`
	LaunchTicket LaunchTicket `json:"launchTicket"`
}
