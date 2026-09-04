// Package flightchess implements server-authoritative two-player Aeroplane Chess.
package flightchess

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
	GameID = "flight_chess"

	RollRequested = "flight_chess.roll.requested"
	RollAccepted  = "flight_chess.roll.accepted"
	MoveRequested = "flight_chess.move.requested"
	MoveAccepted  = "flight_chess.move.accepted"

	Black = "black"
	White = "white"

	StatusActive   = "active"
	StatusFinished = "finished"
	ResultGoal     = "goal"

	PhaseAwaitingRoll = "awaiting_roll"
	PhaseAwaitingMove = "awaiting_move"

	ZoneHangar   = "hangar"
	ZoneLaunch   = "launch"
	ZoneMain     = "main"
	ZoneHome     = "home"
	ZoneFinished = "finished"

	EffectNone         = "none"
	EffectJump         = "jump"
	EffectShortcut     = "shortcut"
	EffectJumpShortcut = "jump_shortcut"

	PieceCount    = 4
	MainCellCount = 52
	HomeCellCount = 6
)

var (
	ErrNotYourTurn       = errors.New("not_your_turn")
	ErrInvalidPhase      = errors.New("invalid_phase")
	ErrInvalidMove       = errors.New("invalid_move")
	ErrRandomUnavailable = errors.New("random_unavailable")
)

var startIndices = map[string]int{Black: 26, White: 0}

type Rules struct{}

func NewRules() *Rules { return &Rules{} }

func (*Rules) GameID() string { return GameID }

func (*Rules) PlayerLimit() int { return 2 }

func (*Rules) SingleActiveMatchPerUser() bool { return true }

type Piece struct {
	Zone  string `json:"zone"`
	Index int    `json:"index"`
}

type snapshotState struct {
	Status               string             `json:"status"`
	Phase                string             `json:"phase"`
	BlackUserID          *string            `json:"blackUserId"`
	WhiteUserID          *string            `json:"whiteUserId"`
	NextColor            string             `json:"nextColor"`
	Dice                 int                `json:"dice"`
	ConsecutiveSixes     int                `json:"consecutiveSixes"`
	SixMovedPieceIndices []int              `json:"sixMovedPieceIndices"`
	Pieces               map[string][]Piece `json:"pieces"`
	WinnerUserID         *string            `json:"winnerUserId"`
	Result               *string            `json:"result"`
}

type requestedMovePayload struct {
	PieceIndex int `json:"pieceIndex"`
}

type acceptedRollPayload struct {
	Color                 string `json:"color"`
	UserID                string `json:"userId"`
	Value                 int    `json:"value"`
	MovablePieceIndices   []int  `json:"movablePieceIndices"`
	PenalizedPieceIndices []int  `json:"penalizedPieceIndices"`
}

type acceptedMovePayload struct {
	Color                string `json:"color"`
	UserID               string `json:"userId"`
	PieceIndex           int    `json:"pieceIndex"`
	Roll                 int    `json:"roll"`
	From                 Piece  `json:"from"`
	To                   Piece  `json:"to"`
	Effect               string `json:"effect"`
	CapturedPieceIndices []int  `json:"capturedPieceIndices"`
}

type moveResolution struct {
	to     Piece
	effect string
}

func (rules *Rules) Rebuild(events []gameapi.Event) (gameapi.Snapshot, error) {
	snapshot, err := encodeSnapshot(0, initialState())
	if err != nil {
		return gameapi.Snapshot{}, gameapi.ErrInvalidSnapshot
	}
	for index, persisted := range events {
		if persisted.Revision != int64(index+1) || !validActorID(persisted.ActorID) {
			return gameapi.Snapshot{}, gameapi.ErrInvalidEvent
		}
		var produced gameapi.Event
		var next gameapi.Snapshot
		switch persisted.Type {
		case RollAccepted:
			accepted, decodeErr := decodeAcceptedRoll(persisted.Payload)
			if decodeErr != nil || accepted.UserID != persisted.ActorID {
				return gameapi.Snapshot{}, gameapi.ErrInvalidEvent
			}
			produced, next, err = rules.applyRollValue(snapshot, persisted.ActorID, accepted.Value)
		case MoveAccepted:
			accepted, decodeErr := decodeAcceptedMove(persisted.Payload)
			if decodeErr != nil || accepted.UserID != persisted.ActorID {
				return gameapi.Snapshot{}, gameapi.ErrInvalidEvent
			}
			payload, marshalErr := json.Marshal(requestedMovePayload{PieceIndex: accepted.PieceIndex})
			if marshalErr != nil {
				return gameapi.Snapshot{}, gameapi.ErrInvalidEvent
			}
			produced, next, err = rules.Apply(snapshot, persisted.ActorID, gameapi.Action{Type: MoveRequested, Payload: payload})
		default:
			return gameapi.Snapshot{}, gameapi.ErrInvalidEvent
		}
		if err != nil || produced.Revision != persisted.Revision || produced.Type != persisted.Type ||
			produced.ActorID != persisted.ActorID || !bytes.Equal(produced.Payload, persisted.Payload) {
			return gameapi.Snapshot{}, gameapi.ErrInvalidEvent
		}
		snapshot = next
	}
	return cloneSnapshot(snapshot), nil
}

// ApplyRandom is the only valid roll boundary. The caller owns and serializes
// access to randomSource; the accepted value is persisted in the returned event.
func (rules *Rules) ApplyRandom(snapshot gameapi.Snapshot, actorID string, action gameapi.Action, randomSource io.Reader) (gameapi.Event, gameapi.Snapshot, error) {
	if action.Type != RollRequested || !strictEmptyObject(action.Payload) || !validActorID(actorID) || randomSource == nil {
		return gameapi.Event{}, gameapi.Snapshot{}, gameapi.ErrInvalidAction
	}
	value, err := rollDie(randomSource)
	if err != nil {
		return gameapi.Event{}, gameapi.Snapshot{}, ErrRandomUnavailable
	}
	return rules.applyRollValue(snapshot, actorID, value)
}

func (rules *Rules) Apply(snapshot gameapi.Snapshot, actorID string, action gameapi.Action) (gameapi.Event, gameapi.Snapshot, error) {
	if action.Type != MoveRequested || !validActorID(actorID) {
		return gameapi.Event{}, gameapi.Snapshot{}, gameapi.ErrInvalidAction
	}
	pieceIndex, err := decodeRequestedMove(action.Payload)
	if err != nil {
		return gameapi.Event{}, gameapi.Snapshot{}, gameapi.ErrInvalidAction
	}
	state, snapshot, err := stateFromSnapshot(snapshot)
	if err != nil {
		return gameapi.Event{}, gameapi.Snapshot{}, err
	}
	if state.Status != StatusActive || state.Phase != PhaseAwaitingMove {
		return gameapi.Event{}, gameapi.Snapshot{}, ErrInvalidPhase
	}
	if err := bindAndValidateActor(&state, actorID); err != nil {
		return gameapi.Event{}, gameapi.Snapshot{}, err
	}
	if pieceIndex < 0 || pieceIndex >= PieceCount {
		return gameapi.Event{}, gameapi.Snapshot{}, ErrInvalidMove
	}
	from := state.Pieces[state.NextColor][pieceIndex]
	resolution, ok := resolveMove(state.NextColor, from, state.Dice)
	if !ok {
		return gameapi.Event{}, gameapi.Snapshot{}, ErrInvalidMove
	}
	color := state.NextColor
	roll := state.Dice
	state.Pieces[color][pieceIndex] = resolution.to
	captured := captureAt(&state, color, resolution.to)
	if roll == 6 {
		state.SixMovedPieceIndices = appendUnique(state.SixMovedPieceIndices, pieceIndex)
	} else {
		state.ConsecutiveSixes = 0
		state.SixMovedPieceIndices = []int{}
	}
	state.Dice = 0
	state.Phase = PhaseAwaitingRoll
	if allFinished(state.Pieces[color]) {
		winner := actorID
		result := ResultGoal
		state.Status = StatusFinished
		state.WinnerUserID = &winner
		state.Result = &result
	} else if roll != 6 {
		state.NextColor = opposite(color)
	}
	payload, err := json.Marshal(acceptedMovePayload{
		Color: color, UserID: actorID, PieceIndex: pieceIndex, Roll: roll,
		From: from, To: resolution.to, Effect: resolution.effect,
		CapturedPieceIndices: captured,
	})
	if err != nil {
		return gameapi.Event{}, gameapi.Snapshot{}, gameapi.ErrInvalidAction
	}
	revision := snapshot.Revision + 1
	next, err := encodeSnapshot(revision, state)
	if err != nil {
		return gameapi.Event{}, gameapi.Snapshot{}, gameapi.ErrInvalidSnapshot
	}
	return gameapi.Event{Revision: revision, Type: MoveAccepted, ActorID: actorID, Payload: payload}, next, nil
}

func (rules *Rules) applyRollValue(snapshot gameapi.Snapshot, actorID string, value int) (gameapi.Event, gameapi.Snapshot, error) {
	if value < 1 || value > 6 || !validActorID(actorID) {
		return gameapi.Event{}, gameapi.Snapshot{}, gameapi.ErrInvalidAction
	}
	state, snapshot, err := stateFromSnapshot(snapshot)
	if err != nil {
		return gameapi.Event{}, gameapi.Snapshot{}, err
	}
	if state.Status != StatusActive || state.Phase != PhaseAwaitingRoll {
		return gameapi.Event{}, gameapi.Snapshot{}, ErrInvalidPhase
	}
	if err := bindAndValidateActor(&state, actorID); err != nil {
		return gameapi.Event{}, gameapi.Snapshot{}, err
	}
	color := state.NextColor
	penalized := []int{}
	movable := []int{}
	if value == 6 {
		state.ConsecutiveSixes++
		if state.ConsecutiveSixes == 3 {
			penalized = append(penalized, state.SixMovedPieceIndices...)
			for _, index := range penalized {
				state.Pieces[color][index] = Piece{Zone: ZoneHangar, Index: index}
			}
			state.ConsecutiveSixes = 0
			state.SixMovedPieceIndices = []int{}
			state.NextColor = opposite(color)
		} else {
			movable = movablePieces(color, state.Pieces[color], value)
			if len(movable) != 0 {
				state.Phase = PhaseAwaitingMove
				state.Dice = value
			}
		}
	} else {
		state.ConsecutiveSixes = 0
		state.SixMovedPieceIndices = []int{}
		movable = movablePieces(color, state.Pieces[color], value)
		if len(movable) != 0 {
			state.Phase = PhaseAwaitingMove
			state.Dice = value
		} else {
			state.NextColor = opposite(color)
		}
	}
	payload, err := json.Marshal(acceptedRollPayload{
		Color: color, UserID: actorID, Value: value,
		MovablePieceIndices: movable, PenalizedPieceIndices: penalized,
	})
	if err != nil {
		return gameapi.Event{}, gameapi.Snapshot{}, gameapi.ErrInvalidAction
	}
	revision := snapshot.Revision + 1
	next, err := encodeSnapshot(revision, state)
	if err != nil {
		return gameapi.Event{}, gameapi.Snapshot{}, gameapi.ErrInvalidSnapshot
	}
	return gameapi.Event{Revision: revision, Type: RollAccepted, ActorID: actorID, Payload: payload}, next, nil
}

func stateFromSnapshot(snapshot gameapi.Snapshot) (snapshotState, gameapi.Snapshot, error) {
	if snapshot.Revision == 0 && len(snapshot.State) == 0 {
		encoded, err := encodeSnapshot(0, initialState())
		if err != nil {
			return snapshotState{}, gameapi.Snapshot{}, gameapi.ErrInvalidSnapshot
		}
		return initialState(), encoded, nil
	}
	state, err := decodeSnapshot(snapshot)
	return state, snapshot, err
}

func initialState() snapshotState {
	pieces := map[string][]Piece{Black: make([]Piece, PieceCount), White: make([]Piece, PieceCount)}
	for _, color := range []string{Black, White} {
		for index := 0; index < PieceCount; index++ {
			pieces[color][index] = Piece{Zone: ZoneHangar, Index: index}
		}
	}
	return snapshotState{
		Status: StatusActive, Phase: PhaseAwaitingRoll, NextColor: Black,
		SixMovedPieceIndices: []int{}, Pieces: pieces,
	}
}

func resolveMove(color string, piece Piece, roll int) (moveResolution, bool) {
	if roll < 1 || roll > 6 {
		return moveResolution{}, false
	}
	switch piece.Zone {
	case ZoneHangar:
		if roll != 6 {
			return moveResolution{}, false
		}
		return moveResolution{to: Piece{Zone: ZoneLaunch, Index: 0}, effect: EffectNone}, true
	case ZoneLaunch:
		return resolveMainProgress(color, roll)
	case ZoneMain:
		progress, ok := progressForIndex(color, piece.Index)
		if !ok {
			return moveResolution{}, false
		}
		return resolveProgress(color, progress+roll)
	case ZoneHome:
		target := piece.Index + roll
		if target < HomeCellCount {
			return moveResolution{to: Piece{Zone: ZoneHome, Index: target}, effect: EffectNone}, true
		}
		if target == HomeCellCount {
			return moveResolution{to: Piece{Zone: ZoneFinished, Index: 0}, effect: EffectNone}, true
		}
	}
	return moveResolution{}, false
}

func resolveProgress(color string, progress int) (moveResolution, bool) {
	if progress <= 0 {
		return moveResolution{}, false
	}
	if progress <= 50 {
		return resolveMainProgress(color, progress)
	}
	if progress <= 50+HomeCellCount {
		return moveResolution{to: Piece{Zone: ZoneHome, Index: progress - 51}, effect: EffectNone}, true
	}
	if progress == 51+HomeCellCount {
		return moveResolution{to: Piece{Zone: ZoneFinished, Index: 0}, effect: EffectNone}, true
	}
	return moveResolution{}, false
}

func resolveMainProgress(color string, progress int) (moveResolution, bool) {
	if progress < 1 || progress > 50 {
		return resolveProgress(color, progress)
	}
	effect := EffectNone
	resolved := progress
	if resolved == 18 {
		resolved = 30
		effect = EffectShortcut
	} else if resolved%4 == 2 && resolved < 50 {
		resolved += 4
		effect = EffectJump
		if resolved == 18 {
			resolved = 30
			effect = EffectJumpShortcut
		}
	}
	return moveResolution{to: Piece{Zone: ZoneMain, Index: indexForProgress(color, resolved)}, effect: effect}, true
}

func movablePieces(color string, pieces []Piece, roll int) []int {
	result := make([]int, 0, PieceCount)
	for index, piece := range pieces {
		if _, ok := resolveMove(color, piece, roll); ok {
			result = append(result, index)
		}
	}
	return result
}

func captureAt(state *snapshotState, color string, destination Piece) []int {
	if destination.Zone != ZoneMain {
		return []int{}
	}
	opponent := opposite(color)
	captured := make([]int, 0, PieceCount)
	for index, piece := range state.Pieces[opponent] {
		if piece == destination {
			state.Pieces[opponent][index] = Piece{Zone: ZoneHangar, Index: index}
			captured = append(captured, index)
		}
	}
	return captured
}

func progressForIndex(color string, index int) (int, bool) {
	start, ok := startIndices[color]
	if !ok || index < 0 || index >= MainCellCount {
		return 0, false
	}
	progress := (index-start+MainCellCount)%MainCellCount + 1
	return progress, progress <= 50
}

func indexForProgress(color string, progress int) int {
	return (startIndices[color] + progress - 1) % MainCellCount
}

func bindAndValidateActor(state *snapshotState, actorID string) error {
	current := &state.BlackUserID
	other := state.WhiteUserID
	if state.NextColor == White {
		current = &state.WhiteUserID
		other = state.BlackUserID
	}
	if *current != nil {
		if **current != actorID {
			return ErrNotYourTurn
		}
		return nil
	}
	if other != nil && *other == actorID {
		return ErrNotYourTurn
	}
	value := actorID
	*current = &value
	return nil
}

func opposite(color string) string {
	if color == Black {
		return White
	}
	return Black
}

func appendUnique(values []int, value int) []int {
	for _, existing := range values {
		if existing == value {
			return values
		}
	}
	return append(values, value)
}

func allFinished(pieces []Piece) bool {
	if len(pieces) != PieceCount {
		return false
	}
	for _, piece := range pieces {
		if piece.Zone != ZoneFinished {
			return false
		}
	}
	return true
}

func rollDie(randomSource io.Reader) (int, error) {
	var sample [1]byte
	for attempts := 0; attempts < 128; attempts++ {
		if _, err := io.ReadFull(randomSource, sample[:]); err != nil {
			return 0, err
		}
		if sample[0] < 252 {
			return int(sample[0]%6) + 1, nil
		}
	}
	return 0, ErrRandomUnavailable
}

func decodeRequestedMove(payload json.RawMessage) (int, error) {
	fields, err := strictObject(payload, map[string]struct{}{"pieceIndex": {}})
	if err != nil || len(fields) != 1 {
		return 0, gameapi.ErrInvalidAction
	}
	var index int
	if json.Unmarshal(fields["pieceIndex"], &index) != nil || index < 0 || index >= PieceCount || !strictInteger(fields["pieceIndex"]) {
		return 0, gameapi.ErrInvalidAction
	}
	return index, nil
}

func decodeAcceptedRoll(payload json.RawMessage) (acceptedRollPayload, error) {
	allowed := map[string]struct{}{"color": {}, "userId": {}, "value": {}, "movablePieceIndices": {}, "penalizedPieceIndices": {}}
	fields, err := strictObject(payload, allowed)
	if err != nil || len(fields) != len(allowed) {
		return acceptedRollPayload{}, gameapi.ErrInvalidEvent
	}
	var result acceptedRollPayload
	if json.Unmarshal(payload, &result) != nil || result.Color != Black && result.Color != White || !validActorID(result.UserID) || result.Value < 1 || result.Value > 6 ||
		!validIndices(result.MovablePieceIndices) || !validIndices(result.PenalizedPieceIndices) {
		return acceptedRollPayload{}, gameapi.ErrInvalidEvent
	}
	return result, nil
}

func decodeAcceptedMove(payload json.RawMessage) (acceptedMovePayload, error) {
	allowed := map[string]struct{}{"color": {}, "userId": {}, "pieceIndex": {}, "roll": {}, "from": {}, "to": {}, "effect": {}, "capturedPieceIndices": {}}
	fields, err := strictObject(payload, allowed)
	if err != nil || len(fields) != len(allowed) {
		return acceptedMovePayload{}, gameapi.ErrInvalidEvent
	}
	var result acceptedMovePayload
	if json.Unmarshal(payload, &result) != nil || result.Color != Black && result.Color != White || !validActorID(result.UserID) ||
		result.PieceIndex < 0 || result.PieceIndex >= PieceCount || result.Roll < 1 || result.Roll > 6 ||
		!validPiece(result.From, result.PieceIndex) || !validPiece(result.To, result.PieceIndex) ||
		result.Effect != EffectNone && result.Effect != EffectJump && result.Effect != EffectShortcut && result.Effect != EffectJumpShortcut ||
		!validIndices(result.CapturedPieceIndices) {
		return acceptedMovePayload{}, gameapi.ErrInvalidEvent
	}
	return result, nil
}

func decodeSnapshot(snapshot gameapi.Snapshot) (snapshotState, error) {
	if snapshot.Revision < 0 || len(snapshot.State) == 0 || len(snapshot.State) > 8192 || !utf8.Valid(snapshot.State) {
		return snapshotState{}, gameapi.ErrInvalidSnapshot
	}
	allowed := map[string]struct{}{
		"status": {}, "phase": {}, "blackUserId": {}, "whiteUserId": {}, "nextColor": {}, "dice": {},
		"consecutiveSixes": {}, "sixMovedPieceIndices": {}, "pieces": {}, "winnerUserId": {}, "result": {},
	}
	fields, err := strictObject(snapshot.State, allowed)
	if err != nil || len(fields) != len(allowed) {
		return snapshotState{}, gameapi.ErrInvalidSnapshot
	}
	var state snapshotState
	if json.Unmarshal(snapshot.State, &state) != nil || !validState(state) {
		return snapshotState{}, gameapi.ErrInvalidSnapshot
	}
	return state, nil
}

func validState(state snapshotState) bool {
	if state.NextColor != Black && state.NextColor != White || !validOptionalActor(state.BlackUserID) || !validOptionalActor(state.WhiteUserID) ||
		state.BlackUserID != nil && state.WhiteUserID != nil && *state.BlackUserID == *state.WhiteUserID ||
		state.ConsecutiveSixes < 0 || state.ConsecutiveSixes > 2 || !validIndices(state.SixMovedPieceIndices) || len(state.Pieces) != 2 {
		return false
	}
	for _, color := range []string{Black, White} {
		pieces, ok := state.Pieces[color]
		if !ok || len(pieces) != PieceCount {
			return false
		}
		for index, piece := range pieces {
			if !validPiece(piece, index) {
				return false
			}
			if piece.Zone == ZoneMain {
				if _, reachable := progressForIndex(color, piece.Index); !reachable {
					return false
				}
			}
		}
	}
	if state.Phase == PhaseAwaitingRoll {
		if state.Dice != 0 {
			return false
		}
	} else if state.Phase == PhaseAwaitingMove {
		if state.Dice < 1 || state.Dice > 6 || len(movablePieces(state.NextColor, state.Pieces[state.NextColor], state.Dice)) == 0 {
			return false
		}
	} else {
		return false
	}
	if state.Status == StatusActive {
		return state.Result == nil && state.WinnerUserID == nil && !allFinished(state.Pieces[Black]) && !allFinished(state.Pieces[White])
	}
	if state.Status != StatusFinished || state.Result == nil || *state.Result != ResultGoal || state.WinnerUserID == nil {
		return false
	}
	return state.Phase == PhaseAwaitingRoll && (*state.WinnerUserID == valueOrEmpty(state.BlackUserID) && allFinished(state.Pieces[Black]) ||
		*state.WinnerUserID == valueOrEmpty(state.WhiteUserID) && allFinished(state.Pieces[White]))
}

func validPiece(piece Piece, slot int) bool {
	switch piece.Zone {
	case ZoneHangar:
		return piece.Index == slot
	case ZoneLaunch, ZoneFinished:
		return piece.Index == 0
	case ZoneMain:
		return piece.Index >= 0 && piece.Index < MainCellCount
	case ZoneHome:
		return piece.Index >= 0 && piece.Index < HomeCellCount
	default:
		return false
	}
}

func validIndices(indices []int) bool {
	seen := map[int]bool{}
	for _, index := range indices {
		if index < 0 || index >= PieceCount || seen[index] {
			return false
		}
		seen[index] = true
	}
	return true
}

func encodeSnapshot(revision int64, state snapshotState) (gameapi.Snapshot, error) {
	if revision < 0 || !validState(state) {
		return gameapi.Snapshot{}, gameapi.ErrInvalidSnapshot
	}
	encoded, err := json.Marshal(state)
	if err != nil {
		return gameapi.Snapshot{}, err
	}
	return gameapi.Snapshot{Revision: revision, State: encoded}, nil
}

func strictObject(data []byte, allowed map[string]struct{}) (map[string]json.RawMessage, error) {
	if len(data) == 0 || len(data) > 8192 || !utf8.Valid(data) {
		return nil, gameapi.ErrInvalidAction
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	token, err := decoder.Token()
	if err != nil || token != json.Delim('{') {
		return nil, gameapi.ErrInvalidAction
	}
	fields := make(map[string]json.RawMessage, len(allowed))
	for decoder.More() {
		keyToken, err := decoder.Token()
		key, ok := keyToken.(string)
		if err != nil || !ok {
			return nil, gameapi.ErrInvalidAction
		}
		if _, ok := allowed[key]; !ok {
			return nil, gameapi.ErrInvalidAction
		}
		if _, duplicate := fields[key]; duplicate {
			return nil, gameapi.ErrInvalidAction
		}
		var raw json.RawMessage
		if decoder.Decode(&raw) != nil {
			return nil, gameapi.ErrInvalidAction
		}
		fields[key] = append(json.RawMessage(nil), raw...)
	}
	if token, err = decoder.Token(); err != nil || token != json.Delim('}') {
		return nil, gameapi.ErrInvalidAction
	}
	if _, err = decoder.Token(); !errors.Is(err, io.EOF) {
		return nil, gameapi.ErrInvalidAction
	}
	return fields, nil
}

func strictEmptyObject(payload []byte) bool {
	fields, err := strictObject(payload, map[string]struct{}{})
	return err == nil && len(fields) == 0
}

func strictInteger(raw []byte) bool {
	if len(raw) == 0 {
		return false
	}
	for index, value := range raw {
		if value == '-' && index == 0 {
			continue
		}
		if value < '0' || value > '9' {
			return false
		}
	}
	return !(len(raw) > 1 && raw[0] == '0') && !(len(raw) > 2 && raw[0] == '-' && raw[1] == '0')
}

func validActorID(value string) bool {
	if value == "" || len(value) > 128 || !utf8.ValidString(value) {
		return false
	}
	for _, character := range value {
		if unicode.IsControl(character) {
			return false
		}
	}
	return true
}

func validOptionalActor(value *string) bool { return value == nil || validActorID(*value) }

func valueOrEmpty(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}

func cloneSnapshot(snapshot gameapi.Snapshot) gameapi.Snapshot {
	return gameapi.Snapshot{Revision: snapshot.Revision, State: append(json.RawMessage(nil), snapshot.State...)}
}
