package reversi

import (
	"bytes"
	"encoding/json"
	"math/rand"
	"me.zqydev/gamebox/server/internal/games/gameapi"
	"testing"
)

func TestOpeningAndIllegalActions(t *testing.T) {
	r := NewRules()
	s, _ := r.Rebuild(nil)
	st, _ := decodeSnapshot(s)
	if len(st.LegalMoves) != 4 || st.Board[27] != 2 || st.Board[28] != 1 {
		t.Fatal(st)
	}
	for _, payload := range []string{`{}`, `{"x":0,"y":0}`, `{"x":3,"y":3}`, `{"x":-1,"y":3}`, `{"x":3,"y":2,"color":"white"}`, `{"x":3,"x":2,"y":2}`, `{"x":null,"y":2}`} {
		if _, _, err := r.Apply(s, "black", gameapi.Action{Type: MoveRequested, Payload: []byte(payload)}); err == nil {
			t.Fatalf("accepted %s", payload)
		}
	}
	_, next, err := r.Apply(s, "black", move(3, 2))
	if err != nil {
		t.Fatal(err)
	}
	st, _ = decodeSnapshot(next)
	if st.Board[27] != 1 || st.BlackCount != 4 || st.WhiteCount != 1 || st.NextColor != "white" {
		t.Fatal(st)
	}
	if _, _, err = r.Apply(next, "black", move(2, 2)); err == nil {
		t.Fatal("same actor took other color")
	}
}
func move(x, y int) gameapi.Action {
	p, _ := json.Marshal(Point{X: x, Y: y})
	return gameapi.Action{Type: MoveRequested, Payload: p}
}

func TestEightDirectionsAndNoChain(t *testing.T) {
	var b [64]uint8
	for dy := -1; dy <= 1; dy++ {
		for dx := -1; dx <= 1; dx++ {
			if dx == 0 && dy == 0 {
				continue
			}
			b[(3+dy)*8+3+dx] = 2
			b[(3+2*dy)*8+3+2*dx] = 1
		}
	}
	if got := flips(b, Point{3, 3}, 1); len(got) != 8 {
		t.Fatal(got)
	}
	// A newly flipped neighbor must not trigger a perpendicular chain.
	b = [64]uint8{}
	b[3*8+4] = 2
	b[3*8+5] = 1
	b[4*8+4] = 2
	b[5*8+4] = 1
	got := flips(b, Point{3, 3}, 1)
	if len(got) != 1 || got[0] != 28 {
		t.Fatal(got)
	}
	b[3*8+4] = 0
	if len(flips(b, Point{3, 3}, 1)) != 0 {
		t.Fatal("jumped empty")
	}
}
func TestCompleteGamesReplayPassAndScoring(t *testing.T) {
	sawPass, sawEarly, sawDraw := false, false, false
	for seed := int64(0); seed < 300; seed++ {
		r := NewRules()
		s, _ := r.Rebuild(nil)
		events := []gameapi.Event{}
		rng := rand.New(rand.NewSource(seed))
		for {
			st, err := decodeSnapshot(s)
			if err != nil {
				t.Fatal(err)
			}
			if st.Status == "finished" {
				sawEarly = sawEarly || st.BlackCount+st.WhiteCount < 64
				sawDraw = sawDraw || st.Result != nil && *st.Result == "draw"
				if st.BlackCount == st.WhiteCount && st.WinnerUserID != nil {
					t.Fatal("draw winner")
				}
				break
			}
			p := st.LegalMoves[rng.Intn(len(st.LegalMoves))]
			e, next, err := r.Apply(s, st.NextColor, move(p.X, p.Y))
			if err != nil {
				t.Fatal(err)
			}
			events = append(events, e)
			s = next
			nextSt, _ := decodeSnapshot(s)
			sawPass = sawPass || nextSt.PassedColor != nil
		}
		replay, err := r.Rebuild(events)
		if err != nil || !bytes.Equal(replay.State, s.State) {
			t.Fatal("replay mismatch", err)
		}
		events[0].Revision = 2
		if _, err = r.Rebuild(events); err == nil {
			t.Fatal("corrupt history accepted")
		}
	}
	if !sawPass || !sawEarly || !sawDraw {
		t.Fatalf("coverage pass=%v early=%v draw=%v", sawPass, sawEarly, sawDraw)
	}
}
