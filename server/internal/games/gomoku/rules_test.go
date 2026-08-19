package gomoku

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"strings"
	"sync"
	"testing"
	"unicode/utf8"

	games "me.zqydev/gamebox/server/internal/games/gameapi"
)

const (
	blackActor = "11111111-1111-4111-8111-111111111111"
	whiteActor = "22222222-2222-4222-8222-222222222222"
)

type snapshotView struct {
	Status       string  `json:"status"`
	Board        []int   `json:"board"`
	BoardSize    int     `json:"boardSize"`
	BlackUserID  *string `json:"blackUserId"`
	WhiteUserID  *string `json:"whiteUserId"`
	NextColor    string  `json:"nextColor"`
	WinnerUserID *string `json:"winnerUserId"`
	Result       *string `json:"result"`
}

func TestBoardUsesFixedStorageAndRowMajorCoordinates(t *testing.T) {
	var fixed [225]uint8 = board{}.cells
	if fixed != ([225]uint8{}) {
		t.Fatal("zero-value board is not empty")
	}

	var b board
	if got := b.index(Point{X: 4, Y: 3}); got != 3*15+4 {
		t.Fatalf("index = %d, want %d", got, 3*15+4)
	}
	if b.occupied(Point{X: 0, Y: 0}) {
		t.Fatal("zero-value board reports occupied cell")
	}
}

func TestInitialSnapshotIsEmpty15By15(t *testing.T) {
	snapshot, err := NewRules().Rebuild(nil)
	if err != nil {
		t.Fatalf("Rebuild(nil): %v", err)
	}
	view := decodeSnapshotView(t, snapshot)
	if snapshot.Revision != 0 || view.BoardSize != 15 || len(view.Board) != 225 {
		t.Fatalf("initial snapshot = revision %d, size %d, cells %d", snapshot.Revision, view.BoardSize, len(view.Board))
	}
	for index, cell := range view.Board {
		if cell != 0 {
			t.Fatalf("board[%d] = %d, want empty", index, cell)
		}
	}
	if view.NextColor != "black" || view.BlackUserID != nil || view.WhiteUserID != nil || view.Status != "active" || view.Result != nil || view.WinnerUserID != nil {
		t.Fatalf("unexpected initial state: %#v", view)
	}
}

func TestApplyRejectsIllegalMovesWithoutMutation(t *testing.T) {
	rules := NewRules()
	initial, err := rules.Rebuild(nil)
	if err != nil {
		t.Fatal(err)
	}
	_, afterBlack, err := rules.Apply(initial, blackActor, moveAction(7, 7))
	if err != nil {
		t.Fatalf("first move: %v", err)
	}
	_, afterWhite, err := rules.Apply(afterBlack, whiteActor, moveAction(8, 7))
	if err != nil {
		t.Fatalf("second move: %v", err)
	}

	tests := []struct {
		name     string
		snapshot games.Snapshot
		actor    string
		action   games.Action
		want     error
	}{
		{name: "negative x", snapshot: initial, actor: blackActor, action: moveAction(-1, 0), want: games.ErrInvalidAction},
		{name: "x at board size", snapshot: initial, actor: blackActor, action: moveAction(15, 0), want: games.ErrInvalidAction},
		{name: "negative y", snapshot: initial, actor: blackActor, action: moveAction(0, -1), want: games.ErrInvalidAction},
		{name: "y at board size", snapshot: initial, actor: blackActor, action: moveAction(0, 15), want: games.ErrInvalidAction},
		{name: "occupied", snapshot: afterWhite, actor: blackActor, action: moveAction(7, 7), want: ErrCellOccupied},
		{name: "non current actor", snapshot: afterWhite, actor: whiteActor, action: moveAction(6, 7), want: ErrNotYourTurn},
		{name: "unknown actor", snapshot: afterWhite, actor: "33333333-3333-4333-8333-333333333333", action: moveAction(6, 7), want: ErrNotYourTurn},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			beforeSnapshot := append([]byte(nil), test.snapshot.State...)
			beforeAction := append([]byte(nil), test.action.Payload...)
			event, gotSnapshot, gotErr := rules.Apply(test.snapshot, test.actor, test.action)
			if !errors.Is(gotErr, test.want) {
				t.Fatalf("Apply error = %v, want %v", gotErr, test.want)
			}
			if !reflect.DeepEqual(event, games.Event{}) || !reflect.DeepEqual(gotSnapshot, games.Snapshot{}) {
				t.Fatalf("rejected action returned state: %#v %#v", event, gotSnapshot)
			}
			if !bytes.Equal(test.snapshot.State, beforeSnapshot) || !bytes.Equal(test.action.Payload, beforeAction) {
				t.Fatal("Apply mutated its input")
			}
		})
	}
}

func TestApplyBindsActorsToColorsAndAdvancesTurn(t *testing.T) {
	rules := NewRules()
	snapshot, _ := rules.Rebuild(nil)
	event, snapshot, err := rules.Apply(snapshot, blackActor, moveAction(2, 3))
	if err != nil {
		t.Fatalf("black move: %v", err)
	}
	wantPayload := fmt.Sprintf(`{"x":2,"y":3,"color":"black","userId":%q}`, blackActor)
	if event.Revision != 1 || event.Type != MoveAccepted || event.ActorID != blackActor || string(event.Payload) != wantPayload {
		t.Fatalf("black event = %#v payload=%s", event, event.Payload)
	}
	view := decodeSnapshotView(t, snapshot)
	assertStringPointer(t, view.BlackUserID, blackActor, "blackUserId")
	if view.WhiteUserID != nil || view.NextColor != "white" {
		t.Fatalf("state after black = %#v", view)
	}

	_, snapshot, err = rules.Apply(snapshot, whiteActor, moveAction(4, 5))
	if err != nil {
		t.Fatalf("white move: %v", err)
	}
	view = decodeSnapshotView(t, snapshot)
	assertStringPointer(t, view.WhiteUserID, whiteActor, "whiteUserId")
	if view.NextColor != "black" || view.Board[3*15+2] != int(Black) || view.Board[5*15+4] != int(White) {
		t.Fatalf("state after white = %#v", view)
	}
}

func TestWinningDirectionsExactFiveOverlineEdgesAndBidirectionalJoin(t *testing.T) {
	tests := []struct {
		name   string
		stones []Stone
		move   Point
	}{
		{name: "horizontal exact five", stones: []Stone{{3, 7, Black}, {4, 7, Black}, {5, 7, Black}, {6, 7, Black}}, move: Point{7, 7}},
		{name: "vertical exact five", stones: []Stone{{7, 3, Black}, {7, 4, Black}, {7, 5, Black}, {7, 6, Black}}, move: Point{7, 7}},
		{name: "descending diagonal", stones: []Stone{{3, 3, Black}, {4, 4, Black}, {5, 5, Black}, {6, 6, Black}}, move: Point{7, 7}},
		{name: "ascending diagonal", stones: []Stone{{3, 11, Black}, {4, 10, Black}, {5, 9, Black}, {6, 8, Black}}, move: Point{7, 7}},
		{name: "overline wins", stones: []Stone{{2, 8, Black}, {3, 8, Black}, {4, 8, Black}, {6, 8, Black}, {7, 8, Black}}, move: Point{5, 8}},
		{name: "left edge", stones: []Stone{{0, 0, Black}, {1, 0, Black}, {2, 0, Black}, {3, 0, Black}}, move: Point{4, 0}},
		{name: "right edge", stones: []Stone{{10, 14, Black}, {11, 14, Black}, {12, 14, Black}, {13, 14, Black}}, move: Point{14, 14}},
		{name: "joins both directions", stones: []Stone{{3, 6, Black}, {4, 6, Black}, {6, 6, Black}, {7, 6, Black}}, move: Point{5, 6}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			snapshot := snapshotWith(t, test.stones, Black, blackActor, whiteActor)
			event, got, err := NewRules().Apply(snapshot, blackActor, moveAction(test.move.X, test.move.Y))
			if err != nil {
				t.Fatalf("Apply: %v", err)
			}
			view := decodeSnapshotView(t, got)
			if view.Status != "finished" || !pointerEquals(view.Result, "five") || !pointerEquals(view.WinnerUserID, blackActor) {
				t.Fatalf("winning state = %#v", view)
			}
			if event.Revision != snapshot.Revision+1 {
				t.Fatalf("event revision = %d", event.Revision)
			}
		})
	}
}

func TestWhiteFiveProducesAValidTerminalSnapshot(t *testing.T) {
	rules := NewRules()
	snapshot, err := rules.Rebuild(nil)
	if err != nil {
		t.Fatal(err)
	}
	steps := []struct {
		actor string
		point Point
	}{
		{blackActor, Point{0, 14}}, {whiteActor, Point{3, 7}},
		{blackActor, Point{2, 14}}, {whiteActor, Point{4, 7}},
		{blackActor, Point{4, 14}}, {whiteActor, Point{5, 7}},
		{blackActor, Point{6, 14}}, {whiteActor, Point{6, 7}},
		{blackActor, Point{8, 14}}, {whiteActor, Point{7, 7}},
	}
	events := make([]games.Event, 0, len(steps))
	for _, step := range steps {
		event, next, applyErr := rules.Apply(snapshot, step.actor, moveAction(step.point.X, step.point.Y))
		if applyErr != nil {
			t.Fatalf("Apply(%v): %v", step.point, applyErr)
		}
		events = append(events, event)
		snapshot = next
	}
	view := decodeSnapshotView(t, snapshot)
	if view.Status != "finished" || !pointerEquals(view.Result, "five") || !pointerEquals(view.WinnerUserID, whiteActor) || view.NextColor != "black" {
		t.Fatalf("white terminal state = %#v", view)
	}
	if _, _, err := rules.Apply(snapshot, blackActor, moveAction(14, 14)); !errors.Is(err, games.ErrInvalidAction) {
		t.Fatalf("valid terminal snapshot was rejected as corrupt: %v", err)
	}
	rebuilt, err := rules.Rebuild(events)
	if err != nil || !bytes.Equal(rebuilt.State, snapshot.State) {
		t.Fatalf("rebuild white win: err=%v\n%s\n%s", err, rebuilt.State, snapshot.State)
	}
}

func TestRenjuForbiddenShapeIsStillLegal(t *testing.T) {
	// Center creates open threes horizontally and vertically. Gomoku in this
	// product has no double-three, double-four, or overline forbidden branch.
	stones := []Stone{{6, 7, Black}, {8, 7, Black}, {7, 6, Black}, {7, 8, Black}}
	snapshot := snapshotWith(t, stones, Black, blackActor, whiteActor)
	_, got, err := NewRules().Apply(snapshot, blackActor, moveAction(7, 7))
	if err != nil {
		t.Fatalf("double-three move was rejected: %v", err)
	}
	view := decodeSnapshotView(t, got)
	if view.Status != "active" || view.Board[7*15+7] != int(Black) {
		t.Fatalf("forbidden-shape move not applied: %#v", view)
	}
}

func TestFullBoardWithoutFiveIsDraw(t *testing.T) {
	var blackPoints, whitePoints []Point
	var colors [225]Color
	for y := 0; y < 15; y++ {
		for x := 0; x < 15; x++ {
			color := White
			if ((x + 2*y) % 4) < 2 {
				color = Black
				blackPoints = append(blackPoints, Point{x, y})
			} else {
				whitePoints = append(whitePoints, Point{x, y})
			}
			colors[y*15+x] = color
		}
	}
	if len(blackPoints) != 113 || len(whitePoints) != 112 {
		t.Fatalf("formula counts = %d/%d, want 113/112", len(blackPoints), len(whitePoints))
	}
	for _, direction := range []Point{{1, 0}, {0, 1}, {1, 1}, {1, -1}} {
		if longest := longestRun(colors, direction); longest > 2 {
			t.Fatalf("formula longest run in %v = %d, want <= 2", direction, longest)
		}
	}

	rules := NewRules()
	snapshot, _ := rules.Rebuild(nil)
	events := make([]games.Event, 0, 225)
	for turn := 0; turn < 112; turn++ {
		event, next := mustApply(t, rules, snapshot, blackActor, blackPoints[turn])
		events = append(events, event)
		snapshot = next
		event, next = mustApply(t, rules, snapshot, whiteActor, whitePoints[turn])
		events = append(events, event)
		snapshot = next
	}
	event, snapshot := mustApply(t, rules, snapshot, blackActor, blackPoints[112])
	events = append(events, event)
	view := decodeSnapshotView(t, snapshot)
	if snapshot.Revision != 225 || event.Revision != 225 || occupiedCount(view.Board) != 225 || view.Status != "finished" || !pointerEquals(view.Result, "draw") || view.WinnerUserID != nil {
		t.Fatalf("draw state = revision %d event %d view %#v", snapshot.Revision, event.Revision, view)
	}
	if _, _, err := rules.Apply(snapshot, whiteActor, moveAction(0, 0)); !errors.Is(err, games.ErrInvalidAction) {
		t.Fatalf("generated draw snapshot failed validation: %v", err)
	}
	rebuilt, err := rules.Rebuild(events)
	if err != nil || !bytes.Equal(rebuilt.State, snapshot.State) {
		t.Fatalf("rebuild draw: err=%v", err)
	}
}

func TestActionJSONIsStrictAndErrorsAreSafe(t *testing.T) {
	initial, _ := NewRules().Rebuild(nil)
	invalidUTF8 := append([]byte(`{"x":1,"y":2,"note":"`), 0xff)
	invalidUTF8 = append(invalidUTF8, []byte(`"}`)...)
	tests := []struct {
		name   string
		actor  string
		action games.Action
		secret string
	}{
		{name: "unknown action", actor: blackActor, action: games.Action{Type: "gomoku.teleport.requested", Payload: json.RawMessage(`{"x":1,"y":2}`)}},
		{name: "malformed", actor: blackActor, action: games.Action{Type: MoveRequested, Payload: json.RawMessage(`{"x":`)}},
		{name: "trailing document", actor: blackActor, action: games.Action{Type: MoveRequested, Payload: json.RawMessage(`{"x":1,"y":2}{}`)}},
		{name: "unknown field", actor: blackActor, action: games.Action{Type: MoveRequested, Payload: json.RawMessage(`{"x":1,"y":2,"secret":"payload-canary"}`)}, secret: "payload-canary"},
		{name: "duplicate x", actor: blackActor, action: games.Action{Type: MoveRequested, Payload: json.RawMessage(`{"x":1,"x":2,"y":2}`)}},
		{name: "float coordinate", actor: blackActor, action: games.Action{Type: MoveRequested, Payload: json.RawMessage(`{"x":1.0,"y":2}`)}},
		{name: "exponent coordinate", actor: blackActor, action: games.Action{Type: MoveRequested, Payload: json.RawMessage(`{"x":1e0,"y":2}`)}},
		{name: "string coordinate", actor: blackActor, action: games.Action{Type: MoveRequested, Payload: json.RawMessage(`{"x":"1","y":2}`)}},
		{name: "null coordinate", actor: blackActor, action: games.Action{Type: MoveRequested, Payload: json.RawMessage(`{"x":null,"y":2}`)}},
		{name: "missing coordinate", actor: blackActor, action: games.Action{Type: MoveRequested, Payload: json.RawMessage(`{"x":1}`)}},
		{name: "overflow coordinate", actor: blackActor, action: games.Action{Type: MoveRequested, Payload: json.RawMessage(`{"x":999999999999999999999999999999999999,"y":2}`)}},
		{name: "invalid utf8 payload", actor: blackActor, action: games.Action{Type: MoveRequested, Payload: invalidUTF8}, secret: string(invalidUTF8)},
		{name: "empty actor", actor: "", action: moveAction(1, 2)},
		{name: "invalid utf8 actor", actor: string([]byte{'s', 'e', 'c', 'r', 'e', 't', '-', 0xff}), action: moveAction(1, 2), secret: "secret-"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, _, err := NewRules().Apply(initial, test.actor, test.action)
			if !errors.Is(err, games.ErrInvalidAction) {
				t.Fatalf("error = %v, want invalid action", err)
			}
			if test.secret != "" && strings.Contains(err.Error(), test.secret) {
				t.Fatalf("error exposed actor/payload: %q", err)
			}
			if !utf8.ValidString(err.Error()) {
				t.Fatalf("error is not valid UTF-8: %q", err)
			}
		})
	}
}

func TestRebuildIsStrictDeterministicAndEquivalentToApply(t *testing.T) {
	rules := NewRules()
	snapshot, _ := rules.Rebuild(nil)
	var events []games.Event
	sequence := []struct {
		actor string
		point Point
	}{
		{blackActor, Point{3, 3}}, {whiteActor, Point{3, 4}},
		{blackActor, Point{4, 3}}, {whiteActor, Point{4, 4}},
		{blackActor, Point{5, 3}}, {whiteActor, Point{5, 4}},
		{blackActor, Point{6, 3}}, {whiteActor, Point{6, 4}},
		{blackActor, Point{7, 3}},
	}
	for _, step := range sequence {
		event, next, err := rules.Apply(snapshot, step.actor, moveAction(step.point.X, step.point.Y))
		if err != nil {
			t.Fatalf("Apply sequence: %v", err)
		}
		events = append(events, event)
		snapshot = next
	}

	rebuilt, err := rules.Rebuild(events)
	if err != nil {
		t.Fatalf("Rebuild: %v", err)
	}
	if rebuilt.Revision != snapshot.Revision || !bytes.Equal(rebuilt.State, snapshot.State) {
		t.Fatalf("rebuilt state differs:\n%s\n%s", rebuilt.State, snapshot.State)
	}
	second, err := rules.Rebuild(events)
	if err != nil || !bytes.Equal(second.State, rebuilt.State) {
		t.Fatal("Rebuild is not deterministic")
	}
	if !pointerEquals(decodeSnapshotView(t, rebuilt).Result, "five") {
		t.Fatal("replayed winning result was lost")
	}
}

func TestRebuildRejectsCorruptEventStreamsWithoutLeakingData(t *testing.T) {
	winningEvents := winningEventStream(t)
	secretActor := "actor-canary"
	tests := []struct {
		name   string
		events []games.Event
		secret string
	}{
		{name: "revision starts at zero", events: []games.Event{{Revision: 0, Type: MoveAccepted, ActorID: blackActor, Payload: acceptedPayload(1, 1, "black", blackActor)}}},
		{name: "revision gap", events: []games.Event{{Revision: 2, Type: MoveAccepted, ActorID: blackActor, Payload: acceptedPayload(1, 1, "black", blackActor)}}},
		{name: "duplicate revision", events: []games.Event{{Revision: 1, Type: MoveAccepted, ActorID: blackActor, Payload: acceptedPayload(1, 1, "black", blackActor)}, {Revision: 1, Type: MoveAccepted, ActorID: whiteActor, Payload: acceptedPayload(2, 1, "white", whiteActor)}}},
		{name: "unknown event", events: []games.Event{{Revision: 1, Type: "gomoku.unknown", ActorID: secretActor, Payload: json.RawMessage(`{"secret":"event-canary"}`)}}, secret: "canary"},
		{name: "malformed event", events: []games.Event{{Revision: 1, Type: MoveAccepted, ActorID: blackActor, Payload: json.RawMessage(`{"x":`)}}, secret: "x"},
		{name: "unknown payload field", events: []games.Event{{Revision: 1, Type: MoveAccepted, ActorID: blackActor, Payload: json.RawMessage(`{"x":1,"y":1,"secret":"event-canary"}`)}}, secret: "event-canary"},
		{name: "duplicate payload field", events: []games.Event{{Revision: 1, Type: MoveAccepted, ActorID: blackActor, Payload: json.RawMessage(`{"x":1,"x":2,"y":1}`)}}},
		{name: "wrong color", events: []games.Event{{Revision: 1, Type: MoveAccepted, ActorID: blackActor, Payload: acceptedPayload(1, 1, "white", blackActor)}}},
		{name: "mismatched user", events: []games.Event{{Revision: 1, Type: MoveAccepted, ActorID: blackActor, Payload: acceptedPayload(1, 1, "black", whiteActor)}}},
		{name: "same actor twice", events: []games.Event{{Revision: 1, Type: MoveAccepted, ActorID: blackActor, Payload: acceptedPayload(1, 1, "black", blackActor)}, {Revision: 2, Type: MoveAccepted, ActorID: blackActor, Payload: acceptedPayload(2, 1, "white", blackActor)}}},
		{name: "occupied replay", events: []games.Event{{Revision: 1, Type: MoveAccepted, ActorID: blackActor, Payload: acceptedPayload(1, 1, "black", blackActor)}, {Revision: 2, Type: MoveAccepted, ActorID: whiteActor, Payload: acceptedPayload(1, 1, "white", whiteActor)}}},
		{name: "event after finished", events: append(append([]games.Event(nil), winningEvents...), games.Event{Revision: int64(len(winningEvents) + 1), Type: MoveAccepted, ActorID: whiteActor, Payload: acceptedPayload(14, 14, "white", whiteActor)})},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := NewRules().Rebuild(test.events)
			if !errors.Is(err, games.ErrInvalidEvent) {
				t.Fatalf("error = %v, want invalid event", err)
			}
			if !reflect.DeepEqual(got, games.Snapshot{}) {
				t.Fatalf("corrupt replay returned snapshot: %#v", got)
			}
			if test.secret != "" && strings.Contains(err.Error(), test.secret) {
				t.Fatalf("error exposed event: %q", err)
			}
		})
	}
}

func TestSnapshotParsingRejectsCorruptionAndOutputDoesNotAlias(t *testing.T) {
	valid, _ := NewRules().Rebuild(nil)
	tooShort := replaceSnapshotBoard(t, valid.State, []int{0})
	tooLongCells := make([]int, 226)
	tooLong := replaceSnapshotBoard(t, valid.State, tooLongCells)
	invalidUTF8 := append(append(json.RawMessage(nil), valid.State[:len(valid.State)-1]...), 0xff, '}')
	corrupt := []json.RawMessage{
		json.RawMessage(`{"boardSize":15,"board":[]`),
		json.RawMessage(`{"boardSize":15,"boardSize":15,"board":[],"moveCount":0,"nextColor":"black","nextActorId":null,"blackActorId":null,"whiteActorId":null,"status":"active","result":null,"winnerUserId":null}`),
		json.RawMessage(`{"boardSize":15,"board":[],"moveCount":0,"nextColor":"black","nextActorId":null,"blackActorId":null,"whiteActorId":null,"status":"active","result":null,"winnerUserId":null,"extra":true}`),
		tooShort,
		tooLong,
		invalidUTF8,
	}
	for index, state := range corrupt {
		_, _, err := NewRules().Apply(games.Snapshot{State: state}, blackActor, moveAction(1, 1))
		if !errors.Is(err, games.ErrInvalidSnapshot) {
			t.Fatalf("corrupt snapshot %d error = %v", index, err)
		}
	}

	inputCopy := append([]byte(nil), valid.State...)
	event, next, err := NewRules().Apply(valid, blackActor, moveAction(1, 1))
	if err != nil {
		t.Fatal(err)
	}
	next.State[0] ^= 0xff
	event.Payload[0] ^= 0xff
	if !bytes.Equal(valid.State, inputCopy) {
		t.Fatal("returned buffers alias input snapshot")
	}
	fresh, err := NewRules().Rebuild(nil)
	if err != nil || !bytes.Equal(fresh.State, inputCopy) {
		t.Fatal("caller mutation contaminated rules instance")
	}
}

func TestSnapshotValidationRejectsForgedTerminalSemantics(t *testing.T) {
	resultFiveValue := "five"
	resultDrawValue := "draw"

	activeWithFive := snapshotWith(t, []Stone{
		{2, 5, Black}, {3, 5, Black}, {4, 5, Black}, {5, 5, Black}, {6, 5, Black},
	}, Black, blackActor, whiteActor)

	finishedWithoutFive := rewriteSnapshot(t,
		snapshotWith(t, []Stone{{2, 5, Black}, {3, 5, Black}}, Black, blackActor, whiteActor),
		func(view *snapshotView) {
			view.Status = "finished"
			view.Result = &resultFiveValue
			view.WinnerUserID = view.WhiteUserID
		},
	)

	winnerHasNoLine := rewriteSnapshot(t,
		snapshotWith(t, []Stone{
			{2, 6, White}, {3, 6, White}, {4, 6, White}, {5, 6, White}, {6, 6, White},
		}, White, blackActor, whiteActor),
		func(view *snapshotView) {
			view.Status = "finished"
			view.Result = &resultFiveValue
			view.WinnerUserID = view.BlackUserID
		},
	)

	bothHaveLines := rewriteSnapshot(t,
		snapshotWith(t, []Stone{
			{2, 5, Black}, {3, 5, Black}, {4, 5, Black}, {5, 5, Black}, {6, 5, Black},
			{2, 6, White}, {3, 6, White}, {4, 6, White}, {5, 6, White}, {6, 6, White},
		}, Black, blackActor, whiteActor),
		func(view *snapshotView) {
			view.Status = "finished"
			view.Result = &resultFiveValue
			view.WinnerUserID = view.WhiteUserID
		},
	)

	fullDrawWithFive := fullDrawSnapshotWithBlackLine(t)
	fullDrawWithFive = rewriteSnapshot(t, fullDrawWithFive, func(view *snapshotView) {
		view.Status = "finished"
		view.Result = &resultDrawValue
		view.WinnerUserID = nil
	})

	tests := []struct {
		name     string
		snapshot games.Snapshot
	}{
		{name: "active already has five", snapshot: activeWithFive},
		{name: "finished five has no line", snapshot: finishedWithoutFive},
		{name: "declared winner has no line but opponent does", snapshot: winnerHasNoLine},
		{name: "both colors have lines", snapshot: bothHaveLines},
		{name: "full draw contains a line", snapshot: fullDrawWithFive},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			before := append([]byte(nil), test.snapshot.State...)
			event, next, err := NewRules().Apply(test.snapshot, blackActor, moveAction(14, 14))
			if !errors.Is(err, games.ErrInvalidSnapshot) {
				t.Fatalf("Apply error = %v, want invalid snapshot", err)
			}
			if err.Error() != games.ErrInvalidSnapshot.Error() {
				t.Fatalf("error exposed forged state: %q", err)
			}
			if !reflect.DeepEqual(event, games.Event{}) || !reflect.DeepEqual(next, games.Snapshot{}) || !bytes.Equal(before, test.snapshot.State) {
				t.Fatal("rejected forged snapshot produced or mutated state")
			}
		})
	}
}

func TestSnapshotActorPresenceMatchesStonePresence(t *testing.T) {
	rules := NewRules()
	initial, err := rules.Rebuild(nil)
	if err != nil {
		t.Fatal(err)
	}
	_, afterBlack, err := rules.Apply(initial, blackActor, moveAction(7, 7))
	if err != nil {
		t.Fatal(err)
	}

	tests := []struct {
		name     string
		snapshot games.Snapshot
	}{
		{name: "empty snapshot prebinds black", snapshot: rewriteSnapshot(t, initial, func(view *snapshotView) { view.BlackUserID = stringPointer(blackActor) })},
		{name: "empty snapshot prebinds white", snapshot: rewriteSnapshot(t, initial, func(view *snapshotView) { view.WhiteUserID = stringPointer(whiteActor) })},
		{name: "black stone missing black actor", snapshot: rewriteSnapshot(t, afterBlack, func(view *snapshotView) { view.BlackUserID = nil })},
		{name: "no white stones but white actor present", snapshot: rewriteSnapshot(t, afterBlack, func(view *snapshotView) { view.WhiteUserID = stringPointer(whiteActor) })},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, _, err := rules.Apply(test.snapshot, blackActor, moveAction(8, 8))
			if !errors.Is(err, games.ErrInvalidSnapshot) || err.Error() != games.ErrInvalidSnapshot.Error() {
				t.Fatalf("Apply error = %v, want safe invalid snapshot", err)
			}
		})
	}

	// The stricter presence invariant must preserve lazy black/white binding.
	event, first, err := rules.Apply(initial, blackActor, moveAction(1, 1))
	if err != nil || event.ActorID != blackActor {
		t.Fatalf("lazy black binding: event=%#v err=%v", event, err)
	}
	_, second, err := rules.Apply(first, whiteActor, moveAction(2, 1))
	if err != nil {
		t.Fatalf("lazy white binding: %v", err)
	}
	view := decodeSnapshotView(t, second)
	assertStringPointer(t, view.BlackUserID, blackActor, "blackUserId")
	assertStringPointer(t, view.WhiteUserID, whiteActor, "whiteUserId")
	assertStringPointer(t, actorForNextColor(view), blackActor, "next actor")
}

func TestRulesInstancesHaveNoSharedMutableState(t *testing.T) {
	const workers = 32
	var wg sync.WaitGroup
	errorsCh := make(chan error, workers)
	for worker := 0; worker < workers; worker++ {
		wg.Add(1)
		go func(index int) {
			defer wg.Done()
			rules := NewRules()
			snapshot, err := rules.Rebuild(nil)
			if err == nil {
				_, snapshot, err = rules.Apply(snapshot, fmt.Sprintf("actor-%d", index), moveAction(index%15, index/15))
			}
			if err != nil || snapshot.Revision != 1 {
				errorsCh <- fmt.Errorf("worker %d: revision=%d err=%v", index, snapshot.Revision, err)
			}
		}(worker)
	}
	wg.Wait()
	close(errorsCh)
	for err := range errorsCh {
		t.Error(err)
	}
}

func moveAction(x, y int) games.Action {
	return games.Action{Type: MoveRequested, Payload: json.RawMessage(fmt.Sprintf(`{"x":%d,"y":%d}`, x, y))}
}

func acceptedPayload(x, y int, color, userID string) json.RawMessage {
	return json.RawMessage(fmt.Sprintf(`{"x":%d,"y":%d,"color":%q,"userId":%q}`, x, y, color, userID))
}

func mustApply(t *testing.T, rules games.Rules, snapshot games.Snapshot, actor string, point Point) (games.Event, games.Snapshot) {
	t.Helper()
	event, next, err := rules.Apply(snapshot, actor, moveAction(point.X, point.Y))
	if err != nil {
		t.Fatalf("Apply(%s, %v): %v", actor, point, err)
	}
	return event, next
}

func decodeSnapshotView(t *testing.T, snapshot games.Snapshot) snapshotView {
	t.Helper()
	var view snapshotView
	decoder := json.NewDecoder(bytes.NewReader(snapshot.State))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&view); err != nil {
		t.Fatalf("decode snapshot: %v\n%s", err, snapshot.State)
	}
	return view
}

func snapshotWith(t *testing.T, stones []Stone, next Color, blackID, whiteID string) games.Snapshot {
	t.Helper()
	stones = append([]Stone(nil), stones...)
	blackCount, whiteCount := 0, 0
	for _, stone := range stones {
		if stone.Color == Black {
			blackCount++
		} else if stone.Color == White {
			whiteCount++
		}
	}
	whiteFillers := []Point{{0, 12}, {2, 12}, {4, 12}, {6, 12}, {8, 12}, {10, 12}, {12, 12}, {14, 12}, {1, 14}, {3, 14}}
	blackFillers := []Point{{1, 13}, {3, 13}, {5, 13}, {7, 13}, {9, 13}, {11, 13}, {13, 13}, {0, 14}, {2, 14}, {4, 14}}
	targetDelta := 0
	if next == White {
		targetDelta = 1
	}
	for blackCount-whiteCount > targetDelta {
		point := whiteFillers[whiteCount]
		stones = append(stones, Stone{X: point.X, Y: point.Y, Color: White})
		whiteCount++
	}
	for blackCount-whiteCount < targetDelta {
		point := blackFillers[blackCount]
		stones = append(stones, Stone{X: point.X, Y: point.Y, Color: Black})
		blackCount++
	}
	board := make([]int, 225)
	for _, stone := range stones {
		if stone.X < 0 || stone.X >= 15 || stone.Y < 0 || stone.Y >= 15 || board[stone.Y*15+stone.X] != 0 {
			t.Fatalf("invalid test stone: %#v", stone)
		}
		board[stone.Y*15+stone.X] = int(stone.Color)
	}
	nextColor := "black"
	if next == White {
		nextColor = "white"
	}
	state := snapshotView{
		BoardSize: 15, Board: board, NextColor: nextColor,
		BlackUserID: &blackID, WhiteUserID: &whiteID, Status: "active",
	}
	encoded, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	return games.Snapshot{Revision: int64(len(stones)), State: encoded}
}

func longestRun(colors [225]Color, direction Point) int {
	longest := 0
	for y := 0; y < 15; y++ {
		for x := 0; x < 15; x++ {
			previousX, previousY := x-direction.X, y-direction.Y
			if previousX >= 0 && previousX < 15 && previousY >= 0 && previousY < 15 && colors[previousY*15+previousX] == colors[y*15+x] {
				continue
			}
			length := 0
			for currentX, currentY := x, y; currentX >= 0 && currentX < 15 && currentY >= 0 && currentY < 15 && colors[currentY*15+currentX] == colors[y*15+x]; currentX, currentY = currentX+direction.X, currentY+direction.Y {
				length++
			}
			if length > longest {
				longest = length
			}
		}
	}
	return longest
}

func winningEventStream(t *testing.T) []games.Event {
	t.Helper()
	rules := NewRules()
	snapshot, _ := rules.Rebuild(nil)
	steps := []struct {
		actor string
		point Point
	}{
		{blackActor, Point{0, 0}}, {whiteActor, Point{0, 1}},
		{blackActor, Point{1, 0}}, {whiteActor, Point{1, 1}},
		{blackActor, Point{2, 0}}, {whiteActor, Point{2, 1}},
		{blackActor, Point{3, 0}}, {whiteActor, Point{3, 1}},
		{blackActor, Point{4, 0}},
	}
	events := make([]games.Event, 0, len(steps))
	for _, step := range steps {
		event, next, err := rules.Apply(snapshot, step.actor, moveAction(step.point.X, step.point.Y))
		if err != nil {
			t.Fatalf("build winning events: %v", err)
		}
		events = append(events, event)
		snapshot = next
	}
	return events
}

func assertStringPointer(t *testing.T, got *string, want, field string) {
	t.Helper()
	if got == nil || *got != want {
		t.Fatalf("%s = %v, want %q", field, got, want)
	}
}

func pointerEquals(got *string, want string) bool {
	return got != nil && *got == want
}

func occupiedCount(cells []int) int {
	count := 0
	for _, cell := range cells {
		if cell != 0 {
			count++
		}
	}
	return count
}

func replaceSnapshotBoard(t *testing.T, state json.RawMessage, cells []int) json.RawMessage {
	t.Helper()
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(state, &fields); err != nil {
		t.Fatal(err)
	}
	board, err := json.Marshal(cells)
	if err != nil {
		t.Fatal(err)
	}
	fields["board"] = board
	encoded, err := json.Marshal(fields)
	if err != nil {
		t.Fatal(err)
	}
	return encoded
}

func rewriteSnapshot(t *testing.T, snapshot games.Snapshot, mutate func(*snapshotView)) games.Snapshot {
	t.Helper()
	view := decodeSnapshotView(t, snapshot)
	mutate(&view)
	encoded, err := json.Marshal(view)
	if err != nil {
		t.Fatal(err)
	}
	return games.Snapshot{Revision: snapshot.Revision, State: encoded}
}

func fullDrawSnapshotWithBlackLine(t *testing.T) games.Snapshot {
	t.Helper()
	board := make([]int, 225)
	for y := 0; y < 15; y++ {
		for x := 0; x < 15; x++ {
			color := int(White)
			if ((x + 2*y) % 4) < 2 {
				color = int(Black)
			}
			board[y*15+x] = color
		}
	}
	// Turn two white cells in row zero black to create five, then swap two
	// remote black cells to white so the required 113/112 counts remain.
	board[0*15+2] = int(Black)
	board[0*15+3] = int(Black)
	board[2*15+0] = int(White)
	board[2*15+1] = int(White)
	view := snapshotView{
		Status: "active", Board: board, BoardSize: 15,
		BlackUserID: stringPointer(blackActor), WhiteUserID: stringPointer(whiteActor),
		NextColor: "white",
	}
	encoded, err := json.Marshal(view)
	if err != nil {
		t.Fatal(err)
	}
	return games.Snapshot{Revision: 225, State: encoded}
}

func actorForNextColor(view snapshotView) *string {
	if view.NextColor == "black" {
		return view.BlackUserID
	}
	return view.WhiteUserID
}

func stringPointer(value string) *string {
	return &value
}
