// Package reversi implements standard 8x8 Othello, including forced passes.
package reversi

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"me.zqydev/gamebox/server/internal/games/gameapi"
	"unicode"
	"unicode/utf8"
)

const (
	GameID        = "reversi"
	BoardSize     = 8
	MoveRequested = "reversi.move.requested"
	MoveAccepted  = "reversi.move.accepted"
)

var ErrNotYourTurn = errors.New("not_your_turn")

type Rules struct{}

func NewRules() *Rules                        { return &Rules{} }
func (*Rules) GameID() string                 { return GameID }
func (*Rules) PlayerLimit() int               { return 2 }
func (*Rules) SingleActiveMatchPerUser() bool { return true }

type Point struct {
	X int `json:"x"`
	Y int `json:"y"`
}
type State struct {
	Status       string    `json:"status"`
	Board        [64]uint8 `json:"board"`
	BoardSize    int       `json:"boardSize"`
	BlackUserID  *string   `json:"blackUserId"`
	WhiteUserID  *string   `json:"whiteUserId"`
	NextColor    string    `json:"nextColor"`
	WinnerUserID *string   `json:"winnerUserId"`
	Result       *string   `json:"result"`
	LegalMoves   []Point   `json:"legalMoves"`
	BlackCount   int       `json:"blackCount"`
	WhiteCount   int       `json:"whiteCount"`
	PassedColor  *string   `json:"passedColor"`
	LastMove     *Point    `json:"lastMove"`
}
type acceptedMove struct {
	X      int    `json:"x"`
	Y      int    `json:"y"`
	Color  string `json:"color"`
	UserID string `json:"userId"`
}

func colorName(c uint8) string {
	if c == 1 {
		return "black"
	}
	return "white"
}
func colorValue(c string) uint8 {
	if c == "black" {
		return 1
	}
	if c == "white" {
		return 2
	}
	return 0
}
func flips(b [64]uint8, p Point, c uint8) []int {
	if p.X < 0 || p.X >= 8 || p.Y < 0 || p.Y >= 8 || b[p.Y*8+p.X] != 0 {
		return nil
	}
	var result []int
	for dy := -1; dy <= 1; dy++ {
		for dx := -1; dx <= 1; dx++ {
			if dx == 0 && dy == 0 {
				continue
			}
			var line []int
			x, y := p.X+dx, p.Y+dy
			for x >= 0 && x < 8 && y >= 0 && y < 8 && b[y*8+x] == 3-c {
				line = append(line, y*8+x)
				x += dx
				y += dy
			}
			if len(line) > 0 && x >= 0 && x < 8 && y >= 0 && y < 8 && b[y*8+x] == c {
				result = append(result, line...)
			}
		}
	}
	return result
}
func legal(b [64]uint8, c uint8) []Point {
	out := make([]Point, 0)
	for y := 0; y < 8; y++ {
		for x := 0; x < 8; x++ {
			p := Point{x, y}
			if len(flips(b, p, c)) > 0 {
				out = append(out, p)
			}
		}
	}
	return out
}
func counts(s *State) {
	s.BlackCount = 0
	s.WhiteCount = 0
	for _, c := range s.Board {
		if c == 1 {
			s.BlackCount++
		}
		if c == 2 {
			s.WhiteCount++
		}
	}
}
func initial() gameapi.Snapshot {
	s := State{Status: "active", BoardSize: 8, NextColor: "black"}
	s.Board[27] = 2
	s.Board[36] = 2
	s.Board[28] = 1
	s.Board[35] = 1
	s.LegalMoves = legal(s.Board, 1)
	counts(&s)
	b, _ := json.Marshal(s)
	return gameapi.Snapshot{State: b}
}
func (*Rules) Rebuild(events []gameapi.Event) (gameapi.Snapshot, error) {
	s := initial()
	r := NewRules()
	for i, e := range events {
		if e.Revision != int64(i+1) || e.Type != MoveAccepted {
			return gameapi.Snapshot{}, gameapi.ErrInvalidEvent
		}
		var p acceptedMove
		if json.Unmarshal(e.Payload, &p) != nil {
			return gameapi.Snapshot{}, gameapi.ErrInvalidEvent
		}
		raw, _ := json.Marshal(Point{p.X, p.Y})
		produced, next, err := r.Apply(s, e.ActorID, gameapi.Action{Type: MoveRequested, Payload: raw})
		if err != nil || !bytes.Equal(produced.Payload, e.Payload) {
			return gameapi.Snapshot{}, gameapi.ErrInvalidEvent
		}
		s = next
	}
	return s, nil
}
func (*Rules) Apply(snapshot gameapi.Snapshot, actor string, a gameapi.Action) (gameapi.Event, gameapi.Snapshot, error) {
	fail := func(err error) (gameapi.Event, gameapi.Snapshot, error) {
		return gameapi.Event{}, gameapi.Snapshot{}, err
	}
	if a.Type != MoveRequested || !validActorID(actor) || len(a.Payload) > 1024 || !utf8.Valid(a.Payload) {
		return fail(gameapi.ErrInvalidAction)
	}
	seen, fields, err := decodeObject(a.Payload, map[string]struct{}{"x": {}, "y": {}})
	if err != nil || len(seen) != 2 {
		return fail(gameapi.ErrInvalidAction)
	}
	x, xe := decodeInteger(fields["x"])
	y, ye := decodeInteger(fields["y"])
	if xe != nil || ye != nil {
		return fail(gameapi.ErrInvalidAction)
	}
	if len(snapshot.State) == 0 && snapshot.Revision == 0 {
		snapshot = initial()
	}
	s, err := decodeSnapshot(snapshot)
	if err != nil {
		return fail(err)
	}
	if s.Status != "active" {
		return fail(gameapi.ErrInvalidAction)
	}
	c := colorValue(s.NextColor)
	own, other := &s.BlackUserID, s.WhiteUserID
	if c == 2 {
		own, other = &s.WhiteUserID, s.BlackUserID
	}
	if *own != nil && **own != actor || *own == nil && other != nil && *other == actor {
		return fail(ErrNotYourTurn)
	}
	p := Point{x, y}
	changed := flips(s.Board, p, c)
	if len(changed) == 0 {
		return fail(gameapi.ErrInvalidAction)
	}
	actorCopy := actor
	*own = &actorCopy
	s.Board[y*8+x] = c
	for _, i := range changed {
		s.Board[i] = c
	}
	counts(&s)
	s.LastMove = &p
	s.PassedColor = nil
	s.NextColor = colorName(3 - c)
	s.LegalMoves = legal(s.Board, 3-c)
	if len(s.LegalMoves) == 0 {
		s.LegalMoves = legal(s.Board, c)
		if len(s.LegalMoves) > 0 {
			passed := s.NextColor
			s.PassedColor = &passed
			s.NextColor = colorName(c)
		} else {
			s.Status = "finished"
			s.NextColor = ""
			result := "draw"
			if s.BlackCount != s.WhiteCount {
				result = "majority"
				s.WinnerUserID = s.BlackUserID
				if s.WhiteCount > s.BlackCount {
					s.WinnerUserID = s.WhiteUserID
				}
			}
			s.Result = &result
		}
	}
	raw, _ := json.Marshal(s)
	payload, _ := json.Marshal(acceptedMove{x, y, colorName(c), actor})
	rev := snapshot.Revision + 1
	return gameapi.Event{Revision: rev, Type: MoveAccepted, ActorID: actor, Payload: payload}, gameapi.Snapshot{Revision: rev, State: raw}, nil
}
func decodeSnapshot(snapshot gameapi.Snapshot) (State, error) {
	var s State
	bad := func() (State, error) { return State{}, gameapi.ErrInvalidSnapshot }
	allowed := map[string]struct{}{"status": {}, "board": {}, "boardSize": {}, "blackUserId": {}, "whiteUserId": {}, "nextColor": {}, "winnerUserId": {}, "result": {}, "legalMoves": {}, "blackCount": {}, "whiteCount": {}, "passedColor": {}, "lastMove": {}}
	seen, fields, err := decodeObject(snapshot.State, allowed)
	if err != nil || len(seen) != len(allowed) || snapshot.Revision < 0 || snapshot.Revision > 60 {
		return bad()
	}
	var board []int
	if json.Unmarshal(fields["board"], &board) != nil || len(board) != 64 {
		return bad()
	}
	for _, c := range board {
		if c < 0 || c > 2 {
			return bad()
		}
	}
	if json.Unmarshal(snapshot.State, &s) != nil || s.BoardSize != 8 || !validOptionalActor(s.BlackUserID) || !validOptionalActor(s.WhiteUserID) || s.BlackUserID != nil && s.WhiteUserID != nil && *s.BlackUserID == *s.WhiteUserID {
		return bad()
	}

	if snapshot.Revision == 0 {
		if !bytes.Equal(snapshot.State, initial().State) {
			return bad()
		}
	} else {
		if s.BlackUserID == nil || (snapshot.Revision >= 2 && s.WhiteUserID == nil) || s.LastMove == nil {
			return bad()
		}
		p := *s.LastMove
		if p.X < 0 || p.X >= 8 || p.Y < 0 || p.Y >= 8 || s.Board[p.Y*8+p.X] == 0 {
			return bad()
		}
	}
	if s.PassedColor != nil && (s.Status != "active" || *s.PassedColor == s.NextColor || colorValue(*s.PassedColor) == 0 || len(legal(s.Board, colorValue(*s.PassedColor))) != 0) {
		return bad()
	}
	b, w := s.BlackCount, s.WhiteCount
	counts(&s)
	if b != s.BlackCount || w != s.WhiteCount || int64(b+w) != snapshot.Revision+4 {
		return bad()
	}
	if s.Status == "active" {
		c := colorValue(s.NextColor)
		if c == 0 || s.Result != nil || s.WinnerUserID != nil {
			return bad()
		}
		want := legal(s.Board, c)
		a, _ := json.Marshal(want)
		z, _ := json.Marshal(s.LegalMoves)
		if len(want) == 0 || !bytes.Equal(a, z) {
			return bad()
		}
	} else if s.Status == "finished" {
		if s.NextColor != "" || s.Result == nil || len(s.LegalMoves) != 0 || len(legal(s.Board, 1)) != 0 || len(legal(s.Board, 2)) != 0 {
			return bad()
		}
		if b == w {
			if *s.Result != "draw" || s.WinnerUserID != nil {
				return bad()
			}
		} else {
			winner := s.BlackUserID
			if w > b {
				winner = s.WhiteUserID
			}
			if *s.Result != "majority" || winner == nil || s.WinnerUserID == nil || *winner != *s.WinnerUserID {
				return bad()
			}
		}
	} else {
		return bad()
	}
	return s, nil
}

func decodeObject(data []byte, allowed map[string]struct{}) (map[string]bool, map[string]json.RawMessage, error) {
	decoder := json.NewDecoder(bytes.NewReader(data))
	token, err := decoder.Token()
	if err != nil || token != json.Delim('{') {
		return nil, nil, gameapi.ErrInvalidAction
	}
	seen := make(map[string]bool, len(allowed))
	fields := make(map[string]json.RawMessage, len(allowed))
	for decoder.More() {
		token, err := decoder.Token()
		if err != nil {
			return nil, nil, gameapi.ErrInvalidAction
		}
		key, ok := token.(string)
		if !ok || seen[key] {
			return nil, nil, gameapi.ErrInvalidAction
		}
		if _, ok := allowed[key]; !ok {
			return nil, nil, gameapi.ErrInvalidAction
		}
		seen[key] = true
		var raw json.RawMessage
		if err := decoder.Decode(&raw); err != nil {
			return nil, nil, gameapi.ErrInvalidAction
		}
		fields[key] = append(json.RawMessage(nil), raw...)
	}
	if token, err = decoder.Token(); err != nil || token != json.Delim('}') {
		return nil, nil, gameapi.ErrInvalidAction
	}
	if _, err := decoder.Token(); !errors.Is(err, io.EOF) {
		return nil, nil, gameapi.ErrInvalidAction
	}
	return seen, fields, nil
}

func validActorID(actorID string) bool {
	if actorID == "" || len(actorID) > 128 || !utf8.ValidString(actorID) {
		return false
	}
	for _, character := range actorID {
		if unicode.IsControl(character) {
			return false
		}
	}
	return true
}

func validOptionalActor(actorID *string) bool {
	return actorID == nil || validActorID(*actorID)
}

func decodeInteger(raw json.RawMessage) (int, error) {
	if len(raw) == 0 || bytes.Equal(raw, []byte("null")) {
		return 0, gameapi.ErrInvalidAction
	}
	for index, character := range raw {
		if character == '-' && index == 0 {
			continue
		}
		if character < '0' || character > '9' {
			return 0, gameapi.ErrInvalidAction
		}
	}
	if raw[0] == '-' && len(raw) == 1 || len(raw) > 1 && raw[0] == '0' || len(raw) > 2 && raw[0] == '-' && raw[1] == '0' {
		return 0, gameapi.ErrInvalidAction
	}
	var value int
	if err := json.Unmarshal(raw, &value); err != nil {
		return 0, gameapi.ErrInvalidAction
	}
	return value, nil
}
