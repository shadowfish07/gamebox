package flightchess

import (
	"bytes"
	"encoding/json"
	"errors"
	"testing"

	"me.zqydev/gamebox/server/internal/games/gameapi"
)

const (
	blackID = "00000000-0000-4000-8000-000000000001"
	whiteID = "00000000-0000-4000-8000-000000000002"
)

func TestInitialSnapshotRequiresBlackToRoll(t *testing.T) {
	snapshot, err := NewRules().Rebuild(nil)
	if err != nil {
		t.Fatal(err)
	}
	state := decodeStateForTest(t, snapshot)
	if snapshot.Revision != 0 || state.Status != StatusActive || state.Phase != PhaseAwaitingRoll || state.NextColor != Black || state.Dice != 0 {
		t.Fatalf("unexpected initial state: %#v", state)
	}
	for _, color := range []string{Black, White} {
		if len(state.Pieces[color]) != PieceCount {
			t.Fatalf("%s piece count = %d", color, len(state.Pieces[color]))
		}
		for index, piece := range state.Pieces[color] {
			if piece.Zone != ZoneHangar || piece.Index != index {
				t.Fatalf("%s piece %d = %#v", color, index, piece)
			}
		}
	}
}

func TestRollSixLaunchesPlaneAndKeepsTurn(t *testing.T) {
	rules := NewRules()
	rolled, afterRoll, err := rules.ApplyRandom(gameapi.Snapshot{}, blackID, gameapi.Action{Type: RollRequested, Payload: json.RawMessage(`{}`)}, bytes.NewReader([]byte{5}))
	if err != nil {
		t.Fatal(err)
	}
	if rolled.Type != RollAccepted || string(rolled.Payload) != `{"color":"black","userId":"00000000-0000-4000-8000-000000000001","value":6,"movablePieceIndices":[0,1,2,3],"penalizedPieceIndices":[]}` {
		t.Fatalf("unexpected roll event: %s", rolled.Payload)
	}
	state := decodeStateForTest(t, afterRoll)
	if state.Phase != PhaseAwaitingMove || state.Dice != 6 || state.ConsecutiveSixes != 1 || state.NextColor != Black {
		t.Fatalf("unexpected rolled state: %#v", state)
	}

	moved, afterMove, err := rules.Apply(afterRoll, blackID, gameapi.Action{Type: MoveRequested, Payload: json.RawMessage(`{"pieceIndex":2}`)})
	if err != nil {
		t.Fatal(err)
	}
	if moved.Type != MoveAccepted {
		t.Fatalf("event type = %q", moved.Type)
	}
	state = decodeStateForTest(t, afterMove)
	if state.Pieces[Black][2] != (Piece{Zone: ZoneLaunch, Index: 0}) || state.Phase != PhaseAwaitingRoll || state.NextColor != Black || state.Dice != 0 {
		t.Fatalf("unexpected launched state: %#v", state)
	}
}

func TestNonSixWithoutMovablePlanesPassesAutomatically(t *testing.T) {
	event, snapshot, err := NewRules().ApplyRandom(gameapi.Snapshot{}, blackID, gameapi.Action{Type: RollRequested, Payload: json.RawMessage(`{}`)}, bytes.NewReader([]byte{2}))
	if err != nil {
		t.Fatal(err)
	}
	state := decodeStateForTest(t, snapshot)
	if event.Type != RollAccepted || state.Phase != PhaseAwaitingRoll || state.NextColor != White || state.Dice != 0 {
		t.Fatalf("roll did not pass: event=%s state=%#v", event.Payload, state)
	}
}

func TestMoveResolvesColorJumpShortcutStackAndCapture(t *testing.T) {
	rules := NewRules()
	state := initialState()
	state.BlackUserID = stringPointer(blackID)
	state.WhiteUserID = stringPointer(whiteID)
	state.Phase = PhaseAwaitingMove
	state.Dice = 4
	state.Pieces[Black][0] = Piece{Zone: ZoneMain, Index: 13}
	state.Pieces[Black][1] = Piece{Zone: ZoneMain, Index: 35}
	state.Pieces[White][0] = Piece{Zone: ZoneMain, Index: 3}
	state.Pieces[White][1] = Piece{Zone: ZoneMain, Index: 3}
	snapshot := encodeStateForTest(t, 7, state)

	event, next, err := rules.Apply(snapshot, blackID, gameapi.Action{Type: MoveRequested, Payload: json.RawMessage(`{"pieceIndex":1}`)})
	if err != nil {
		t.Fatal(err)
	}
	var payload acceptedMovePayload
	if err := json.Unmarshal(event.Payload, &payload); err != nil {
		t.Fatal(err)
	}
	if payload.Effect != EffectJumpShortcut || payload.To != (Piece{Zone: ZoneMain, Index: 3}) || len(payload.CapturedPieceIndices) != 2 {
		t.Fatalf("unexpected move payload: %#v", payload)
	}
	state = decodeStateForTest(t, next)
	if state.Pieces[Black][1] != payload.To || state.Pieces[White][0].Zone != ZoneHangar || state.Pieces[White][1].Zone != ZoneHangar || state.NextColor != White {
		t.Fatalf("unexpected resolved state: %#v", state)
	}
}

func TestExactFinishRejectsOvershootAndFourthPlaneWins(t *testing.T) {
	rules := NewRules()
	state := initialState()
	state.BlackUserID = stringPointer(blackID)
	state.WhiteUserID = stringPointer(whiteID)
	state.Phase = PhaseAwaitingMove
	state.Dice = 2
	state.Pieces[Black][0] = Piece{Zone: ZoneHome, Index: HomeCellCount - 1}
	state.Pieces[Black][1] = Piece{Zone: ZoneFinished, Index: 0}
	state.Pieces[Black][2] = Piece{Zone: ZoneFinished, Index: 0}
	state.Pieces[Black][3] = Piece{Zone: ZoneMain, Index: 26}
	overshoot := encodeStateForTest(t, 20, state)
	if _, _, err := rules.Apply(overshoot, blackID, gameapi.Action{Type: MoveRequested, Payload: json.RawMessage(`{"pieceIndex":0}`)}); !errors.Is(err, ErrInvalidMove) {
		t.Fatalf("overshoot error = %v", err)
	}

	state.Dice = 1
	state.Pieces[Black][3] = Piece{Zone: ZoneFinished, Index: 0}
	finish := encodeStateForTest(t, 20, state)
	event, snapshot, err := rules.Apply(finish, blackID, gameapi.Action{Type: MoveRequested, Payload: json.RawMessage(`{"pieceIndex":0}`)})
	if err != nil {
		t.Fatal(err)
	}
	state = decodeStateForTest(t, snapshot)
	if state.Status != StatusFinished || state.Result == nil || *state.Result != ResultGoal || state.WinnerUserID == nil || *state.WinnerUserID != blackID || event.Type != MoveAccepted {
		t.Fatalf("fourth plane did not win: %#v", state)
	}
}

func TestThirdSixReturnsPiecesMovedDuringStreakAndEndsTurn(t *testing.T) {
	rules := NewRules()
	state := initialState()
	state.BlackUserID = stringPointer(blackID)
	state.WhiteUserID = stringPointer(whiteID)
	state.Phase = PhaseAwaitingRoll
	state.ConsecutiveSixes = 2
	state.SixMovedPieceIndices = []int{0, 1}
	state.Pieces[Black][0] = Piece{Zone: ZoneMain, Index: 9}
	state.Pieces[Black][1] = Piece{Zone: ZoneHome, Index: 2}
	snapshot := encodeStateForTest(t, 12, state)

	event, next, err := rules.ApplyRandom(snapshot, blackID, gameapi.Action{Type: RollRequested, Payload: json.RawMessage(`{}`)}, bytes.NewReader([]byte{5}))
	if err != nil {
		t.Fatal(err)
	}
	var payload acceptedRollPayload
	if err := json.Unmarshal(event.Payload, &payload); err != nil {
		t.Fatal(err)
	}
	if len(payload.PenalizedPieceIndices) != 2 || len(payload.MovablePieceIndices) != 0 {
		t.Fatalf("unexpected penalty payload: %#v", payload)
	}
	state = decodeStateForTest(t, next)
	if state.Pieces[Black][0].Zone != ZoneHangar || state.Pieces[Black][1].Zone != ZoneHangar || state.NextColor != White || state.ConsecutiveSixes != 0 || state.Phase != PhaseAwaitingRoll {
		t.Fatalf("unexpected penalty state: %#v", state)
	}
}

func TestRebuildRejectsTamperedAcceptedRoll(t *testing.T) {
	event, _, err := NewRules().ApplyRandom(gameapi.Snapshot{}, blackID, gameapi.Action{Type: RollRequested, Payload: json.RawMessage(`{}`)}, bytes.NewReader([]byte{5}))
	if err != nil {
		t.Fatal(err)
	}
	event.Payload = json.RawMessage(`{"color":"black","userId":"00000000-0000-4000-8000-000000000001","value":6,"movablePieceIndices":[0],"penalizedPieceIndices":[]}`)
	if _, err := NewRules().Rebuild([]gameapi.Event{event}); !errors.Is(err, gameapi.ErrInvalidEvent) {
		t.Fatalf("tampered rebuild error = %v", err)
	}
}

func decodeStateForTest(t *testing.T, snapshot gameapi.Snapshot) snapshotState {
	t.Helper()
	var state snapshotState
	if err := json.Unmarshal(snapshot.State, &state); err != nil {
		t.Fatal(err)
	}
	return state
}

func encodeStateForTest(t *testing.T, revision int64, state snapshotState) gameapi.Snapshot {
	t.Helper()
	encoded, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	return gameapi.Snapshot{Revision: revision, State: encoded}
}

func stringPointer(value string) *string { return &value }
