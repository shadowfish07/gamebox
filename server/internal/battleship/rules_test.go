package battleship

import (
	"encoding/json"
	"errors"
	"testing"
)

func fleet() []Ship {
	return []Ship{{0, 0, false}, {10, 1, false}, {20, 2, false}, {30, 3, false}, {40, 4, false}}
}
func TestPlacementAndHiddenInformation(t *testing.T) {
	s := newState("a", "b", 0)
	if err := s.apply(0, Action{Kind: "ready", Ships: fleet()}); err != nil {
		t.Fatal(err)
	}
	v := s.view(1)
	if len(v.EnemyShips) != 0 || !v.EnemyReady {
		t.Fatal("placement leaked or readiness missing")
	}
	if err := s.apply(0, Action{Kind: "save", Ships: fleet()}); err == nil {
		t.Fatal("ready fleet changed")
	}
	invalid := fleet()
	invalid[1].Cell = 0
	if err := s.apply(1, Action{Kind: "ready", Ships: invalid}); err == nil {
		t.Fatal("overlap accepted")
	}
	invalid = fleet()
	invalid[0].Cell = 9
	if err := s.apply(1, Action{Kind: "ready", Ships: invalid}); err == nil {
		t.Fatal("wrap accepted")
	}
	if err := s.apply(1, Action{Kind: "ready", Ships: fleet()}); err != nil {
		t.Fatal(err)
	}
	if s.Phase != "battle" || s.Turn != 0 {
		t.Fatal(s)
	}
	if err := s.apply(1, Action{Kind: "fire", Cell: 0}); err == nil {
		t.Fatal("out of turn")
	}
	if err := s.apply(0, Action{Kind: "fire", Cell: 0}); err != nil {
		t.Fatal(err)
	}
	if s.Turn != 1 || len(s.view(0).EnemyShips) != 0 {
		t.Fatal("hit leaked fleet or gave extra turn")
	}
	if err := s.apply(1, Action{Kind: "fire", Cell: 99}); err != nil {
		t.Fatal(err)
	}
	if err := s.apply(0, Action{Kind: "fire", Cell: 0}); err == nil {
		t.Fatal("duplicate hit")
	}
}
func TestSinkWinAndCancellation(t *testing.T) {
	s := newState("a", "b", 0)
	for i := 0; i < 2; i++ {
		if err := s.apply(i, Action{Kind: "ready", Ships: fleet()}); err != nil {
			t.Fatal(err)
		}
	}
	miss := 50
	for _, ship := range fleet() {
		for _, cell := range ship.cells() {
			if err := s.apply(0, Action{Kind: "fire", Cell: cell}); err != nil {
				t.Fatal(err)
			}
			if s.Phase != "finished" {
				if err := s.apply(1, Action{Kind: "fire", Cell: miss}); err != nil {
					t.Fatal(err)
				}
				miss++
			}
		}
	}
	if s.Winner != "a" || len(s.view(0).EnemyShips) != 5 {
		t.Fatal(s)
	}
	if err := s.apply(1, Action{Kind: "fire", Cell: 90}); err == nil {
		t.Fatal("post-terminal shot")
	}
	s = newState("a", "b", 1)
	for i := 0; i < 2; i++ {
		_ = s.apply(i, Action{Kind: "ready", Ships: fleet()})
	}
	if err := s.apply(0, Action{Kind: "cancel"}); err == nil {
		t.Fatal("unilateral battle cancel")
	}
	_ = s.apply(0, Action{Kind: "offer_end"})
	if s.Phase != "battle" {
		t.Fatal("offer ended match")
	}
	_ = s.apply(1, Action{Kind: "offer_end"})
	if s.Phase != "cancelled" || s.Winner != "" {
		t.Fatal(s)
	}
}

func TestUnusedActionFieldsCannotChangeState(t *testing.T) {
	for _, kind := range []string{"save", "ready", "fire", "cancel", "resign", "offer_end", "decline_end", "rematch"} {
		for _, field := range []string{"ships", "cell"} {
			if (kind == "save" || kind == "ready") && field == "ships" || kind == "fire" && field == "cell" {
				continue
			}
			t.Run(kind+"/"+field, func(t *testing.T) {
				s := newState("a", "b", 0)
				a := Action{Kind: kind}
				switch kind {
				case "save", "ready":
					a.Ships = fleet()
				case "fire", "resign", "offer_end", "decline_end":
					for p := 0; p < 2; p++ {
						if err := s.apply(p, Action{Kind: "ready", Ships: fleet()}); err != nil {
							t.Fatal(err)
						}
					}
					if kind == "decline_end" {
						s.EndOffer = "b"
					}
				case "rematch":
					s.Phase = "cancelled"
				}
				before, _ := json.Marshal(s)
				malformed := a
				if field == "ships" {
					malformed.Ships = fleet()
				} else {
					malformed.Cell = 99
				}
				if err := s.apply(0, malformed); !errors.Is(err, ErrInvalid) {
					t.Errorf("malformed %s: %v", kind, err)
				}
				after, _ := json.Marshal(s)
				if string(before) != string(after) {
					t.Error("malformed payload changed authoritative state")
				}
				if err := s.apply(0, a); err != nil {
					t.Fatalf("valid action rejected: %v", err)
				}
			})
		}
	}
}
