package battleship

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"github.com/google/uuid"
	"me.zqydev/gamebox/server/internal/clock"
	"me.zqydev/gamebox/server/internal/store"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

func setup(t *testing.T) (*Service, *sql.DB, string, string, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "sea.db")
	db, e := store.Open(context.Background(), path)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { db.Close() })
	a, b := uuid.NewString(), uuid.NewString()
	for i, id := range []string{a, b} {
		_, e = db.Exec(`INSERT INTO users(id,nickname,normalized_nickname,created_at,updated_at) VALUES(?,?,?,?,?)`, id, id, id, i, i)
		if e != nil {
			t.Fatal(e)
		}
	}
	return New(db, clock.Real{}), db, a, b, path
}
func act(t *testing.T, s *Service, user, id, kind string, ships []Ship, cell int) View {
	t.Helper()
	v, e := s.Get(context.Background(), user, id)
	if e != nil {
		t.Fatal(e)
	}
	v, e = s.Act(context.Background(), user, id, Action{ActionID: uuid.NewString(), Revision: v.Revision, Kind: kind, Ships: ships, Cell: cell})
	if e != nil {
		t.Fatal(e)
	}
	return v
}
func TestDurableIdempotentPrivateMatches(t *testing.T) {
	s, db, a, b, path := setup(t)
	ctx := context.Background()
	id := uuid.NewString()
	v, e := s.Create(ctx, a, id, b)
	if e != nil {
		t.Fatal(e)
	}
	again, e := s.Create(ctx, a, id, b)
	if e != nil || again.ID != v.ID {
		t.Fatal(e)
	}
	outsider := uuid.NewString()
	if _, e = s.Get(ctx, outsider, id); !errors.Is(e, ErrNotFound) {
		t.Fatal("outsider view", e)
	}
	action := Action{ActionID: uuid.NewString(), Revision: 0, Kind: "ready", Ships: fleet()}
	v, e = s.Act(ctx, a, id, action)
	if e != nil {
		t.Fatal(e)
	}
	other, e := s.Get(ctx, b, id)
	if e != nil || len(other.EnemyShips) != 0 || len(other.OwnShips) != 0 {
		t.Fatal("private leak", e)
	}
	v, e = s.Act(ctx, a, id, action)
	if e != nil || v.Revision != 1 {
		t.Fatal("retry", e, v.Revision)
	}
	altered := action
	altered.Kind = "cancel"
	if _, e = s.Act(ctx, a, id, altered); !errors.Is(e, ErrConflict) {
		t.Fatal("collision", e)
	}
	act(t, s, b, id, "ready", fleet(), 0)
	// Reopen the physical database, with no online clients and years of elapsed time.
	if e = db.Close(); e != nil {
		t.Fatal(e)
	}
	db2, e := store.Open(ctx, path)
	if e != nil {
		t.Fatal(e)
	}
	defer db2.Close()
	s2 := New(db2, clock.NewFake(time.Now().AddDate(5, 0, 0)))
	v, e = s2.Get(ctx, a, id)
	if e != nil || v.Phase != "battle" || v.Revision != 2 {
		t.Fatal("recovery", e)
	}
	v, e = s2.Act(ctx, a, id, action)
	if e != nil || v.Revision != 2 {
		t.Fatal("old idempotent retry", e)
	}
	actor := a
	if !v.YourTurn {
		actor = b
	}
	result := act(t, s2, actor, id, "resign", nil, 0)
	if result.Phase != "finished" {
		t.Fatal(result)
	}
	one := act(t, s2, a, id, "rematch", nil, 0)
	if one.NextMatchID != "" {
		t.Fatal("unilateral rematch")
	}
	two := act(t, s2, b, id, "rematch", nil, 0)
	if two.NextMatchID == "" {
		t.Fatal("missing rematch")
	}
	var oldRaw, newRaw string
	db2.QueryRow("SELECT state_json FROM battleship_matches WHERE id=?", id).Scan(&oldRaw)
	db2.QueryRow("SELECT state_json FROM battleship_matches WHERE id=?", two.NextMatchID).Scan(&newRaw)
	// New state must have an empty fleet; first player is swapped.
	nv, e := s2.Get(ctx, a, two.NextMatchID)
	if e != nil || nv.Phase != "placement" || len(nv.OwnShips) != 0 {
		t.Fatal(e, nv)
	}
	var oldState, newState State
	if err := json.Unmarshal([]byte(oldRaw), &oldState); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal([]byte(newRaw), &newState); err != nil {
		t.Fatal(err)
	}
	if newState.First != 1-oldState.First || newState.Turn != newState.First {
		t.Fatal("rematch did not reverse the first player")
	}
}
func TestConcurrentActionsHaveOneWinner(t *testing.T) {
	s, _, a, b, path := setup(t)
	ctx := context.Background()
	id := uuid.NewString()
	if _, e := s.Create(ctx, a, id, b); e != nil {
		t.Fatal(e)
	}
	// A second service with a separate connection pool represents another process.
	db2, e := store.Open(ctx, path)
	if e != nil {
		t.Fatal(e)
	}
	defer db2.Close()
	s2 := New(db2, clock.Real{})
	var wg sync.WaitGroup
	errs := make(chan error, 2)
	for _, service := range []*Service{s, s2} {
		wg.Add(1)
		go func(s *Service) {
			defer wg.Done()
			_, e := s.Act(ctx, a, id, Action{ActionID: uuid.NewString(), Revision: 0, Kind: "ready", Ships: fleet()})
			errs <- e
		}(service)
	}
	wg.Wait()
	close(errs)
	accepted, conflict := 0, 0
	for e := range errs {
		if e == nil {
			accepted++
		} else if errors.Is(e, ErrConflict) {
			conflict++
		} else {
			t.Fatal(e)
		}
	}
	if accepted != 1 || conflict != 1 {
		t.Fatal(accepted, conflict)
	}
}

func TestListPaginationAndPlacementCancellation(t *testing.T) {
	s, _, a, b, _ := setup(t)
	ctx := context.Background()
	for i := 0; i < 31; i++ {
		if _, err := s.Create(ctx, a, uuid.NewString(), b); err != nil {
			t.Fatal(err)
		}
	}
	first, err := s.List(ctx, b, "")
	if err != nil || len(first.Matches) != 30 || first.NextCursor == "" {
		t.Fatal("first page", err)
	}
	second, err := s.List(ctx, b, first.NextCursor)
	if err != nil || len(second.Matches) != 1 || second.NextCursor != "" {
		t.Fatal("last page", err)
	}
	seen := map[string]bool{}
	for _, m := range append(first.Matches, second.Matches...) {
		if seen[m.ID] || m.OpponentID != a {
			t.Fatal("wrong pagination/view")
		}
		seen[m.ID] = true
	}
	empty, err := s.List(ctx, uuid.NewString(), "")
	if err != nil || len(empty.Matches) != 0 {
		t.Fatal("nonparticipant listing", err)
	}
	id := first.Matches[0].ID
	act(t, s, a, id, "save", fleet()[:1], 0)
	cancelled := act(t, s, b, id, "cancel", nil, 0)
	if cancelled.Phase != "cancelled" || cancelled.Winner != "" || len(cancelled.EnemyShips) != 1 {
		t.Fatal("cancelled placement not revealed", cancelled)
	}
}

type waitingClock struct {
	entered chan struct{}
	release chan struct{}
}

func (c waitingClock) Now() time.Time { close(c.entered); <-c.release; return time.Now() }
func TestCancelledWriteRollsBackAndLeavesPoolUsable(t *testing.T) {
	s, db, a, b, _ := setup(t)
	id := uuid.NewString()
	if _, err := s.Create(context.Background(), a, id, b); err != nil {
		t.Fatal(err)
	}
	c := waitingClock{make(chan struct{}), make(chan struct{})}
	blocked := New(db, c)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() {
		_, err := blocked.Act(ctx, a, id, Action{ActionID: uuid.NewString(), Kind: "ready", Ships: fleet()})
		done <- err
	}()
	select {
	case <-c.entered:
	case <-time.After(5 * time.Second):
		t.Fatal("write never reached persistence")
	}
	cancel()
	close(c.release)
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("cancelled write accepted")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("cancelled transaction hung")
	}
	v, err := s.Get(context.Background(), a, id)
	if err != nil || v.Revision != 0 || v.Ready {
		t.Fatal("pool or rollback broken", err, v)
	}
	act(t, s, a, id, "ready", fleet(), 0)
}
