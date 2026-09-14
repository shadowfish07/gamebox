package battleship

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/json"
	"errors"
	"math/big"
	"time"

	"github.com/google/uuid"
	"me.zqydev/gamebox/server/internal/clock"
)

type Service struct {
	db    *sql.DB
	clock clock.Clock
}

func New(db *sql.DB, c clock.Clock) *Service { return &Service{db, c} }
func validID(id string) bool {
	u, e := uuid.Parse(id)
	return e == nil && u.String() == id && u != uuid.Nil
}
func (s *Service) Create(ctx context.Context, user, id, opponent string) (View, error) {
	if !validID(id) || !validID(user) || !validID(opponent) || user == opponent {
		return View{}, ErrInvalid
	}
	var enabled int
	if err := s.db.QueryRowContext(ctx, "SELECT enabled FROM users WHERE id=?", opponent).Scan(&enabled); errors.Is(err, sql.ErrNoRows) || err == nil && enabled != 1 {
		return View{}, ErrInvalid
	} else if err != nil {
		return View{}, err
	}
	coin, err := rand.Int(rand.Reader, big.NewInt(2))
	if err != nil {
		return View{}, err
	}
	state := newState(user, opponent, int(coin.Int64()))
	raw, _ := json.Marshal(state)
	_, err = s.db.ExecContext(ctx, `INSERT INTO battleship_matches(id,player_a,player_b,state_json,updated_at) VALUES(?,?,?,?,?) ON CONFLICT(id) DO NOTHING`, id, user, opponent, string(raw), s.clock.Now().UnixMilli())
	if err != nil {
		return View{}, err
	}
	var a, b string
	if err = s.db.QueryRowContext(ctx, "SELECT player_a,player_b FROM battleship_matches WHERE id=?", id).Scan(&a, &b); err != nil {
		return View{}, err
	}
	if a != user || b != opponent {
		return View{}, ErrConflict
	}
	return s.Get(ctx, user, id)
}
func (s *Service) Get(ctx context.Context, user, id string) (View, error) {
	if !validID(id) {
		return View{}, ErrNotFound
	}
	var raw, name string
	var rev int64
	err := s.db.QueryRowContext(ctx, `SELECT m.state_json,m.revision,u.nickname FROM battleship_matches m JOIN users u ON u.id=CASE WHEN m.player_a=? THEN m.player_b ELSE m.player_a END WHERE m.id=? AND (m.player_a=? OR m.player_b=?)`, user, id, user, user).Scan(&raw, &rev, &name)
	if errors.Is(err, sql.ErrNoRows) {
		return View{}, ErrNotFound
	}
	if err != nil {
		return View{}, err
	}
	var state State
	if err = json.Unmarshal([]byte(raw), &state); err != nil {
		return View{}, err
	}
	p := state.player(user)
	if p < 0 {
		return View{}, ErrNotFound
	}
	v := state.view(p)
	v.ID = id
	v.Revision = rev
	v.OpponentName = name
	return v, nil
}

// Act serializes through SQLite, including across processes. The durable action
// ledger makes retries idempotent even after the match or service has advanced.
func (s *Service) Act(ctx context.Context, user, id string, a Action) (View, error) {
	if !validID(id) || !validID(a.ActionID) || a.Revision < 0 {
		return View{}, ErrInvalid
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	// store.Open configures immediate SQLite transactions. database/sql owns
	// rollback on context cancellation, so an interrupted request cannot return a
	// connection with a live transaction to the shared pool.
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return View{}, err
	}
	defer tx.Rollback()

	var raw string
	var rev int64
	err = tx.QueryRowContext(ctx, `SELECT state_json,revision FROM battleship_matches WHERE id=? AND (player_a=? OR player_b=?)`, id, user, user).Scan(&raw, &rev)
	if errors.Is(err, sql.ErrNoRows) {
		return View{}, ErrNotFound
	}
	if err != nil {
		return View{}, err
	}
	request, _ := json.Marshal(a)
	var prior, actor string
	err = tx.QueryRowContext(ctx, "SELECT actor_id,request_json FROM battleship_actions WHERE match_id=? AND action_id=?", id, a.ActionID).Scan(&actor, &prior)
	if err == nil {
		if actor != user || prior != string(request) {
			return View{}, ErrConflict
		}
		if err = tx.Commit(); err != nil {
			return View{}, err
		}
		return s.Get(ctx, user, id)
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return View{}, err
	}
	if rev != a.Revision {
		return View{}, ErrConflict
	}
	var state State
	if err = json.Unmarshal([]byte(raw), &state); err != nil {
		return View{}, err
	}
	if err = state.apply(state.player(user), a); err != nil {
		return View{}, err
	}
	if state.Rematch[0] && state.Rematch[1] && state.NextMatchID == "" {
		nextID, e := uuid.NewRandom()
		if e != nil {
			return View{}, e
		}
		state.NextMatchID = nextID.String()
		next := newState(state.Players[0], state.Players[1], 1-state.First)
		nextRaw, _ := json.Marshal(next)
		_, err = tx.ExecContext(ctx, "INSERT INTO battleship_matches(id,player_a,player_b,state_json,updated_at) VALUES(?,?,?,?,?)", state.NextMatchID, state.Players[0], state.Players[1], string(nextRaw), s.clock.Now().UnixMilli())
		if err != nil {
			return View{}, err
		}
	}
	nextRaw, _ := json.Marshal(state)
	if _, err = tx.ExecContext(ctx, "UPDATE battleship_matches SET state_json=?,revision=revision+1,updated_at=? WHERE id=?", string(nextRaw), s.clock.Now().UnixMilli(), id); err != nil {
		return View{}, err
	}
	if _, err = tx.ExecContext(ctx, "INSERT INTO battleship_actions(match_id,action_id,actor_id,request_json) VALUES(?,?,?,?)", id, a.ActionID, user, string(request)); err != nil {
		return View{}, err
	}
	if err = tx.Commit(); err != nil {
		return View{}, err
	}
	return s.Get(ctx, user, id)
}

type Opponent struct {
	ID       string `json:"id"`
	Nickname string `json:"nickname"`
}
type OpponentPage struct {
	Players    []Opponent `json:"players"`
	NextCursor string     `json:"nextCursor"`
}

func (s *Service) Opponents(ctx context.Context, user, after string) (OpponentPage, error) {
	result := OpponentPage{Players: []Opponent{}}
	if after != "" && !validID(after) {
		return result, ErrInvalid
	}
	rows, err := s.db.QueryContext(ctx, "SELECT id,nickname FROM users WHERE enabled=1 AND id<>? AND id>? ORDER BY id LIMIT 31", user, after)
	if err != nil {
		return result, err
	}
	defer rows.Close()
	for rows.Next() {
		var p Opponent
		if err = rows.Scan(&p.ID, &p.Nickname); err != nil {
			return result, err
		}
		result.Players = append(result.Players, p)
	}
	if len(result.Players) > 30 {
		result.Players = result.Players[:30]
		result.NextCursor = result.Players[29].ID
	}
	return result, rows.Err()
}

type MatchPage struct {
	Matches    []View `json:"matches"`
	NextCursor string `json:"nextCursor"`
}

func (s *Service) List(ctx context.Context, user, after string) (MatchPage, error) {
	result := MatchPage{Matches: []View{}}
	if after != "" && !validID(after) {
		return result, ErrInvalid
	}
	rows, err := s.db.QueryContext(ctx, `SELECT m.id,m.revision,m.state_json,u.nickname FROM battleship_matches m JOIN users u ON u.id=CASE WHEN m.player_a=? THEN m.player_b ELSE m.player_a END WHERE (m.player_a=? OR m.player_b=?) AND m.id>? ORDER BY m.id LIMIT 31`, user, user, user, after)
	if err != nil {
		return result, err
	}
	defer rows.Close()
	for rows.Next() {
		var v View
		var raw, name, id string
		var rev int64
		if err = rows.Scan(&id, &rev, &raw, &name); err != nil {
			return result, err
		}
		var st State
		if err = json.Unmarshal([]byte(raw), &st); err != nil {
			return result, err
		}
		p := st.player(user)
		if p < 0 {
			return result, ErrNotFound
		}
		v = st.view(p)
		v.ID = id
		v.Revision = rev
		v.OpponentName = name
		result.Matches = append(result.Matches, v)
	}
	if len(result.Matches) > 30 {
		result.Matches = result.Matches[:30]
		result.NextCursor = result.Matches[29].ID
	}
	return result, rows.Err()
}
