package chinesecheckers

import (
	"encoding/json"
	"errors"
	"reflect"
	"testing"

	"me.zqydev/gamebox/server/internal/games/gameapi"
)

const (
	blackActor = "user-black"
	whiteActor = "user-white"
)

func TestBoardGeometryHasStandardStarAndCamps(t *testing.T) {
	if got := len(boardPoints); got != BoardCells {
		t.Fatalf("len(boardPoints) = %d, want %d", got, BoardCells)
	}
	if got := campIndices(Black); !reflect.DeepEqual(got, []int{111, 112, 113, 114, 115, 116, 117, 118, 119, 120}) {
		t.Fatalf("black target camp = %v", got)
	}
	if got := campIndices(White); !reflect.DeepEqual(got, []int{0, 1, 2, 3, 4, 5, 6, 7, 8, 9}) {
		t.Fatalf("white target camp = %v", got)
	}
	neutral := 0
	for index := 0; index < BoardCells; index++ {
		if isNeutralCamp(index) {
			neutral++
		}
	}
	if neutral != 40 {
		t.Fatalf("neutral camp holes = %d, want 40", neutral)
	}
}

func TestApplyMovesPieceAndAlternatesTurn(t *testing.T) {
	rules := NewRules()
	event, snapshot, err := rules.Apply(gameapi.Snapshot{}, blackActor, moveAction(6, 14))
	if err != nil {
		t.Fatalf("Apply() error = %v", err)
	}
	if event.Type != MoveAccepted || event.Revision != 1 || event.ActorID != blackActor {
		t.Fatalf("event = %+v", event)
	}
	state := mustDecodeState(t, snapshot)
	if state.Board[6] != uint8(Empty) || state.Board[14] != uint8(Black) {
		t.Fatalf("move was not applied: source=%d destination=%d", state.Board[6], state.Board[14])
	}
	if state.BlackUserID == nil || *state.BlackUserID != blackActor || state.WhiteUserID != nil || state.NextColor != White.String() {
		t.Fatalf("unexpected turn binding: %+v", state)
	}

	_, _, err = rules.Apply(snapshot, blackActor, moveAction(111, 102))
	if !errors.Is(err, ErrNotYourTurn) {
		t.Fatalf("second black move error = %v, want %v", err, ErrNotYourTurn)
	}
	_, next, err := rules.Apply(snapshot, whiteActor, moveAction(111, 102))
	if err != nil {
		t.Fatalf("white Apply() error = %v", err)
	}
	state = mustDecodeState(t, next)
	if state.WhiteUserID == nil || *state.WhiteUserID != whiteActor || state.NextColor != Black.String() {
		t.Fatalf("unexpected white binding: %+v", state)
	}
}

func TestValidatePathSupportsTurningMultiJump(t *testing.T) {
	var cells [BoardCells]uint8
	// 56 -> 58 jumps over 57, then 58 -> 79 jumps over 68. The
	// second jump changes direction on the hexagonal lattice.
	cells[56] = uint8(Black)
	cells[57] = uint8(White)
	cells[68] = uint8(White)
	if !validMovePath(cells, Black, []int{56, 58, 79}) {
		t.Fatal("turning multi-jump should be legal")
	}
	if validMovePath(cells, Black, []int{56, 58, 59}) {
		t.Fatal("a jump chain must not mix in a step")
	}
}

func TestValidatePathRejectsRuleBoundaryViolations(t *testing.T) {
	tests := []struct {
		name  string
		cells [BoardCells]uint8
		path  []int
	}{
		{name: "empty source", path: []int{56, 57}},
		{name: "repeated hole", cells: boardWith(56, Black, 57, White), path: []int{56, 58, 56}},
		{name: "occupied destination", cells: boardWith(56, Black, 57, White), path: []int{56, 57}},
		{name: "jump without midpoint", cells: boardWith(56, Black), path: []int{56, 58}},
		{name: "ends in neutral camp", cells: boardWith(56, Black), path: []int{56, 46}},
		{name: "leaves target camp", cells: boardWith(111, Black), path: []int{111, 102}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if validMovePath(test.cells, Black, test.path) {
				t.Fatalf("validMovePath(%v) = true", test.path)
			}
		})
	}
}

func TestApplyCompletesTargetCamp(t *testing.T) {
	state := snapshotState{Status: statusActive, NextColor: Black.String()}
	for _, index := range []int{112, 113, 114, 115, 116, 117, 118, 119, 120, 102} {
		state.Board[index] = uint8(Black)
	}
	for _, index := range []int{23, 24, 25, 26, 27, 28, 29, 30, 31, 32} {
		state.Board[index] = uint8(White)
	}
	state.BlackUserID = stringPointer(blackActor)
	state.WhiteUserID = stringPointer(whiteActor)
	snapshot := encodeSnapshotForTest(t, 20, state)

	event, next, err := NewRules().Apply(snapshot, blackActor, moveAction(102, 111))
	if err != nil {
		t.Fatalf("Apply() error = %v", err)
	}
	if event.Revision != 21 {
		t.Fatalf("revision = %d, want 21", event.Revision)
	}
	got := mustDecodeState(t, next)
	if got.Status != statusFinished || got.Result == nil || *got.Result != resultGoal || got.WinnerUserID == nil || *got.WinnerUserID != blackActor {
		t.Fatalf("finished state = %+v", got)
	}
}

func TestRebuildRejectsTamperedAcceptedPath(t *testing.T) {
	rules := NewRules()
	event, _, err := rules.Apply(gameapi.Snapshot{}, blackActor, moveAction(6, 14))
	if err != nil {
		t.Fatal(err)
	}
	event.Payload = json.RawMessage(`{"path":[6,13],"color":"black","userId":"user-black"}`)
	if _, err := rules.Rebuild([]gameapi.Event{event}); !errors.Is(err, gameapi.ErrInvalidEvent) {
		t.Fatalf("Rebuild() error = %v, want invalid event", err)
	}
}

func TestApplyRejectsMalformedPayloadWithoutLeakingIt(t *testing.T) {
	secret := "payload-canary"
	_, _, err := NewRules().Apply(gameapi.Snapshot{}, blackActor, gameapi.Action{
		Type:    MoveRequested,
		Payload: json.RawMessage(`{"path":[6,14],"secret":"` + secret + `"}`),
	})
	if !errors.Is(err, gameapi.ErrInvalidAction) || err.Error() == secret {
		t.Fatalf("Apply() error = %v", err)
	}
}

func moveAction(path ...int) gameapi.Action {
	payload, _ := json.Marshal(movePayload{Path: path})
	return gameapi.Action{Type: MoveRequested, Payload: payload}
}

func boardWith(entries ...any) [BoardCells]uint8 {
	var cells [BoardCells]uint8
	for index := 0; index < len(entries); index += 2 {
		cells[entries[index].(int)] = uint8(entries[index+1].(Color))
	}
	return cells
}

func mustDecodeState(t *testing.T, snapshot gameapi.Snapshot) snapshotState {
	t.Helper()
	state, err := decodeSnapshot(snapshot)
	if err != nil {
		t.Fatalf("decodeSnapshot() error = %v", err)
	}
	return state
}

func encodeSnapshotForTest(t *testing.T, revision int64, state snapshotState) gameapi.Snapshot {
	t.Helper()
	encoded, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	return gameapi.Snapshot{Revision: revision, State: encoded}
}

func stringPointer(value string) *string { return &value }
