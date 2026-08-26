package rps

import (
	"encoding/json"
	"errors"
	"testing"

	"me.zqydev/gamebox/server/internal/games/gameapi"
)

const (
	alice = "11111111-1111-4111-8111-111111111111"
	bob   = "22222222-2222-4222-8222-222222222222"
)

func configured(t *testing.T, format string) gameapi.Rules {
	t.Helper()
	rules, err := NewRules().Configure(json.RawMessage(`{"format":"` + format + `"}`))
	if err != nil {
		t.Fatal(err)
	}
	return rules
}

func choose(t *testing.T, rules gameapi.Rules, snapshot gameapi.Snapshot, actor, choice string) (gameapi.Event, gameapi.Snapshot) {
	t.Helper()
	event, next, err := rules.Apply(snapshot, actor, gameapi.Action{Type: ChoiceRequested, Payload: json.RawMessage(`{"choice":"` + choice + `"}`)})
	if err != nil {
		t.Fatal(err)
	}
	return event, next
}

func TestConfigureRejectsNonCanonicalFormats(t *testing.T) {
	for _, raw := range []string{"", `{}`, `{"format":"best_of_five"}`, `{"format":"single_round","extra":true}`, `{"format":"single_round","format":"best_of_three"}`} {
		if _, err := NewRules().Configure(json.RawMessage(raw)); !errors.Is(err, ErrInvalidFormat) {
			t.Fatalf("Configure(%q) error=%v", raw, err)
		}
	}
}

func TestEveryHandComparisonAndDraw(t *testing.T) {
	tests := []struct {
		left, right string
		winner      *string
	}{
		{Rock, Rock, nil}, {Paper, Paper, nil}, {Scissors, Scissors, nil},
		{Rock, Scissors, stringPointer(alice)}, {Scissors, Rock, stringPointer(bob)},
		{Paper, Rock, stringPointer(alice)}, {Rock, Paper, stringPointer(bob)},
		{Scissors, Paper, stringPointer(alice)}, {Paper, Scissors, stringPointer(bob)},
	}
	for _, test := range tests {
		t.Run(test.left+"_"+test.right, func(t *testing.T) {
			rules := configured(t, FormatBestOfThree)
			first, snapshot := choose(t, rules, gameapi.Snapshot{}, alice, test.left)
			if first.Type != ChoiceLocked {
				t.Fatalf("first type=%s", first.Type)
			}
			second, snapshot := choose(t, rules, snapshot, bob, test.right)
			if second.Type != RoundRevealed {
				t.Fatalf("second type=%s", second.Type)
			}
			var state state
			if json.Unmarshal(snapshot.State, &state) != nil || state.LastReveal == nil {
				t.Fatalf("state=%s", snapshot.State)
			}
			got := state.LastReveal.RoundWinnerUserID
			if got == nil && test.winner != nil || got != nil && (test.winner == nil || *got != *test.winner) {
				t.Fatalf("winner=%v want=%v", got, test.winner)
			}
		})
	}
}

func TestSingleRoundFinishesOnFirstNonDraw(t *testing.T) {
	rules := configured(t, FormatSingleRound)
	_, snapshot := choose(t, rules, gameapi.Snapshot{}, alice, Rock)
	_, snapshot = choose(t, rules, snapshot, bob, Scissors)
	var state state
	_ = json.Unmarshal(snapshot.State, &state)
	if state.Status != "finished" || state.WinnerUserID == nil || *state.WinnerUserID != alice || state.Result == nil || *state.Result != "rounds" {
		t.Fatalf("terminal state=%s", snapshot.State)
	}
	if _, _, err := rules.Apply(snapshot, bob, gameapi.Action{Type: ChoiceRequested, Payload: json.RawMessage(`{"choice":"paper"}`)}); !errors.Is(err, ErrMatchFinished) {
		t.Fatalf("post-terminal error=%v", err)
	}
}

func TestBestOfThreeIgnoresDrawsAndNeedsTwoWins(t *testing.T) {
	rules := configured(t, FormatBestOfThree)
	snapshot := gameapi.Snapshot{}
	for _, round := range [][2]string{{Rock, Rock}, {Paper, Rock}, {Scissors, Paper}} {
		_, snapshot = choose(t, rules, snapshot, alice, round[0])
		_, snapshot = choose(t, rules, snapshot, bob, round[1])
	}
	var state state
	_ = json.Unmarshal(snapshot.State, &state)
	if state.Status != "finished" || state.Scores[alice] != 2 || state.Scores[bob] != 0 || state.Round != 3 {
		t.Fatalf("state=%s", snapshot.State)
	}
}

func TestDuplicateInvalidAndReplay(t *testing.T) {
	rules := configured(t, FormatBestOfThree)
	first, snapshot := choose(t, rules, gameapi.Snapshot{}, alice, Rock)
	if _, _, err := rules.Apply(snapshot, alice, gameapi.Action{Type: ChoiceRequested, Payload: json.RawMessage(`{"choice":"paper"}`)}); !errors.Is(err, ErrChoiceLocked) {
		t.Fatalf("duplicate error=%v", err)
	}
	if _, _, err := rules.Apply(snapshot, bob, gameapi.Action{Type: ChoiceRequested, Payload: json.RawMessage(`{"choice":"lizard"}`)}); !errors.Is(err, ErrInvalidChoice) {
		t.Fatalf("invalid error=%v", err)
	}
	second, final := choose(t, rules, snapshot, bob, Paper)
	rebuilt, err := rules.Rebuild([]gameapi.Event{first, second})
	if err != nil || rebuilt.Revision != final.Revision || string(rebuilt.State) != string(final.State) {
		t.Fatalf("rebuild err=%v\ngot=%s\nwant=%s", err, rebuilt.State, final.State)
	}
}
