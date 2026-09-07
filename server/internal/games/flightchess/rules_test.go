package flightchess

import (
	"bytes"
	"encoding/json"
	"errors"
	"math/rand"
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
	if rolled.Type != RollAccepted || string(rolled.Payload) != `{"color":"black","userId":"00000000-0000-4000-8000-000000000001","value":6,"movablePieceIndices":[0,1,2,3]}` {
		t.Fatalf("unexpected roll event: %s", rolled.Payload)
	}
	state := decodeStateForTest(t, afterRoll)
	if state.Phase != PhaseAwaitingMove || state.Dice != 6 || state.NextColor != Black {
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

func TestExactFinishBouncesOvershootAndFourthPlaneWins(t *testing.T) {
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
	if _, bounced, err := rules.Apply(overshoot, blackID, gameapi.Action{Type: MoveRequested, Payload: json.RawMessage(`{"pieceIndex":0}`)}); err != nil {
		t.Fatalf("overshoot error = %v", err)
	} else if got := decodeStateForTest(t, bounced); got.Pieces[Black][0] != state.Pieces[Black][0] || got.Status != StatusActive || got.NextColor != White {
		t.Fatalf("bounce back to starting cell failed: %#v", got)
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

func TestRepeatedSixesKeepTurnWithoutPenalty(t *testing.T) {
	rules := NewRules()
	var snapshot gameapi.Snapshot
	for rollNumber := 1; rollNumber <= 3; rollNumber++ {
		_, afterRoll, err := rules.ApplyRandom(snapshot, blackID, gameapi.Action{Type: RollRequested, Payload: json.RawMessage(`{}`)}, bytes.NewReader([]byte{5}))
		if err != nil {
			t.Fatalf("roll %d: %v", rollNumber, err)
		}
		state := decodeStateForTest(t, afterRoll)
		if state.Phase != PhaseAwaitingMove || state.NextColor != Black {
			t.Fatalf("roll %d did not keep selection: %#v", rollNumber, state)
		}
		_, snapshot, err = rules.Apply(afterRoll, blackID, gameapi.Action{Type: MoveRequested, Payload: json.RawMessage(`{"pieceIndex":0}`)})
		if err != nil {
			t.Fatalf("move %d: %v", rollNumber, err)
		}
	}
	state := decodeStateForTest(t, snapshot)
	if state.Pieces[Black][0].Zone == ZoneHangar || state.NextColor != Black || state.Phase != PhaseAwaitingRoll {
		t.Fatalf("repeated sixes applied a penalty: %#v", state)
	}
}

func TestRebuildRejectsTamperedAcceptedRoll(t *testing.T) {
	event, _, err := NewRules().ApplyRandom(gameapi.Snapshot{}, blackID, gameapi.Action{Type: RollRequested, Payload: json.RawMessage(`{}`)}, bytes.NewReader([]byte{5}))
	if err != nil {
		t.Fatal(err)
	}
	event.Payload = json.RawMessage(`{"color":"black","userId":"00000000-0000-4000-8000-000000000001","value":6,"movablePieceIndices":[0]}`)
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

func TestHomeLaneRollsBounceAndRemainMovable(t *testing.T) {
	for _, color := range []string{Black, White} {
		for index := 0; index < HomeCellCount; index++ {
			for roll := 1; roll <= 6; roll++ {
				// Walk one step at a time as an independent rules oracle.
				target, direction := index, 1
				for step := 0; step < roll; step++ {
					target += direction
					if target == HomeCellCount {
						direction = -1
					}
				}
				want := Piece{Zone: ZoneHome, Index: target}
				if target == HomeCellCount {
					want = Piece{Zone: ZoneFinished}
				}
				got, ok := resolveMove(color, Piece{Zone: ZoneHome, Index: index}, roll)
				if !ok || got.to != want {
					t.Fatalf("%s home %d roll %d: got %#v, want %#v", color, index, roll, got, want)
				}
				state := initialState()
				state.Pieces[color][0] = Piece{Zone: ZoneHome, Index: index}
				if indices := movablePieces(color, state.Pieces[color], roll); len(indices) == 0 || indices[0] != 0 {
					t.Fatalf("home plane excluded: %v", indices)
				}
			}
		}
	}
}

func TestRebuildAcceptsHistoricalOvershootExclusionAndNewBounce(t *testing.T) {
	rules := NewRules()
	var snapshot gameapi.Snapshot
	var events []gameapi.Event
	// Reach home through real accepted rolls and moves, without snapshot injection.
	for step := 0; step < 20; step++ {
		roll, rolled, err := rules.applyRollValue(snapshot, blackID, 6)
		if err != nil {
			t.Fatal(err)
		}
		move, moved, err := rules.Apply(rolled, blackID, gameapi.Action{Type: MoveRequested, Payload: json.RawMessage(`{"pieceIndex":0}`)})
		if err != nil {
			t.Fatal(err)
		}
		events = append(events, roll, move)
		snapshot = moved
		if decodeStateForTest(t, snapshot).Pieces[Black][0].Zone == ZoneHome {
			break
		}
	}
	state := decodeStateForTest(t, snapshot)
	if state.Pieces[Black][0].Zone != ZoneHome || state.Pieces[Black][0].Index == 0 {
		t.Fatal("fixture did not reach an overshooting position")
	}
	roll, rolled, err := rules.applyRollValue(snapshot, blackID, 6)
	if err != nil {
		t.Fatal(err)
	}
	// Exact payload stored by the old rule: home plane excluded, hangars legal.
	legacy := roll
	legacy.Payload = json.RawMessage(`{"color":"black","userId":"00000000-0000-4000-8000-000000000001","value":6,"movablePieceIndices":[1,2,3]}`)
	if rebuilt, err := rules.Rebuild(append(append([]gameapi.Event{}, events...), legacy)); err != nil || !bytes.Equal(rebuilt.State, rolled.State) {
		t.Fatalf("legacy roll could not be restored: %v", err)
	}
	move, moved, err := rules.Apply(rolled, blackID, gameapi.Action{Type: MoveRequested, Payload: json.RawMessage(`{"pieceIndex":0}`)})
	if err != nil {
		t.Fatal(err)
	}
	if rebuilt, err := rules.Rebuild(append(events, roll, move)); err != nil || !bytes.Equal(rebuilt.State, moved.State) {
		t.Fatalf("new bounce could not be replayed: %v", err)
	}
}

func TestCapturesEveryLandingWithoutCapturingPassedCells(t *testing.T) {
	for _, color := range []string{Black, White} {
		for _, tc := range []struct {
			name           string
			from, roll, to int
			effect         string
			enemies        []int
			captured       []int
		}{
			{"jump", 1, 1, 6, EffectJump, []int{2, 6, 2, 4}, []int{0, 1, 2}},
			{"shortcut", 16, 2, 30, EffectShortcut, []int{18, 30, 17, 24}, []int{0, 1}},
			{"jump_shortcut", 10, 4, 30, EffectJumpShortcut, []int{30, 14, 18, 12}, []int{0, 1, 2}},
		} {
			t.Run(color+"/"+tc.name, func(t *testing.T) {
				state := initialState()
				state.BlackUserID, state.WhiteUserID = stringPointer(blackID), stringPointer(whiteID)
				state.NextColor, state.Phase, state.Dice = color, PhaseAwaitingMove, tc.roll
				state.Pieces[color][0] = Piece{ZoneMain, indexForProgress(color, tc.from)}
				for index, progress := range tc.enemies {
					state.Pieces[opposite(color)][index] = Piece{ZoneMain, indexForProgress(color, progress)}
				}
				actor := blackID
				if color == White {
					actor = whiteID
				}
				event, next, err := NewRules().Apply(encodeStateForTest(t, 10, state), actor, gameapi.Action{Type: MoveRequested, Payload: json.RawMessage(`{"pieceIndex":0}`)})
				if err != nil {
					t.Fatal(err)
				}
				var payload acceptedMovePayload
				if err := json.Unmarshal(event.Payload, &payload); err != nil {
					t.Fatal(err)
				}
				want, _ := json.Marshal(tc.captured)
				got, _ := json.Marshal(payload.CapturedPieceIndices)
				if !bytes.Equal(got, want) || payload.Effect != tc.effect || payload.To != (Piece{ZoneMain, indexForProgress(color, tc.to)}) {
					t.Fatalf("move = %+v, want captures %s", payload, want)
				}
				after := decodeStateForTest(t, next)
				for index, before := range state.Pieces[opposite(color)] {
					captured := false
					for _, slot := range tc.captured {
						captured = captured || index == slot
					}
					expected := before
					if captured {
						expected = Piece{ZoneHangar, index}
					}
					if after.Pieces[opposite(color)][index] != expected {
						t.Fatalf("piece %d: %+v", index, after)
					}
				}
			})
		}
	}
}

func TestRebuildPreservesHistoricalAndCorrectedLandingCaptures(t *testing.T) {
	rules := NewRules()
	random := rand.New(rand.NewSource(41))
	var snapshot gameapi.Snapshot
	var events []gameapi.Event
	for step := 0; step < 2000; step++ {
		state, _, err := stateFromSnapshot(snapshot)
		if err != nil {
			t.Fatal(err)
		}
		if state.Status == StatusFinished {
			snapshot = gameapi.Snapshot{}
			events = nil
			continue
		}
		actor := blackID
		if state.NextColor == White {
			actor = whiteID
		}
		roll, rolled, err := rules.applyRollValue(snapshot, actor, random.Intn(6)+1)
		if err != nil {
			t.Fatal(err)
		}
		events = append(events, roll)
		snapshot = rolled
		state = decodeStateForTest(t, rolled)
		if state.Phase != PhaseAwaitingMove {
			continue
		}
		movable := movablePieces(state.NextColor, state.Pieces[state.NextColor], state.Dice)
		payload, _ := json.Marshal(requestedMovePayload{PieceIndex: movable[random.Intn(len(movable))]})
		action := gameapi.Action{Type: MoveRequested, Payload: payload}
		current, next, err := rules.Apply(rolled, actor, action)
		if err != nil {
			t.Fatal(err)
		}
		legacy, oldNext, err := rules.applyMove(rolled, actor, action, false)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(current.Payload, legacy.Payload) {
			for _, variant := range []struct {
				event    gameapi.Event
				snapshot gameapi.Snapshot
			}{{current, next}, {legacy, oldNext}} {
				rebuilt, err := rules.Rebuild(append(append([]gameapi.Event{}, events...), variant.event))
				if err != nil || !bytes.Equal(rebuilt.State, variant.snapshot.State) {
					t.Fatalf("capture replay: %v", err)
				}
			}
			return
		}
		events = append(events, current)
		snapshot = next
	}
	t.Fatal("fixture never reached an intermediate landing capture")
}
