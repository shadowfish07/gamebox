package results

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"unicode/utf8"

	"github.com/google/uuid"
)

var ErrInvalidResult = errors.New("invalid authoritative game result")

// Leave room for the protocol envelope while keeping every canonical result
// deliverable over the shared 64 KiB WebSocket limit.
const maximumResultBytes = 60 * 1024

func ValidateAndEncode(result GameResult) ([]byte, error) {
	if result.SchemaVersion != 1 || !canonicalUUID(result.MatchID) || result.GameID != "gomoku" ||
		result.StartedAt <= 0 || result.FinishedAt < result.StartedAt || result.FinalRevision <= 0 ||
		int64(len(result.Events)) != result.FinalRevision || len(result.Events) > 226 ||
		(result.Result != "five" && result.Result != "resignation" && result.Result != "draw") {
		return nil, ErrInvalidResult
	}
	seenUsers := map[string]struct{}{}
	seenSeats := map[int]struct{}{}
	seenColors := map[string]struct{}{}
	for _, player := range result.Players {
		if !canonicalUUID(player.UserID) || player.Nickname == "" || !utf8.ValidString(player.Nickname) || len([]byte(player.Nickname)) > 80 ||
			(player.Seat != 0 && player.Seat != 1) || (player.Color != "black" && player.Color != "white") {
			return nil, ErrInvalidResult
		}
		seenUsers[player.UserID] = struct{}{}
		seenSeats[player.Seat] = struct{}{}
		seenColors[player.Color] = struct{}{}
	}
	if len(seenUsers) != 2 || len(seenSeats) != 2 || len(seenColors) != 2 {
		return nil, ErrInvalidResult
	}
	if result.Result == "draw" {
		if result.WinnerUserID != nil {
			return nil, ErrInvalidResult
		}
	} else if result.WinnerUserID == nil {
		return nil, ErrInvalidResult
	} else if _, exists := seenUsers[*result.WinnerUserID]; !exists {
		return nil, ErrInvalidResult
	}
	seenActions := map[string]struct{}{}
	for index := range result.Events {
		event := &result.Events[index]
		if event.Revision != int64(index+1) || event.Type == "" || len(event.Type) > 128 ||
			event.CommittedAt < result.StartedAt || event.CommittedAt > result.FinishedAt ||
			(index > 0 && event.CommittedAt < result.Events[index-1].CommittedAt) {
			return nil, ErrInvalidResult
		}
		if event.ActionID != nil {
			if !canonicalUUID(*event.ActionID) {
				return nil, ErrInvalidResult
			}
			if _, duplicate := seenActions[*event.ActionID]; duplicate {
				return nil, ErrInvalidResult
			}
			seenActions[*event.ActionID] = struct{}{}
		}
		if event.ActorID != nil {
			if _, exists := seenUsers[*event.ActorID]; !exists {
				return nil, ErrInvalidResult
			}
		}
		canonicalPayload, err := canonicalObject(event.Payload)
		if err != nil {
			return nil, ErrInvalidResult
		}
		event.Payload = canonicalPayload
	}
	if result.Events[len(result.Events)-1].CommittedAt != result.FinishedAt {
		return nil, ErrInvalidResult
	}
	encoded, err := json.Marshal(result)
	if err != nil || len(encoded) > maximumResultBytes {
		return nil, ErrInvalidResult
	}
	return encoded, nil
}

func Hash(encoded []byte) (string, error) {
	if len(encoded) == 0 || len(encoded) > maximumResultBytes {
		return "", ErrInvalidResult
	}
	digest := sha256.Sum256(encoded)
	return hex.EncodeToString(digest[:]), nil
}

func canonicalObject(raw json.RawMessage) (json.RawMessage, error) {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var value map[string]any
	if err := decoder.Decode(&value); err != nil || value == nil {
		return nil, ErrInvalidResult
	}
	var trailing any
	if decoder.Decode(&trailing) == nil {
		return nil, ErrInvalidResult
	}
	encoded, err := json.Marshal(value)
	if err != nil {
		return nil, ErrInvalidResult
	}
	return encoded, nil
}

func canonicalUUID(value string) bool {
	parsed, err := uuid.Parse(value)
	return err == nil && parsed != uuid.Nil && parsed.String() == value
}
