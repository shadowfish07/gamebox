package matches

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
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

func TestFlightChessCancelOnlyBeforeGameplay(t *testing.T) {
	for _, actions := range []int{0, 1, 2} {
		t.Run(fmt.Sprint(actions), func(t *testing.T) {
			fixture := newFixture(t)
			service := fixture.service(t, bytes.NewReader([]byte{0, 5}))
			ctx := context.Background()
			created, err := service.Create(ctx, flightchess.GameID, initiatorID, opponentID)
			if err != nil {
				t.Fatal(err)
			}
			if actions >= 1 {
				if _, _, err := service.ApplyAction(ctx, flightChessAction(created.ID, initiatorID, 2100, 0, flightchess.RollRequested, `{}`)); err != nil {
					t.Fatal(err)
				}
			}
			if actions == 2 {
				if _, _, err := service.ApplyAction(ctx, flightChessAction(created.ID, initiatorID, 2101, 1, flightchess.MoveRequested, `{"pieceIndex":0}`)); err != nil {
					t.Fatal(err)
				}
			}
			_, err = service.Cancel(ctx, created.ID, opponentID)
			wantStatus, wantRevision, wantSlots := StatusCancelled, int64(1), 0
			if actions == 0 {
				if err != nil {
					t.Fatal(err)
				}
			} else {
				if !errors.Is(err, ErrMatchNotCancellable) {
					t.Fatalf("cancel after %d actions: %v", actions, err)
				}
				wantStatus, wantRevision, wantSlots = StatusActive, int64(actions), 2
			}
			rebuilt, err := service.Snapshot(ctx, created.ID)
			if err != nil || rebuilt.Match.Status != wantStatus || rebuilt.Match.Revision != wantRevision {
				t.Fatalf("snapshot=(%+v,%v)", rebuilt.Match, err)
			}
			assertTableCount(t, fixture.db, "active_game_slots", wantSlots)
		})
	}
}

func TestFlightChessEventLimitEndsMatchAndPreservesHistory(t *testing.T) {
	for _, finalType := range []string{flightchess.RollRequested, flightchess.MoveRequested, protocol.TypeFlightChessResignRequested} {
		t.Run(finalType, func(t *testing.T) {
			fixture := newFixture(t)
			entropy := make([]byte, maximumFlightChessEvents+2)
			if finalType == flightchess.MoveRequested {
				entropy[maximumFlightChessEvents-1] = 5
			}
			service := fixture.service(t, bytes.NewReader(entropy))
			ctx := context.Background()
			created, err := service.Create(ctx, flightchess.GameID, initiatorID, opponentID)
			if err != nil {
				t.Fatal(err)
			}
			var before Snapshot
			for revision := 0; revision < maximumFlightChessEvents-1; revision++ {
				actor := initiatorID
				if revision%2 == 1 {
					actor = opponentID
				}
				_, before, err = service.ApplyAction(ctx, flightChessAction(created.ID, actor, 3000+revision, int64(revision), flightchess.RollRequested, `{}`))
				if err != nil {
					t.Fatalf("roll %d: %v", revision+1, err)
				}
			}
			actor, payload := opponentID, `{}`
			if finalType == flightchess.MoveRequested {
				actor, payload = initiatorID, `{"pieceIndex":0}`
			}
			request := flightChessAction(created.ID, actor, 4000, before.Match.Revision, finalType, payload)
			if finalType != protocol.TypeFlightChessResignRequested {
				invalid := request
				invalid.ActorUserID = thirdID
				if _, _, err := service.ApplyAction(ctx, invalid); !errors.Is(err, ErrInvalidRequest) {
					t.Fatalf("nonmember: %v", err)
				}
			}
			if finalType == flightchess.RollRequested {
				if _, err := fixture.db.Exec(`CREATE TRIGGER fail_limit_metadata BEFORE INSERT ON flight_chess_limit_actions BEGIN SELECT RAISE(ABORT, 'fixture failure'); END`); err != nil {
					t.Fatal(err)
				}
				failed, _, err := service.ApplyAction(ctx, request)
				if !errors.Is(err, ErrInternal) || failed.Revision != 0 {
					t.Fatalf("metadata failure=(%+v,%v)", failed, err)
				}
				if intact, err := service.Snapshot(ctx, created.ID); err != nil || intact.Match.Status != StatusActive || intact.Match.Revision != before.Match.Revision {
					t.Fatalf("rollback=(%+v,%v)", intact.Match, err)
				}
				assertTableCount(t, fixture.db, "match_events", maximumFlightChessEvents-1)
				assertTableCount(t, fixture.db, "flight_chess_limit_actions", 0)
				assertTableCount(t, fixture.db, "active_game_slots", 2)
				if _, err := fixture.db.Exec(`DROP TRIGGER fail_limit_metadata`); err != nil {
					t.Fatal(err)
				}
			}
			event, finished, err := service.ApplyAction(ctx, request)
			if err != nil {
				t.Fatalf("last action: %v", err)
			}
			wantStatus, wantType := StatusAbandoned, protocol.TypePlatformMatchAbandoned
			if finalType == protocol.TypeFlightChessResignRequested {
				wantStatus, wantType = StatusFinished, protocol.TypeFlightChessResigned
			}
			if event.Type != wantType || event.Revision != maximumFlightChessEvents || finished.Match.Status != wantStatus || finished.Match.FinishedAt == nil {
				t.Fatalf("event=%+v match=%+v", event, finished.Match)
			}
			if finalType != protocol.TypeFlightChessResignRequested && (event.ActionID != nil || event.ActorUserID != nil || string(event.Payload) != `{}` || finished.Match.Result != nil || finished.Match.WinnerUserID != nil) {
				t.Fatalf("noncanonical abandonment: %+v %+v", event, finished.Match)
			}
			rebuilt, err := service.Snapshot(ctx, created.ID)
			if err != nil || rebuilt.Match.Status != wantStatus || rebuilt.Match.Revision != maximumFlightChessEvents || rebuilt.Game.Revision != before.Game.Revision || !bytes.Equal(rebuilt.Game.State, before.Game.State) {
				t.Fatalf("rebuilt=(%+v,%v)", rebuilt, err)
			}
			// Retry through a fresh service with no entropy: the outcome must be
			// loaded durably, without rerolling or committing another event.
			restarted := fixture.service(t, bytes.NewReader(nil))
			retried, retrySnapshot, retryErr := restarted.ApplyAction(ctx, request)
			if retryErr != nil || retried.Type != event.Type || retried.Revision != event.Revision || !retried.CreatedAt.Equal(event.CreatedAt) || retrySnapshot.Match.Status != wantStatus || retrySnapshot.Match.Revision != maximumFlightChessEvents {
				t.Fatalf("retry=(%+v,%+v,%v)", retried, retrySnapshot.Match, retryErr)
			}
			if finalType != protocol.TypeFlightChessResignRequested {
				if retried.ActionID != nil || retried.ActorUserID != nil {
					t.Fatalf("retry exposed request metadata: %+v", retried)
				}
				conflict := request
				conflict.Type, conflict.Payload = protocol.TypeFlightChessResignRequested, json.RawMessage(`{}`)
				if _, _, err := restarted.ApplyAction(ctx, conflict); !errors.Is(err, ErrActionConflict) {
					t.Fatalf("changed type retry: %v", err)
				}
				if finalType == flightchess.MoveRequested {
					conflict = request
					conflict.Payload = json.RawMessage(`{"pieceIndex":1}`)
					if _, _, err := restarted.ApplyAction(ctx, conflict); !errors.Is(err, ErrActionConflict) {
						t.Fatalf("changed piece retry: %v", err)
					}
				}
			}
			assertTableCount(t, fixture.db, "active_game_slots", 0)
			assertTableCount(t, fixture.db, "match_events", maximumFlightChessEvents)
			if _, _, err := service.ApplyAction(ctx, flightChessAction(created.ID, actor, 4001, maximumFlightChessEvents, finalType, payload)); !errors.Is(err, ErrInvalidRequest) {
				t.Fatalf("terminal action: %v", err)
			}
		})
	}
}
