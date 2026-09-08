package flightchess

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"testing"

	"me.zqydev/gamebox/server/internal/games/gameapi"
)

func TestLaunchDiceAndNextTurn(t *testing.T) {
	for value := 1; value <= 6; value++ {
		t.Run(fmt.Sprint(value), func(t *testing.T) {
			rules := NewRules()
			roll, rolled, err := rules.ApplyRandom(gameapi.Snapshot{}, blackID, gameapi.Action{Type: RollRequested, Payload: json.RawMessage(`{}`)}, bytes.NewReader([]byte{byte(value - 1)}))
			if err != nil {
				t.Fatal(err)
			}
			state := decodeStateForTest(t, rolled)
			if value < 5 {
				if state.Phase != PhaseAwaitingRoll || state.NextColor != White {
					t.Fatalf("small roll did not pass: %#v", state)
				}
				return
			}
			var payload acceptedRollPayload
			if err := json.Unmarshal(roll.Payload, &payload); err != nil {
				t.Fatal(err)
			}
			if len(payload.MovablePieceIndices) != 4 {
				t.Fatalf("hangar selection = %v", payload.MovablePieceIndices)
			}
			move, moved, err := rules.Apply(rolled, blackID, gameapi.Action{Type: MoveRequested, Payload: json.RawMessage(`{"pieceIndex":2}`)})
			if err != nil {
				t.Fatal(err)
			}
			state = decodeStateForTest(t, moved)
			nextActor, nextColor := whiteID, White
			if value == 6 {
				nextActor, nextColor = blackID, Black
			}
			if state.Pieces[Black][2] != (Piece{Zone: ZoneLaunch}) || state.NextColor != nextColor || state.Dice != 0 || state.Phase != PhaseAwaitingRoll {
				t.Fatalf("bad launch: %#v", state)
			}
			if _, _, err := rules.Apply(moved, blackID, gameapi.Action{Type: MoveRequested, Payload: json.RawMessage(`{"pieceIndex":2}`)}); !errors.Is(err, ErrInvalidPhase) {
				t.Fatalf("move without new roll: %v", err)
			}
			if value == 5 {
				if _, _, err := rules.applyRollValue(moved, blackID, 1); !errors.Is(err, ErrNotYourTurn) {
					t.Fatalf("five granted bonus roll: %v", err)
				}
			}
			if _, _, err := rules.applyRollValue(moved, nextActor, 1); err != nil {
				t.Fatalf("next roll: %v", err)
			}
			rebuilt, err := rules.Rebuild([]gameapi.Event{roll, move})
			if err != nil || !bytes.Equal(rebuilt.State, moved.State) {
				t.Fatalf("replay: %v", err)
			}
		})
	}
}

func TestHistoricalFivePassStillRebuilds(t *testing.T) {
	rules := NewRules()
	oldRoll := gameapi.Event{Revision: 1, Type: RollAccepted, ActorID: blackID, Payload: json.RawMessage(`{"color":"black","userId":"00000000-0000-4000-8000-000000000001","value":5,"movablePieceIndices":[]}`)}
	snapshot, err := rules.Rebuild([]gameapi.Event{oldRoll})
	if err != nil {
		t.Fatal(err)
	}
	state := decodeStateForTest(t, snapshot)
	if state.NextColor != White || state.Phase != PhaseAwaitingRoll {
		t.Fatalf("historical pass changed: %#v", state)
	}
	roll, rolled, err := rules.applyRollValue(snapshot, whiteID, 5)
	if err != nil {
		t.Fatal(err)
	}
	move, moved, err := rules.Apply(rolled, whiteID, gameapi.Action{Type: MoveRequested, Payload: json.RawMessage(`{"pieceIndex":0}`)})
	if err != nil {
		t.Fatal(err)
	}
	if rebuilt, err := rules.Rebuild([]gameapi.Event{oldRoll, roll, move}); err != nil || !bytes.Equal(rebuilt.State, moved.State) {
		t.Fatalf("mixed replay: %v", err)
	}
}
