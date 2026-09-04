package matches

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"testing"

	"me.zqydev/gamebox/server/internal/games/flightchess"
	"me.zqydev/gamebox/server/internal/protocol"
)

func TestFlightChessAuthoritativeRollMoveRetrySnapshotAndResign(t *testing.T) {
	fixture := newFixture(t)
	// The first byte assigns platform colors; subsequent bytes produce dice.
	service := fixture.service(t, bytes.NewReader([]byte{0, 5, 2}))
	created, err := service.Create(context.Background(), flightchess.GameID, initiatorID, opponentID)
	if err != nil {
		t.Fatal(err)
	}

	roll := flightChessAction(created.ID, initiatorID, 2001, 0, flightchess.RollRequested, `{}`)
	event, snapshot, err := service.ApplyAction(context.Background(), roll)
	if err != nil {
		t.Fatalf("roll: %v", err)
	}
	if event.Type != flightchess.RollAccepted || event.Revision != 1 || snapshot.Match.Revision != 1 || snapshot.Game.Revision != 1 {
		t.Fatalf("roll event=%+v snapshot=%+v", event, snapshot)
	}
	var state struct {
		Phase     string `json:"phase"`
		NextColor string `json:"nextColor"`
		Dice      int    `json:"dice"`
	}
	if json.Unmarshal(snapshot.Game.State, &state) != nil || state.Phase != flightchess.PhaseAwaitingMove || state.NextColor != string(ColorBlack) || state.Dice != 6 {
		t.Fatalf("rolled state=%s", snapshot.Game.State)
	}

	move := flightChessAction(created.ID, initiatorID, 2002, 1, flightchess.MoveRequested, `{"pieceIndex":2}`)
	moveEvent, moved, err := service.ApplyAction(context.Background(), move)
	if err != nil {
		t.Fatalf("move: %v", err)
	}
	if moveEvent.Type != flightchess.MoveAccepted || moved.Match.Revision != 2 || moved.Match.Status != StatusActive {
		t.Fatalf("move event=%+v snapshot=%+v", moveEvent, moved.Match)
	}
	if _, _, err := service.ApplyAction(context.Background(), flightChessAction(created.ID, opponentID, 2003, 2, flightchess.RollRequested, `{}`)); !errors.Is(err, flightchess.ErrNotYourTurn) {
		t.Fatalf("opponent stole extra roll: %v", err)
	}

	retry, current, err := service.ApplyAction(context.Background(), roll)
	if err != nil || retry.Revision != 1 || current.Match.Revision != 2 {
		t.Fatalf("idempotent roll retry=(%+v,%+v,%v)", retry, current.Match, err)
	}
	conflict := roll
	conflict.Type = flightchess.MoveRequested
	conflict.Payload = json.RawMessage(`{"pieceIndex":0}`)
	if _, _, err := service.ApplyAction(context.Background(), conflict); !errors.Is(err, ErrActionConflict) {
		t.Fatalf("action conflict error=%v", err)
	}

	wire, err := snapshotEnvelope(current, initiatorID)
	if err != nil || !bytes.Contains(wire, []byte(`"blackUserId":"`+initiatorID+`"`)) || !bytes.Contains(wire, []byte(`"pieces"`)) {
		t.Fatalf("snapshot wire=(%s,%v)", wire, err)
	}

	resign := flightChessAction(created.ID, initiatorID, 2004, 2, protocol.TypeFlightChessResignRequested, `{}`)
	resigned, finished, err := service.ApplyAction(context.Background(), resign)
	if err != nil {
		t.Fatalf("resign: %v", err)
	}
	if resigned.Type != protocol.TypeFlightChessResigned || finished.Match.Status != StatusFinished || !stringPointerEquals(finished.Match.Result, ResultResignation) || !stringPointerEquals(finished.Match.WinnerUserID, opponentID) {
		t.Fatalf("resignation event=%+v match=%+v", resigned, finished.Match)
	}
	if rebuilt, err := service.Snapshot(context.Background(), created.ID); err != nil || rebuilt.Match.Revision != 3 || rebuilt.Game.Revision != 2 {
		t.Fatalf("rebuilt snapshot=(%+v,%v)", rebuilt, err)
	}
}

func TestFlightChessRandomFailureDoesNotCommitRoll(t *testing.T) {
	fixture := newFixture(t)
	service := fixture.service(t, bytes.NewReader([]byte{0}))
	created, err := service.Create(context.Background(), flightchess.GameID, initiatorID, opponentID)
	if err != nil {
		t.Fatal(err)
	}
	request := flightChessAction(created.ID, initiatorID, 2010, 0, flightchess.RollRequested, `{}`)
	if _, _, err := service.ApplyAction(context.Background(), request); !errors.Is(err, ErrInternal) {
		t.Fatalf("random failure error=%v", err)
	}
	if snapshot, err := service.Snapshot(context.Background(), created.ID); err != nil || snapshot.Match.Revision != 0 {
		t.Fatalf("failed roll mutated match=(%+v,%v)", snapshot.Match, err)
	}
}

func flightChessAction(matchID, actorID string, sequence int, revision int64, actionType, payload string) ActionRequest {
	return ActionRequest{
		MatchID: matchID, ActorUserID: actorID, ActionID: actionID(sequence), ExpectedRevision: revision,
		Type: actionType, Payload: json.RawMessage(payload),
	}
}
