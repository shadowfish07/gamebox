package flightchess

import "testing"

func TestFinishIsSixthStepAfterMainRoute(t *testing.T) {
	for _, color := range []string{Black, White} {
		entry := Piece{Zone: ZoneMain, Index: indexForProgress(color, 50)}
		for roll := 1; roll <= 6; roll++ {
			want := Piece{Zone: ZoneHome, Index: roll - 1}
			if roll == 6 {
				want = Piece{Zone: ZoneFinished}
			}
			got, ok := resolveMove(color, entry, roll)
			if !ok || got.to != want {
				t.Fatalf("%s finish entry + %d: got %#v (%v), want %#v", color, roll, got, ok, want)
			}
		}
	}
}
