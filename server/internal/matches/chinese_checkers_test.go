package matches

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"testing"

	"me.zqydev/gamebox/server/internal/games/chinesecheckers"
	"me.zqydev/gamebox/server/internal/protocol"
)

func TestChineseCheckersMoveRetrySnapshotAndResignation(t *testing.T) {
	fixture := newFixture(t)
	service := fixture.service(t, bytes.NewReader([]byte{0}))
	created, err := service.Create(context.Background(), chinesecheckers.GameID, initiatorID, opponentID)
	if err != nil {
		t.Fatal(err)
	}

	blackMove := chineseCheckersMoveRequest(created.ID, initiatorID, 910, 0, 6, 14)
	event, snapshot, err := service.ApplyAction(context.Background(), blackMove)
	if err != nil {
		t.Fatalf("black move: %v", err)
	}
	if event.Type != chinesecheckers.MoveAccepted || event.Revision != 1 || snapshot.Game.Revision != 1 || snapshot.Match.Revision != 1 {
		t.Fatalf("black move event=%+v snapshot=%+v", event, snapshot)
	}
	var state struct {
		Board       []int  `json:"board"`
		NextColor   string `json:"nextColor"`
		BlackUserID string `json:"blackUserId"`
	}
	if json.Unmarshal(snapshot.Game.State, &state) != nil || len(state.Board) != chinesecheckers.BoardCells || state.Board[6] != 0 || state.Board[14] != 1 || state.NextColor != "white" || state.BlackUserID != initiatorID {
		t.Fatalf("black state=%s", snapshot.Game.State)
	}

	if _, _, err := service.ApplyAction(context.Background(), chineseCheckersMoveRequest(created.ID, initiatorID, 911, 1, 7, 15)); !errors.Is(err, chinesecheckers.ErrNotYourTurn) {
		t.Fatalf("second black move error=%v", err)
	}
	if _, _, err := service.ApplyAction(context.Background(), chineseCheckersMoveRequest(created.ID, opponentID, 912, 1, 111, 46)); !errors.Is(err, chinesecheckers.ErrInvalidPath) {
		t.Fatalf("invalid white path error=%v", err)
	}
	if _, snapshot, err = service.ApplyAction(context.Background(), chineseCheckersMoveRequest(created.ID, opponentID, 913, 1, 111, 102)); err != nil {
		t.Fatalf("white move: %v", err)
	}

	retry, current, err := service.ApplyAction(context.Background(), blackMove)
	if err != nil || retry.Revision != 1 || current.Match.Revision != 2 {
		t.Fatalf("idempotent retry=(%+v,%+v,%v)", retry, current.Match, err)
	}

	resign := ActionRequest{
		MatchID: created.ID, ActorUserID: opponentID, ActionID: actionID(914), ExpectedRevision: 2,
		Type: protocol.TypeChineseCheckersResignRequested, Payload: json.RawMessage(`{}`),
	}
	resigned, finished, err := service.ApplyAction(context.Background(), resign)
	if err != nil {
		t.Fatalf("resign: %v", err)
	}
	if resigned.Type != protocol.TypeChineseCheckersResigned || resigned.Revision != 3 || finished.Match.Status != StatusFinished || !stringPointerEquals(finished.Match.Result, ResultResignation) || !stringPointerEquals(finished.Match.WinnerUserID, initiatorID) {
		t.Fatalf("resignation event=%+v match=%+v", resigned, finished.Match)
	}
	wantPayload := fmt.Sprintf(`{"userId":%q,"winnerUserId":%q}`, opponentID, initiatorID)
	if string(resigned.Payload) != wantPayload {
		t.Fatalf("resignation payload=%s want=%s", resigned.Payload, wantPayload)
	}
	if rebuilt, err := service.Snapshot(context.Background(), created.ID); err != nil || rebuilt.Match.Revision != 3 || rebuilt.Game.Revision != 2 {
		t.Fatalf("rebuilt snapshot=(%+v,%v)", rebuilt, err)
	}
	assertTableCount(t, fixture.db, "active_game_slots", 0)
}

func TestChineseCheckersCancelRejectsAcceptedMoveWithoutCorruptingMatch(t *testing.T) {
	fixture := newFixture(t)
	service := fixture.service(t, bytes.NewReader([]byte{0}))
	created, err := service.Create(context.Background(), chinesecheckers.GameID, initiatorID, opponentID)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := service.ApplyAction(context.Background(), chineseCheckersMoveRequest(created.ID, initiatorID, 920, 0, 6, 14)); err != nil {
		t.Fatalf("move: %v", err)
	}

	if _, err := service.Cancel(context.Background(), created.ID, opponentID); !errors.Is(err, ErrMatchNotCancellable) {
		t.Fatalf("Cancel error=%v, want %v", err, ErrMatchNotCancellable)
	}
	snapshot, err := service.Snapshot(context.Background(), created.ID)
	if err != nil || snapshot.Match.Status != StatusActive || snapshot.Match.Revision != 1 || snapshot.Game.Revision != 1 {
		t.Fatalf("snapshot after rejected cancel=(%+v,%v)", snapshot, err)
	}
	assertTableCount(t, fixture.db, "active_game_slots", 2)
}

func TestChineseCheckersReservesFinalHistoryEventForResignation(t *testing.T) {
	fixture := newFixture(t)
	service := fixture.service(t, bytes.NewReader([]byte{0}))
	created, err := service.Create(context.Background(), chinesecheckers.GameID, initiatorID, opponentID)
	if err != nil {
		t.Fatal(err)
	}
	cycle := [][]int{{6, 14}, {111, 102}, {14, 6}, {102, 111}}
	for revision := int64(0); revision < maximumMatchEvents-1; revision++ {
		actor := initiatorID
		if revision%2 == 1 {
			actor = opponentID
		}
		path := cycle[int(revision)%len(cycle)]
		request := chineseCheckersMoveRequest(created.ID, actor, 1000+int(revision), revision, path...)
		if _, _, err := service.ApplyAction(context.Background(), request); err != nil {
			t.Fatalf("move revision=%d path=%v: %v", revision, path, err)
		}
	}

	if _, _, err := service.ApplyAction(context.Background(), chineseCheckersMoveRequest(created.ID, opponentID, 1300, maximumMatchEvents-1, 111, 102)); !errors.Is(err, ErrInvalidRequest) {
		t.Fatalf("limit error=%v, want %v", err, ErrInvalidRequest)
	}
	if snapshot, err := service.Snapshot(context.Background(), created.ID); err != nil || snapshot.Match.Revision != maximumMatchEvents-1 {
		t.Fatalf("snapshot at history reserve=(%+v,%v)", snapshot.Match, err)
	}
	resign := ActionRequest{
		MatchID: created.ID, ActorUserID: opponentID, ActionID: actionID(1301), ExpectedRevision: maximumMatchEvents - 1,
		Type: protocol.TypeChineseCheckersResignRequested, Payload: json.RawMessage(`{}`),
	}
	if _, snapshot, err := service.ApplyAction(context.Background(), resign); err != nil || snapshot.Match.Status != StatusFinished || snapshot.Match.Revision != maximumMatchEvents {
		t.Fatalf("resign at history limit=(%+v,%v)", snapshot.Match, err)
	}
}

func chineseCheckersMoveRequest(matchID, actorID string, actionNumber int, expectedRevision int64, path ...int) ActionRequest {
	payload, _ := json.Marshal(struct {
		Path []int `json:"path"`
	}{Path: path})
	return ActionRequest{
		MatchID: matchID, ActorUserID: actorID, ActionID: actionID(actionNumber), ExpectedRevision: expectedRevision,
		Type: chinesecheckers.MoveRequested, Payload: payload,
	}
}
