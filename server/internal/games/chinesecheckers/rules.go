// Package chinesecheckers implements server-authoritative two-player Chinese
// checkers on the standard 121-hole star board.
package chinesecheckers

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"unicode"
	"unicode/utf8"

	"me.zqydev/gamebox/server/internal/games/gameapi"
)

const (
	GameID = "chinese_checkers"

	MoveRequested = "chinese_checkers.move.requested"
	MoveAccepted  = "chinese_checkers.move.accepted"

	statusActive   = "active"
	statusFinished = "finished"
	resultGoal     = "goal"
	resultResign   = "resignation"
)

var (
	ErrNotYourTurn = errors.New("not_your_turn")
	ErrInvalidPath = errors.New("invalid_move")
)

type Rules struct{}

func NewRules() *Rules { return &Rules{} }

func (*Rules) GameID() string { return GameID }

func (*Rules) PlayerLimit() int { return 2 }

func (*Rules) SingleActiveMatchPerUser() bool { return true }

type snapshotState struct {
	Status       string            `json:"status"`
	Board        [BoardCells]uint8 `json:"board"`
	BlackUserID  *string           `json:"blackUserId"`
	WhiteUserID  *string           `json:"whiteUserId"`
	NextColor    string            `json:"nextColor"`
	WinnerUserID *string           `json:"winnerUserId"`
	Result       *string           `json:"result"`
}

type movePayload struct {
	Path []int `json:"path"`
}

type acceptedMovePayload struct {
	Path   []int  `json:"path"`
	Color  string `json:"color"`
	UserID string `json:"userId"`
}

func (*Rules) Rebuild(events []gameapi.Event) (gameapi.Snapshot, error) {
	snapshot, err := initialSnapshot()
	if err != nil {
		return gameapi.Snapshot{}, gameapi.ErrInvalidSnapshot
	}
	for index, persisted := range events {
		if persisted.Revision != int64(index+1) || persisted.Type != MoveAccepted || !validActorID(persisted.ActorID) {
			return gameapi.Snapshot{}, gameapi.ErrInvalidEvent
		}
		accepted, decodeErr := decodeAcceptedMove(persisted.Payload)
		if decodeErr != nil || accepted.UserID != persisted.ActorID {
			return gameapi.Snapshot{}, gameapi.ErrInvalidEvent
		}
		current, stateErr := decodeSnapshot(snapshot)
		if stateErr != nil || accepted.Color != current.NextColor {
			return gameapi.Snapshot{}, gameapi.ErrInvalidEvent
		}
		produced, next, applyErr := applyMove(snapshot, persisted.ActorID, accepted.Path)
		if applyErr != nil || produced.Revision != persisted.Revision || produced.Type != persisted.Type || produced.ActorID != persisted.ActorID || !bytes.Equal(produced.Payload, persisted.Payload) {
			return gameapi.Snapshot{}, gameapi.ErrInvalidEvent
		}
		snapshot = next
	}
	return cloneSnapshot(snapshot), nil
}

func (*Rules) Apply(snapshot gameapi.Snapshot, actorID string, action gameapi.Action) (gameapi.Event, gameapi.Snapshot, error) {
	if action.Type != MoveRequested || !validActorID(actorID) {
		return gameapi.Event{}, gameapi.Snapshot{}, gameapi.ErrInvalidAction
	}
	path, err := decodeMove(action.Payload)
	if err != nil {
		return gameapi.Event{}, gameapi.Snapshot{}, gameapi.ErrInvalidAction
	}
	if len(snapshot.State) == 0 && snapshot.Revision == 0 {
		snapshot, err = initialSnapshot()
		if err != nil {
			return gameapi.Event{}, gameapi.Snapshot{}, gameapi.ErrInvalidSnapshot
		}
	}
	return applyMove(snapshot, actorID, path)
}

func applyMove(snapshot gameapi.Snapshot, actorID string, path []int) (gameapi.Event, gameapi.Snapshot, error) {
	state, err := decodeSnapshot(snapshot)
	if err != nil {
		return gameapi.Event{}, gameapi.Snapshot{}, gameapi.ErrInvalidSnapshot
	}
	if state.Status != statusActive {
		return gameapi.Event{}, gameapi.Snapshot{}, gameapi.ErrInvalidAction
	}
	color := colorNamed(state.NextColor)
	if color == Empty {
		return gameapi.Event{}, gameapi.Snapshot{}, gameapi.ErrInvalidSnapshot
	}
	expectedActor := actorForColor(state, color)
	if expectedActor != nil {
		if *expectedActor != actorID {
			return gameapi.Event{}, gameapi.Snapshot{}, ErrNotYourTurn
		}
	} else {
		otherActor := actorForColor(state, opposite(color))
		if otherActor != nil && *otherActor == actorID {
			return gameapi.Event{}, gameapi.Snapshot{}, ErrNotYourTurn
		}
		actorCopy := actorID
		if color == Black {
			state.BlackUserID = &actorCopy
		} else {
			state.WhiteUserID = &actorCopy
		}
	}
	if !validMovePath(state.Board, color, path) {
		return gameapi.Event{}, gameapi.Snapshot{}, ErrInvalidPath
	}
	state.Board[path[0]] = uint8(Empty)
	state.Board[path[len(path)-1]] = uint8(color)
	state.NextColor = opposite(color).String()
	if hasCompletedCamp(state.Board, color) {
		winner := actorID
		result := resultGoal
		state.Status = statusFinished
		state.WinnerUserID = &winner
		state.Result = &result
	}

	payload, err := json.Marshal(acceptedMovePayload{Path: append([]int(nil), path...), Color: color.String(), UserID: actorID})
	if err != nil {
		return gameapi.Event{}, gameapi.Snapshot{}, gameapi.ErrInvalidAction
	}
	encodedState, err := json.Marshal(state)
	if err != nil {
		return gameapi.Event{}, gameapi.Snapshot{}, gameapi.ErrInvalidSnapshot
	}
	revision := snapshot.Revision + 1
	return gameapi.Event{Revision: revision, Type: MoveAccepted, ActorID: actorID, Payload: payload}, gameapi.Snapshot{Revision: revision, State: encodedState}, nil
}

func initialSnapshot() (gameapi.Snapshot, error) {
	state := snapshotState{Status: statusActive, Board: initialBoard(), NextColor: Black.String()}
	encoded, err := json.Marshal(state)
	if err != nil {
		return gameapi.Snapshot{}, err
	}
	return gameapi.Snapshot{State: encoded}, nil
}

func decodeMove(payload json.RawMessage) ([]int, error) {
	if len(payload) > 2048 || !utf8.Valid(payload) {
		return nil, gameapi.ErrInvalidAction
	}
	seen, fields, err := decodeObject(payload, map[string]struct{}{"path": {}})
	if err != nil || !seen["path"] {
		return nil, gameapi.ErrInvalidAction
	}
	return decodePath(fields["path"], gameapi.ErrInvalidAction)
}

func decodeAcceptedMove(payload json.RawMessage) (acceptedMovePayload, error) {
	if len(payload) > 2304 || !utf8.Valid(payload) {
		return acceptedMovePayload{}, gameapi.ErrInvalidEvent
	}
	allowed := map[string]struct{}{"path": {}, "color": {}, "userId": {}}
	seen, fields, err := decodeObject(payload, allowed)
	if err != nil || len(seen) != len(allowed) {
		return acceptedMovePayload{}, gameapi.ErrInvalidEvent
	}
	path, err := decodePath(fields["path"], gameapi.ErrInvalidEvent)
	if err != nil {
		return acceptedMovePayload{}, gameapi.ErrInvalidEvent
	}
	var color, userID string
	if json.Unmarshal(fields["color"], &color) != nil || colorNamed(color) == Empty || json.Unmarshal(fields["userId"], &userID) != nil || !validActorID(userID) {
		return acceptedMovePayload{}, gameapi.ErrInvalidEvent
	}
	return acceptedMovePayload{Path: path, Color: color, UserID: userID}, nil
}

func decodePath(raw json.RawMessage, invalid error) ([]int, error) {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	token, err := decoder.Token()
	if err != nil || token != json.Delim('[') {
		return nil, invalid
	}
	path := make([]int, 0, 8)
	for decoder.More() {
		if len(path) >= BoardCells {
			return nil, invalid
		}
		var number json.RawMessage
		if err := decoder.Decode(&number); err != nil {
			return nil, invalid
		}
		value, err := decodeInteger(number)
		if err != nil || value < 0 || value >= BoardCells {
			return nil, invalid
		}
		path = append(path, value)
	}
	if token, err = decoder.Token(); err != nil || token != json.Delim(']') || len(path) < 2 {
		return nil, invalid
	}
	if _, err := decoder.Token(); !errors.Is(err, io.EOF) {
		return nil, invalid
	}
	return path, nil
}

func decodeSnapshot(snapshot gameapi.Snapshot) (snapshotState, error) {
	if snapshot.Revision < 0 || len(snapshot.State) > 8192 || !utf8.Valid(snapshot.State) {
		return snapshotState{}, gameapi.ErrInvalidSnapshot
	}
	allowed := map[string]struct{}{"status": {}, "board": {}, "blackUserId": {}, "whiteUserId": {}, "nextColor": {}, "winnerUserId": {}, "result": {}}
	seen, fields, err := decodeObject(snapshot.State, allowed)
	if err != nil || len(seen) != len(allowed) {
		return snapshotState{}, gameapi.ErrInvalidSnapshot
	}
	var rawBoard []int
	if err := json.Unmarshal(fields["board"], &rawBoard); err != nil || len(rawBoard) != BoardCells {
		return snapshotState{}, gameapi.ErrInvalidSnapshot
	}
	var state snapshotState
	decoder := json.NewDecoder(bytes.NewReader(snapshot.State))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&state); err != nil {
		return snapshotState{}, gameapi.ErrInvalidSnapshot
	}
	blackCount, whiteCount := 0, 0
	for _, raw := range state.Board {
		switch Color(raw) {
		case Black:
			blackCount++
		case White:
			whiteCount++
		case Empty:
		default:
			return snapshotState{}, gameapi.ErrInvalidSnapshot
		}
	}
	if blackCount != 10 || whiteCount != 10 || !validOptionalActor(state.BlackUserID) || !validOptionalActor(state.WhiteUserID) {
		return snapshotState{}, gameapi.ErrInvalidSnapshot
	}
	if state.BlackUserID != nil && state.WhiteUserID != nil && *state.BlackUserID == *state.WhiteUserID {
		return snapshotState{}, gameapi.ErrInvalidSnapshot
	}
	if snapshot.Revision == 0 && (state.BlackUserID != nil || state.WhiteUserID != nil) || snapshot.Revision == 1 && (state.BlackUserID == nil || state.WhiteUserID != nil) || snapshot.Revision >= 2 && (state.BlackUserID == nil || state.WhiteUserID == nil) {
		return snapshotState{}, gameapi.ErrInvalidSnapshot
	}
	expectedColor := Black
	if snapshot.Revision%2 == 1 {
		expectedColor = White
	}
	if state.NextColor != expectedColor.String() {
		return snapshotState{}, gameapi.ErrInvalidSnapshot
	}
	blackComplete := hasCompletedCamp(state.Board, Black)
	whiteComplete := hasCompletedCamp(state.Board, White)
	switch state.Status {
	case statusActive:
		if state.WinnerUserID != nil || state.Result != nil || blackComplete || whiteComplete {
			return snapshotState{}, gameapi.ErrInvalidSnapshot
		}
	case statusFinished:
		if state.Result == nil {
			return snapshotState{}, gameapi.ErrInvalidSnapshot
		}
		switch *state.Result {
		case resultGoal:
			if state.WinnerUserID == nil || blackComplete == whiteComplete {
				return snapshotState{}, gameapi.ErrInvalidSnapshot
			}
			winnerColor := Black
			if whiteComplete {
				winnerColor = White
			}
			if *state.WinnerUserID != valueOrEmpty(actorForColor(state, winnerColor)) {
				return snapshotState{}, gameapi.ErrInvalidSnapshot
			}
		case resultResign:
			if state.WinnerUserID == nil || blackComplete || whiteComplete || (*state.WinnerUserID != valueOrEmpty(state.BlackUserID) && *state.WinnerUserID != valueOrEmpty(state.WhiteUserID)) {
				return snapshotState{}, gameapi.ErrInvalidSnapshot
			}
		default:
			return snapshotState{}, gameapi.ErrInvalidSnapshot
		}
	default:
		return snapshotState{}, gameapi.ErrInvalidSnapshot
	}
	return state, nil
}

func decodeObject(data []byte, allowed map[string]struct{}) (map[string]bool, map[string]json.RawMessage, error) {
	decoder := json.NewDecoder(bytes.NewReader(data))
	token, err := decoder.Token()
	if err != nil || token != json.Delim('{') {
		return nil, nil, gameapi.ErrInvalidAction
	}
	seen := make(map[string]bool, len(allowed))
	fields := make(map[string]json.RawMessage, len(allowed))
	for decoder.More() {
		token, err := decoder.Token()
		if err != nil {
			return nil, nil, gameapi.ErrInvalidAction
		}
		key, ok := token.(string)
		if !ok || seen[key] {
			return nil, nil, gameapi.ErrInvalidAction
		}
		if _, ok := allowed[key]; !ok {
			return nil, nil, gameapi.ErrInvalidAction
		}
		seen[key] = true
		var raw json.RawMessage
		if err := decoder.Decode(&raw); err != nil {
			return nil, nil, gameapi.ErrInvalidAction
		}
		fields[key] = append(json.RawMessage(nil), raw...)
	}
	if token, err = decoder.Token(); err != nil || token != json.Delim('}') {
		return nil, nil, gameapi.ErrInvalidAction
	}
	if _, err := decoder.Token(); !errors.Is(err, io.EOF) {
		return nil, nil, gameapi.ErrInvalidAction
	}
	return seen, fields, nil
}

func decodeInteger(raw json.RawMessage) (int, error) {
	if len(raw) == 0 || bytes.Equal(raw, []byte("null")) {
		return 0, gameapi.ErrInvalidAction
	}
	for index, character := range raw {
		if character == '-' && index == 0 {
			continue
		}
		if character < '0' || character > '9' {
			return 0, gameapi.ErrInvalidAction
		}
	}
	if raw[0] == '-' && len(raw) == 1 || len(raw) > 1 && raw[0] == '0' || len(raw) > 2 && raw[0] == '-' && raw[1] == '0' {
		return 0, gameapi.ErrInvalidAction
	}
	var value int
	if err := json.Unmarshal(raw, &value); err != nil {
		return 0, gameapi.ErrInvalidAction
	}
	return value, nil
}

func validActorID(actorID string) bool {
	if actorID == "" || len(actorID) > 128 || !utf8.ValidString(actorID) {
		return false
	}
	for _, character := range actorID {
		if unicode.IsControl(character) {
			return false
		}
	}
	return true
}

func validOptionalActor(actorID *string) bool { return actorID == nil || validActorID(*actorID) }

func actorForColor(state snapshotState, color Color) *string {
	if color == Black {
		return state.BlackUserID
	}
	if color == White {
		return state.WhiteUserID
	}
	return nil
}

func opposite(color Color) Color {
	if color == Black {
		return White
	}
	if color == White {
		return Black
	}
	return Empty
}

func colorNamed(name string) Color {
	if name == Black.String() {
		return Black
	}
	if name == White.String() {
		return White
	}
	return Empty
}

func (color Color) String() string {
	if color == Black {
		return "black"
	}
	if color == White {
		return "white"
	}
	return ""
}

func cloneSnapshot(snapshot gameapi.Snapshot) gameapi.Snapshot {
	return gameapi.Snapshot{Revision: snapshot.Revision, State: append(json.RawMessage(nil), snapshot.State...)}
}

func valueOrEmpty(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}
