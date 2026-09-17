// Package battleship owns durable asynchronous matches and private fleet views.
package battleship

import "errors"

var ErrInvalid = errors.New("invalid battleship action")
var ErrConflict = errors.New("battleship state changed")
var ErrNotFound = errors.New("battleship match not found")
var lengths = [5]int{5, 4, 3, 3, 2}

type Ship struct {
	Cell     int  `json:"cell"`
	ID       int  `json:"id"`
	Vertical bool `json:"vertical"`
}

func (s Ship) cells() []int {
	if s.ID < 0 || s.ID >= len(lengths) {
		return nil
	}
	cells := make([]int, lengths[s.ID])
	step := 1
	if s.Vertical {
		step = 10
	}
	for i := range cells {
		cells[i] = s.Cell + i*step
	}
	return cells
}
func validFleet(ships []Ship, complete bool) bool {
	if len(ships) > 5 || complete && len(ships) != 5 {
		return false
	}
	seen := map[int]bool{}
	occupied := map[int]bool{}
	for _, s := range ships {
		if s.ID < 0 || s.ID >= 5 || seen[s.ID] || s.Cell < 0 || s.Cell >= 100 {
			return false
		}
		seen[s.ID] = true
		for _, c := range s.cells() {
			if c >= 100 || !s.Vertical && c/10 != s.Cell/10 || occupied[c] {
				return false
			}
			occupied[c] = true
		}
	}
	return true
}

type Shot struct {
	Cell int  `json:"cell"`
	Hit  bool `json:"hit"`
}
type Action struct {
	ActionID string `json:"actionId"`
	Revision int64  `json:"revision"`
	Kind     string `json:"kind"`
	Ships    []Ship `json:"ships"`
	Cell     int    `json:"cell"`
}
type State struct {
	Players     [2]string `json:"players"`
	Ships       [2][]Ship `json:"ships"`
	Ready       [2]bool   `json:"ready"`
	Shots       [2][]Shot `json:"shots"`
	Phase       string    `json:"phase"`
	First       int       `json:"first"`
	Turn        int       `json:"turn"`
	Winner      string    `json:"winner"`
	EndOffer    string    `json:"endOffer"`
	Rematch     [2]bool   `json:"rematch"`
	NextMatchID string    `json:"nextMatchId"`
}
type View struct {
	ID                    string `json:"id"`
	Revision              int64  `json:"revision"`
	OpponentID            string `json:"opponentId"`
	OpponentName          string `json:"opponentName"`
	Phase                 string `json:"phase"`
	YourTurn              bool   `json:"yourTurn"`
	Ready                 bool   `json:"ready"`
	EnemyReady            bool   `json:"enemyReady"`
	OwnShips              []Ship `json:"ownShips"`
	EnemyShips            []Ship `json:"enemyShips"`
	Shots                 []Shot `json:"shots"`
	Incoming              []Shot `json:"incoming"`
	Winner                string `json:"winner"`
	EndOffer              string `json:"endOffer"`
	RematchRequested      bool   `json:"rematchRequested"`
	EnemyRematchRequested bool   `json:"enemyRematchRequested"`
	NextMatchID           string `json:"nextMatchId"`
}

func newState(a, b string, first int) State {
	return State{Players: [2]string{a, b}, Phase: "placement", First: first, Turn: first}
}
func (s State) player(user string) int {
	for i, p := range s.Players {
		if p == user {
			return i
		}
	}
	return -1
}
func sunk(ship Ship, shots []Shot) bool {
	for _, c := range ship.cells() {
		found := false
		for _, shot := range shots {
			if shot.Cell == c && shot.Hit {
				found = true
			}
		}
		if !found {
			return false
		}
	}
	return true
}
func (s State) view(p int) View {
	enemy := 1 - p
	visible := []Ship{}
	for _, ship := range s.Ships[enemy] {
		if s.Phase == "finished" || s.Phase == "cancelled" || sunk(ship, s.Shots[p]) {
			visible = append(visible, ship)
		}
	}
	return View{OpponentID: s.Players[enemy], Phase: s.Phase, YourTurn: s.Phase == "battle" && s.Turn == p, Ready: s.Ready[p], EnemyReady: s.Ready[enemy], OwnShips: append([]Ship{}, s.Ships[p]...), EnemyShips: visible, Shots: append([]Shot{}, s.Shots[p]...), Incoming: append([]Shot{}, s.Shots[enemy]...), Winner: s.Winner, EndOffer: s.EndOffer, RematchRequested: s.Rematch[p], EnemyRematchRequested: s.Rematch[enemy], NextMatchID: s.NextMatchID}
}
func (s *State) apply(p int, a Action) error {
	if p < 0 || p > 1 {
		return ErrNotFound
	}
	// Reject mixed payloads before touching authority, matching the HTTP contract.
	if a.Kind != "fire" && a.Cell != 0 || a.Kind != "save" && a.Kind != "ready" && len(a.Ships) != 0 {
		return ErrInvalid
	}
	switch a.Kind {
	case "save", "ready":
		if s.Phase != "placement" || s.Ready[p] || !validFleet(a.Ships, a.Kind == "ready") {
			return ErrInvalid
		}
		s.Ships[p] = append([]Ship{}, a.Ships...)
		s.Ready[p] = a.Kind == "ready"
		if s.Ready[0] && s.Ready[1] {
			s.Phase = "battle"
		}
	case "fire":
		if s.Phase != "battle" || s.Turn != p || a.Cell < 0 || a.Cell >= 100 {
			return ErrInvalid
		}
		for _, shot := range s.Shots[p] {
			if shot.Cell == a.Cell {
				return ErrInvalid
			}
		}
		hit := false
		for _, ship := range s.Ships[1-p] {
			for _, c := range ship.cells() {
				if c == a.Cell {
					hit = true
				}
			}
		}
		s.Shots[p] = append(s.Shots[p], Shot{a.Cell, hit})
		s.Turn = 1 - p
		all := true
		for _, ship := range s.Ships[1-p] {
			if !sunk(ship, s.Shots[p]) {
				all = false
			}
		}
		if all {
			s.Phase = "finished"
			s.Winner = s.Players[p]
			s.EndOffer = ""
		}
	case "cancel":
		if s.Phase != "placement" {
			return ErrInvalid
		}
		s.Phase = "cancelled"
	case "resign":
		if s.Phase != "battle" {
			return ErrInvalid
		}
		s.Phase = "finished"
		s.Winner = s.Players[1-p]
		s.EndOffer = ""
	case "offer_end":
		if s.Phase != "battle" || s.EndOffer == s.Players[p] {
			return ErrInvalid
		}
		if s.EndOffer != "" {
			s.Phase = "cancelled"
			s.EndOffer = ""
		} else {
			s.EndOffer = s.Players[p]
		}
	case "decline_end":
		if s.Phase != "battle" || s.EndOffer == "" {
			return ErrInvalid
		}
		s.EndOffer = ""
	case "rematch":
		if s.Phase != "finished" && s.Phase != "cancelled" || s.Rematch[p] {
			return ErrInvalid
		}
		s.Rematch[p] = true
	default:
		return ErrInvalid
	}
	return nil
}
