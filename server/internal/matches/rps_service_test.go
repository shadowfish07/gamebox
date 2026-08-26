package matches

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"testing"

	"me.zqydev/gamebox/server/internal/games/rps"
)

func createRps(t *testing.T, format string) (fixture, *Service, Match) {
	t.Helper()
	fixture := newFixture(t)
	service := fixture.service(t, bytes.NewReader([]byte{0}))
	match, err := service.CreateWithConfig(context.Background(), rps.GameID, initiatorID, opponentID, json.RawMessage(`{"format":"`+format+`"}`))
	if err != nil {
		t.Fatal(err)
	}
	return fixture, service, match
}

func rpsAction(match Match, actor string, revision int64, sequence int, choice string) ActionRequest {
	return ActionRequest{
		MatchID: match.ID, ActorUserID: actor,
		ActionID:         fmt.Sprintf("aaaaaaaa-aaaa-4aaa-8aaa-%012d", sequence),
		ExpectedRevision: revision, Type: rps.ChoiceRequested,
		Payload: json.RawMessage(`{"choice":"` + choice + `"}`),
	}
}

func TestRpsCreatePersistsImmutableConfigAndRequiresIt(t *testing.T) {
	fixture := newFixture(t)
	service := fixture.service(t, bytes.NewReader([]byte{0}))
	if _, err := service.Create(context.Background(), rps.GameID, initiatorID, opponentID); !errors.Is(err, ErrInvalidRequest) {
		t.Fatalf("missing config error=%v", err)
	}
	match, err := service.CreateWithConfig(context.Background(), rps.GameID, initiatorID, opponentID, json.RawMessage(`{ "format" : "best_of_three" }`))
	if err != nil {
		t.Fatal(err)
	}
	if string(match.GameConfig) != `{"format":"best_of_three"}` {
		t.Fatalf("config=%s", match.GameConfig)
	}
	var stored string
	if err := fixture.db.QueryRow(`SELECT game_config_json FROM matches WHERE id=?`, match.ID).Scan(&stored); err != nil || stored != `{"format":"best_of_three"}` {
		t.Fatalf("stored=(%q,%v)", stored, err)
	}
}

func TestRpsSealedChoiceDrawAndBestOfThreeCompletion(t *testing.T) {
	_, service, match := createRps(t, rps.FormatBestOfThree)
	sequence := 1
	apply := func(actor, choice string, revision int64) (Event, Snapshot) {
		event, snapshot, err := service.ApplyAction(context.Background(), rpsAction(match, actor, revision, sequence, choice))
		sequence++
		if err != nil {
			t.Fatal(err)
		}
		return event, snapshot
	}

	locked, snapshot := apply(initiatorID, rps.Rock, 0)
	if locked.Type != rps.ChoiceLocked || bytes.Contains(eventEnvelopeBytes(t, rps.GameID, locked), []byte(`"choice"`)) {
		t.Fatalf("lock leaked: event=%s wire=%s", locked.Payload, eventEnvelopeBytes(t, rps.GameID, locked))
	}
	_, snapshot = apply(opponentID, rps.Rock, 1)
	if snapshot.Match.Status != StatusActive || snapshot.Match.Revision != 2 {
		t.Fatalf("draw snapshot=%+v", snapshot.Match)
	}
	_, _ = apply(initiatorID, rps.Paper, 2)
	_, snapshot = apply(opponentID, rps.Rock, 3)
	_, _ = apply(initiatorID, rps.Scissors, 4)
	revealed, snapshot := apply(opponentID, rps.Paper, 5)
	if revealed.Type != rps.RoundRevealed || snapshot.Match.Status != StatusFinished || snapshot.Match.Result == nil || *snapshot.Match.Result != ResultRounds || snapshot.Match.WinnerUserID == nil || *snapshot.Match.WinnerUserID != initiatorID {
		t.Fatalf("terminal event=%s match=%+v", revealed.Payload, snapshot.Match)
	}
}

func TestRpsRejectsDuplicateChoiceAndPostTerminalAction(t *testing.T) {
	_, service, match := createRps(t, rps.FormatSingleRound)
	if _, _, err := service.ApplyAction(context.Background(), rpsAction(match, initiatorID, 0, 1, rps.Rock)); err != nil {
		t.Fatal(err)
	}
	if _, _, err := service.ApplyAction(context.Background(), rpsAction(match, initiatorID, 1, 2, rps.Paper)); !errors.Is(err, rps.ErrChoiceLocked) {
		t.Fatalf("duplicate error=%v", err)
	}
	if _, _, err := service.ApplyAction(context.Background(), rpsAction(match, opponentID, 1, 3, rps.Scissors)); err != nil {
		t.Fatal(err)
	}
	if _, _, err := service.ApplyAction(context.Background(), rpsAction(match, initiatorID, 2, 4, rps.Paper)); !errors.Is(err, ErrInvalidRequest) {
		t.Fatalf("post-terminal error=%v", err)
	}
}

func TestRpsAcceptsSecondSimultaneousChoiceFromPreviousRevision(t *testing.T) {
	_, service, match := createRps(t, rps.FormatBestOfThree)
	if _, _, err := service.ApplyAction(context.Background(), rpsAction(match, initiatorID, 0, 1, rps.Rock)); err != nil {
		t.Fatal(err)
	}
	event, snapshot, err := service.ApplyAction(context.Background(), rpsAction(match, opponentID, 0, 2, rps.Scissors))
	if err != nil {
		t.Fatal(err)
	}
	if event.Type != rps.RoundRevealed || snapshot.Match.Revision != 2 {
		t.Fatalf("event=%s revision=%d", event.Type, snapshot.Match.Revision)
	}
	if _, _, err := service.ApplyAction(context.Background(), rpsAction(match, initiatorID, 1, 3, rps.Paper)); !errors.Is(err, ErrStaleRevision) {
		t.Fatalf("same actor stale duplicate error=%v", err)
	}
}

func TestRpsStopsStartingRoundsBeforeEventHistoryLimit(t *testing.T) {
	_, service, match := createRps(t, rps.FormatBestOfThree)
	sequence := 1
	for revision := int64(0); revision < maximumMatchEvents-2; revision += 2 {
		if _, _, err := service.ApplyAction(context.Background(), rpsAction(match, initiatorID, revision, sequence, rps.Rock)); err != nil {
			t.Fatalf("first choice revision=%d: %v", revision, err)
		}
		sequence++
		if _, _, err := service.ApplyAction(context.Background(), rpsAction(match, opponentID, revision+1, sequence, rps.Rock)); err != nil {
			t.Fatalf("second choice revision=%d: %v", revision+1, err)
		}
		sequence++
	}
	snapshot, err := service.Snapshot(context.Background(), match.ID)
	if err != nil {
		t.Fatal(err)
	}
	if snapshot.Match.Revision != maximumMatchEvents-2 {
		t.Fatalf("revision=%d", snapshot.Match.Revision)
	}
	if _, _, err := service.ApplyAction(context.Background(), rpsAction(match, initiatorID, maximumMatchEvents-2, sequence, rps.Paper)); !errors.Is(err, ErrInvalidRequest) {
		t.Fatalf("limit error=%v", err)
	}
	if _, err := service.Snapshot(context.Background(), match.ID); err != nil {
		t.Fatalf("history became unreadable: %v", err)
	}
}

func TestRpsSnapshotHidesOpponentChoiceUntilReveal(t *testing.T) {
	_, service, match := createRps(t, rps.FormatBestOfThree)
	if _, _, err := service.ApplyAction(context.Background(), rpsAction(match, initiatorID, 0, 1, rps.Rock)); err != nil {
		t.Fatal(err)
	}
	snapshot, err := service.Snapshot(context.Background(), match.ID)
	if err != nil {
		t.Fatal(err)
	}
	initiatorWire, err := snapshotEnvelope(snapshot, initiatorID)
	if err != nil {
		t.Fatal(err)
	}
	opponentWire, err := snapshotEnvelope(snapshot, opponentID)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(initiatorWire, []byte(`"choice":"rock"`)) || bytes.Contains(opponentWire, []byte(`"choice"`)) || bytes.Contains(opponentWire, []byte(`rock`)) {
		t.Fatalf("secrecy failed\ninitiator=%s\nopponent=%s", initiatorWire, opponentWire)
	}
}

func eventEnvelopeBytes(t *testing.T, gameID string, event Event) []byte {
	t.Helper()
	data, err := eventEnvelope(gameID, event)
	if err != nil {
		t.Fatal(err)
	}
	return data
}
