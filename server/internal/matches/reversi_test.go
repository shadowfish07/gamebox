package matches

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"me.zqydev/gamebox/server/internal/games/reversi"
	"me.zqydev/gamebox/server/internal/protocol"
	"testing"
)

func reversiRequest(matchID, actor string, rev int64, p reversi.Point) ActionRequest {
	raw, _ := json.Marshal(p)
	return ActionRequest{MatchID: matchID, ActorUserID: actor, ActionID: fmt.Sprintf("aaaaaaaa-1111-4111-8111-%012d", rev+1), ExpectedRevision: rev, Type: reversi.MoveRequested, Payload: raw}
}
func TestReversiFullMatchDurableReplayAndHistory(t *testing.T) {
	f := newFixture(t)
	svc := f.service(t, bytes.NewReader([]byte{0, 0}))
	ctx := context.Background()
	m, err := svc.Create(ctx, reversi.GameID, initiatorID, opponentID)
	if err != nil {
		t.Fatal(err)
	}
	s, err := svc.Snapshot(ctx, m.ID)
	if err != nil {
		t.Fatal(err)
	}
	sawPass := false
	for s.Match.Status == StatusActive {
		var state reversi.State
		if json.Unmarshal(s.Game.State, &state) != nil {
			t.Fatal("state")
		}
		actor := initiatorID
		if state.NextColor == "white" {
			actor = opponentID
		}
		request := reversiRequest(m.ID, actor, s.Match.Revision, state.LegalMoves[0])
		e, next, err := svc.ApplyAction(ctx, request)
		if err != nil {
			t.Fatalf("move %d: %v", request.ExpectedRevision, err)
		}
		_, duplicate, err := svc.ApplyAction(ctx, request)
		if err != nil || duplicate.Match.Revision != next.Match.Revision {
			t.Fatal("retry", err)
		}
		if e.Revision == 1 {
			if _, err = svc.Cancel(ctx, m.ID, initiatorID); !errors.Is(err, ErrMatchNotCancellable) {
				t.Fatal("cancel after move", err)
			}
		}
		s = next
		var after reversi.State
		json.Unmarshal(s.Game.State, &after)
		sawPass = sawPass || after.PassedColor != nil
	}
	if !sawPass {
		t.Fatal("expected forced pass in first-legal game")
	}
	// A fresh service instance must derive the same result from persisted events.
	restored := f.service(t, bytes.NewReader([]byte{0, 0}))
	replay, err := restored.Snapshot(ctx, m.ID)
	if err != nil || !bytes.Equal(replay.Game.State, s.Game.State) {
		t.Fatal("replay", err)
	}
	history, err := restored.ListHistory(ctx, reversi.GameID, initiatorID, HistoryPageRequest{Limit: 20})
	if err != nil || len(history.Matches) != 1 {
		t.Fatal("history", err)
	}
	if _, err = svc.Create(ctx, reversi.GameID, initiatorID, opponentID); err != nil {
		t.Fatal("slots not released", err)
	}
}
func TestReversiCancelResignAndTurn(t *testing.T) {
	f := newFixture(t)
	svc := f.service(t, bytes.NewReader([]byte{0, 0}))
	ctx := context.Background()
	m, err := svc.Create(ctx, reversi.GameID, initiatorID, opponentID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = svc.Cancel(ctx, m.ID, initiatorID); err != nil {
		t.Fatal(err)
	}
	m, err = svc.Create(ctx, reversi.GameID, initiatorID, opponentID)
	if err != nil {
		t.Fatal(err)
	}
	req := reversiRequest(m.ID, opponentID, 0, reversi.Point{X: 3, Y: 2})
	if _, _, err = svc.ApplyAction(ctx, req); err == nil {
		t.Fatal("white started")
	}
	req.ActorUserID = initiatorID
	if _, _, err = svc.ApplyAction(ctx, req); err != nil {
		t.Fatal(err)
	}
	req.ExpectedRevision = 0
	req.ActorUserID = opponentID
	if _, _, err = svc.ApplyAction(ctx, req); !errors.Is(err, ErrStaleRevision) {
		t.Fatal("stale", err)
	}
	req.Type = protocol.TypeReversiResignRequested
	req.Payload = []byte(`{}`)
	req.ExpectedRevision = 1
	e, s, err := svc.ApplyAction(ctx, req)
	if err != nil || e.Type != protocol.TypeReversiResigned || s.Match.WinnerUserID == nil || *s.Match.WinnerUserID != initiatorID {
		t.Fatal("resign", err)
	}
	if _, err = svc.Snapshot(ctx, m.ID); err != nil {
		t.Fatal("resign replay", err)
	}
}

func TestBoardResignationRejectsCrossGameRequests(t *testing.T) {
	for _, gameID := range []string{"gomoku", reversi.GameID} {
		t.Run(gameID, func(t *testing.T) {
			f := newFixture(t)
			svc := f.service(t, bytes.NewReader([]byte{0}))
			ctx := context.Background()
			m, err := svc.Create(ctx, gameID, initiatorID, opponentID)
			if err != nil {
				t.Fatal(err)
			}
			move := reversiRequest(m.ID, initiatorID, 0, reversi.Point{X: 3, Y: 2})
			move.Type = gameID + ".move.requested"
			if _, _, err = svc.ApplyAction(ctx, move); err != nil {
				t.Fatal(err)
			}
			other := "gomoku"
			if gameID == "gomoku" {
				other = reversi.GameID
			}
			request := ActionRequest{MatchID: m.ID, ActorUserID: opponentID, ActionID: "bbbbbbbb-1111-4111-8111-111111111111", ExpectedRevision: 1, Type: other + ".resign.requested", Payload: []byte(`{}`)}
			for range 2 {
				if _, _, err = svc.ApplyAction(ctx, request); !errors.Is(err, ErrInvalidRequest) {
					t.Fatalf("cross-game resignation: %v", err)
				}
			}
			snapshot, err := svc.Snapshot(ctx, m.ID)
			if err != nil || snapshot.Match.Status != StatusActive || snapshot.Match.Revision != 1 {
				t.Fatalf("invalid request changed match: %+v, %v", snapshot.Match, err)
			}
			request.Type = gameID + ".resign.requested"
			event, terminal, err := svc.ApplyAction(ctx, request)
			if err != nil || event.Type != gameID+".resigned" || terminal.Match.Status != StatusFinished {
				t.Fatalf("valid resignation: %+v, %v", event, err)
			}
			duplicate, _, err := svc.ApplyAction(ctx, request)
			if err != nil || duplicate.Revision != event.Revision {
				t.Fatalf("valid retry: %+v, %v", duplicate, err)
			}
			request.Type = other + ".resign.requested"
			if _, _, err = svc.ApplyAction(ctx, request); !errors.Is(err, ErrInvalidRequest) {
				t.Fatalf("cross-game retry: %v", err)
			}
		})
	}
}
