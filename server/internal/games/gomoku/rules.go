package gomoku

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
	GameID        = "gomoku"
	MoveRequested = "gomoku.move.requested"
	MoveAccepted  = "gomoku.move.accepted"

	statusActive   = "active"
	statusFinished = "finished"
	resultFive     = "five"
	resultDraw     = "draw"
)

var (
	ErrNotYourTurn  = errors.New("not_your_turn")
	ErrCellOccupied = errors.New("cell_occupied")
)

// Rules has no fields by design: every match state is supplied through the
// opaque snapshot, so instances are safe to use concurrently.
type Rules struct{}

func NewRules() *Rules { return &Rules{} }

func (*Rules) GameID() string { return GameID }

func (*Rules) PlayerLimit() int { return 2 }

func (*Rules) SingleActiveMatchPerUser() bool { return true }

type snapshotState struct {
	Status       string            `json:"status"`
	Board        [boardCells]uint8 `json:"board"`
	BoardSize    int               `json:"boardSize"`
	BlackUserID  *string           `json:"blackUserId"`
	WhiteUserID  *string           `json:"whiteUserId"`
	NextColor    string            `json:"nextColor"`
	WinnerUserID *string           `json:"winnerUserId"`
	Result       *string           `json:"result"`
}

type movePayload struct {
	X int `json:"x"`
	Y int `json:"y"`
}

type acceptedMovePayload struct {
	X      int    `json:"x"`
	Y      int    `json:"y"`
	Color  string `json:"color"`
	UserID string `json:"userId"`
}

func (*Rules) Rebuild(events []gameapi.Event) (gameapi.Snapshot, error) {
	snapshot, err := initialSnapshot()
	if err != nil {
		return gameapi.Snapshot{}, gameapi.ErrInvalidSnapshot
	}
	for index := range events {
		event := events[index]
		if event.Revision != int64(index+1) || event.Type != MoveAccepted || !validActorID(event.ActorID) {
			return gameapi.Snapshot{}, gameapi.ErrInvalidEvent
		}
		point, color, userID, err := decodeAcceptedMove(event.Payload)
		if err != nil {
			return gameapi.Snapshot{}, gameapi.ErrInvalidEvent
		}
		state, stateErr := decodeSnapshot(snapshot)
		if stateErr != nil || color != state.NextColor || userID != event.ActorID {
			return gameapi.Snapshot{}, gameapi.ErrInvalidEvent
		}
		produced, next, err := applyMove(snapshot, event.ActorID, point)
		if err != nil || produced.Revision != event.Revision || produced.ActorID != event.ActorID || produced.Type != event.Type || !bytes.Equal(produced.Payload, event.Payload) {
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
	point, err := decodeMove(action.Payload)
	if err != nil || !point.valid() {
		return gameapi.Event{}, gameapi.Snapshot{}, gameapi.ErrInvalidAction
	}
	if len(snapshot.State) == 0 && snapshot.Revision == 0 {
		snapshot, err = initialSnapshot()
		if err != nil {
			return gameapi.Event{}, gameapi.Snapshot{}, gameapi.ErrInvalidSnapshot
		}
	}
	if snapshot.Revision < 0 {
		return gameapi.Event{}, gameapi.Snapshot{}, gameapi.ErrInvalidSnapshot
	}
	return applyMove(snapshot, actorID, point)
}

func applyMove(snapshot gameapi.Snapshot, actorID string, point Point) (gameapi.Event, gameapi.Snapshot, error) {
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

	stateBoard := board{cells: state.Board, count: occupiedCells(state.Board)}
	if stateBoard.occupied(point) {
		return gameapi.Event{}, gameapi.Snapshot{}, ErrCellOccupied
	}
	if !stateBoard.place(point, color) {
		return gameapi.Event{}, gameapi.Snapshot{}, gameapi.ErrInvalidAction
	}
	state.Board = stateBoard.cells
	state.NextColor = opposite(color).String()

	if stateBoard.wins(point, color) {
		winner := actorID
		result := resultFive
		state.Status = statusFinished
		state.Result = &result
		state.WinnerUserID = &winner
	} else if stateBoard.count == boardCells {
		result := resultDraw
		state.Status = statusFinished
		state.Result = &result
		state.WinnerUserID = nil
	}

	payload, err := json.Marshal(acceptedMovePayload{X: point.X, Y: point.Y, Color: color.String(), UserID: actorID})
	if err != nil {
		return gameapi.Event{}, gameapi.Snapshot{}, gameapi.ErrInvalidAction
	}
	encodedState, err := json.Marshal(state)
	if err != nil {
		return gameapi.Event{}, gameapi.Snapshot{}, gameapi.ErrInvalidSnapshot
	}
	revision := snapshot.Revision + 1
	return gameapi.Event{
			Revision: revision,
			Type:     MoveAccepted,
			ActorID:  actorID,
			Payload:  append(json.RawMessage(nil), payload...),
		}, gameapi.Snapshot{
			Revision: revision,
			State:    append(json.RawMessage(nil), encodedState...),
		}, nil
}

func initialSnapshot() (gameapi.Snapshot, error) {
	state := snapshotState{
		BoardSize: BoardSize,
		NextColor: Black.String(),
		Status:    statusActive,
	}
	encoded, err := json.Marshal(state)
	if err != nil {
		return gameapi.Snapshot{}, err
	}
	return gameapi.Snapshot{State: append(json.RawMessage(nil), encoded...)}, nil
}

func decodeMove(payload json.RawMessage) (Point, error) {
	if len(payload) > 1024 || !utf8.Valid(payload) {
		return Point{}, gameapi.ErrInvalidAction
	}
	seen, fields, err := decodeObject(payload, map[string]struct{}{"x": {}, "y": {}})
	if err != nil || !seen["x"] || !seen["y"] {
		return Point{}, gameapi.ErrInvalidAction
	}
	x, err := decodeInteger(fields["x"])
	if err != nil {
		return Point{}, gameapi.ErrInvalidAction
	}
	y, err := decodeInteger(fields["y"])
	if err != nil {
		return Point{}, gameapi.ErrInvalidAction
	}
	return Point{X: x, Y: y}, nil
}

func decodeAcceptedMove(payload json.RawMessage) (Point, string, string, error) {
	if len(payload) > 1024 || !utf8.Valid(payload) {
		return Point{}, "", "", gameapi.ErrInvalidEvent
	}
	seen, fields, err := decodeObject(payload, map[string]struct{}{"x": {}, "y": {}, "color": {}, "userId": {}})
	if err != nil || !seen["x"] || !seen["y"] || !seen["color"] || !seen["userId"] {
		return Point{}, "", "", gameapi.ErrInvalidEvent
	}
	x, err := decodeInteger(fields["x"])
	if err != nil {
		return Point{}, "", "", gameapi.ErrInvalidEvent
	}
	y, err := decodeInteger(fields["y"])
	if err != nil {
		return Point{}, "", "", gameapi.ErrInvalidEvent
	}
	var color, userID string
	if err := json.Unmarshal(fields["color"], &color); err != nil || colorNamed(color) == Empty {
		return Point{}, "", "", gameapi.ErrInvalidEvent
	}
	if err := json.Unmarshal(fields["userId"], &userID); err != nil || !validActorID(userID) {
		return Point{}, "", "", gameapi.ErrInvalidEvent
	}
	point := Point{X: x, Y: y}
	if !point.valid() {
		return Point{}, "", "", gameapi.ErrInvalidEvent
	}
	return point, color, userID, nil
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

func decodeSnapshot(snapshot gameapi.Snapshot) (snapshotState, error) {
	if snapshot.Revision < 0 || len(snapshot.State) > 8192 || !utf8.Valid(snapshot.State) {
		return snapshotState{}, gameapi.ErrInvalidSnapshot
	}
	allowed := map[string]struct{}{
		"status": {}, "board": {}, "boardSize": {}, "blackUserId": {},
		"whiteUserId": {}, "nextColor": {}, "winnerUserId": {}, "result": {},
	}
	seen, fields, err := decodeObject(snapshot.State, allowed)
	if err != nil || len(seen) != len(allowed) {
		return snapshotState{}, gameapi.ErrInvalidSnapshot
	}
	var rawBoard []int
	if err := json.Unmarshal(fields["board"], &rawBoard); err != nil || len(rawBoard) != boardCells {
		return snapshotState{}, gameapi.ErrInvalidSnapshot
	}
	for _, cell := range rawBoard {
		if cell < int(Empty) || cell > int(White) {
			return snapshotState{}, gameapi.ErrInvalidSnapshot
		}
	}
	var state snapshotState
	decoder := json.NewDecoder(bytes.NewReader(snapshot.State))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&state); err != nil {
		return snapshotState{}, gameapi.ErrInvalidSnapshot
	}
	if state.BoardSize != BoardSize {
		return snapshotState{}, gameapi.ErrInvalidSnapshot
	}
	blackCount, whiteCount := 0, 0
	for _, cell := range state.Board {
		switch Color(cell) {
		case Empty:
		case Black:
			blackCount++
		case White:
			whiteCount++
		default:
			return snapshotState{}, gameapi.ErrInvalidSnapshot
		}
	}
	moveCount := blackCount + whiteCount
	if int64(moveCount) != snapshot.Revision || blackCount < whiteCount || blackCount > whiteCount+1 {
		return snapshotState{}, gameapi.ErrInvalidSnapshot
	}
	if !validOptionalActor(state.BlackUserID) || !validOptionalActor(state.WhiteUserID) {
		return snapshotState{}, gameapi.ErrInvalidSnapshot
	}
	if state.BlackUserID != nil && state.WhiteUserID != nil && *state.BlackUserID == *state.WhiteUserID {
		return snapshotState{}, gameapi.ErrInvalidSnapshot
	}
	if blackCount > 0 && state.BlackUserID == nil || whiteCount > 0 && state.WhiteUserID == nil {
		return snapshotState{}, gameapi.ErrInvalidSnapshot
	}
	expectedColor := Black
	if blackCount > whiteCount {
		expectedColor = White
	}
	if state.NextColor != expectedColor.String() {
		return snapshotState{}, gameapi.ErrInvalidSnapshot
	}
	switch state.Status {
	case statusActive:
		if state.Result != nil || state.WinnerUserID != nil || moveCount == boardCells {
			return snapshotState{}, gameapi.ErrInvalidSnapshot
		}
	case statusFinished:
		if state.Result == nil {
			return snapshotState{}, gameapi.ErrInvalidSnapshot
		}
		switch *state.Result {
		case resultFive:
			if state.WinnerUserID == nil || (*state.WinnerUserID != valueOrEmpty(state.BlackUserID) && *state.WinnerUserID != valueOrEmpty(state.WhiteUserID)) {
				return snapshotState{}, gameapi.ErrInvalidSnapshot
			}
			if *state.WinnerUserID == valueOrEmpty(state.BlackUserID) && blackCount != whiteCount+1 || *state.WinnerUserID == valueOrEmpty(state.WhiteUserID) && blackCount != whiteCount {
				return snapshotState{}, gameapi.ErrInvalidSnapshot
			}
		case resultDraw:
			if moveCount != boardCells || state.WinnerUserID != nil {
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

func validOptionalActor(actorID *string) bool {
	return actorID == nil || validActorID(*actorID)
}

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

func occupiedCells(cells [boardCells]uint8) int {
	count := 0
	for _, cell := range cells {
		if cell != uint8(Empty) {
			count++
		}
	}
	return count
}
