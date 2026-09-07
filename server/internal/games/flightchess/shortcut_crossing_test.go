package flightchess

import (
	"bytes"
	"encoding/json"
	"math/rand"
	"me.zqydev/gamebox/server/internal/games/gameapi"
	"testing"
)

func TestShortcutCapturesOnlyOpponentHomeCrossing(t *testing.T) {
	for _, color := range []string{Black, White} {
		for _, tc := range []struct {
			name       string
			from, roll int
			captures   bool
		}{
			{"shortcut", 16, 2, true}, {"jump shortcut", 10, 4, true}, {"ordinary jump", 1, 1, false}, {"ordinary move", 2, 1, false}, {"enter own home", 50, 3, false},
		} {
			t.Run(color+"/"+tc.name, func(t *testing.T) {
				state := initialState()
				state.BlackUserID, state.WhiteUserID = stringPointer(blackID), stringPointer(whiteID)
				state.NextColor, state.Phase, state.Dice = color, PhaseAwaitingMove, tc.roll
				state.Pieces[color][0] = Piece{ZoneMain, indexForProgress(color, tc.from)}
				state.Pieces[color][1] = Piece{ZoneHome, 2}
				for i, cell := range []int{2, 1, 2, 3} {
					state.Pieces[opposite(color)][i] = Piece{ZoneHome, cell}
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
				if err = json.Unmarshal(event.Payload, &payload); err != nil {
					t.Fatal(err)
				}
				want := "[]"
				if tc.captures {
					want = "[0,2]"
				}
				got, _ := json.Marshal(payload.CapturedPieceIndices)
				if string(got) != want {
					t.Fatalf("captures %s, want %s", got, want)
				}
				after := decodeStateForTest(t, next)
				for i, before := range state.Pieces[opposite(color)] {
					expected := before
					if tc.captures && before.Index == 2 {
						expected = Piece{ZoneHangar, i}
					}
					if after.Pieces[opposite(color)][i] != expected {
						t.Fatalf("opponent %d changed incorrectly", i)
					}
				}
				if after.Pieces[color][1] != (Piece{ZoneHome, 2}) {
					t.Fatal("own crossing plane captured")
				}
			})
		}
	}
}

func TestRebuildPreservesHistoricalAndCorrectedCrossingCaptures(t *testing.T) {
	rules := NewRules()
	random := rand.New(rand.NewSource(41))
	var snapshot gameapi.Snapshot
	var events []gameapi.Event
	for step := 0; step < 10000; step++ {
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
		legacy, oldNext, err := rules.applyMove(rolled, actor, action, true)
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
	t.Fatal("fixture never reached an home crossing capture")
}
