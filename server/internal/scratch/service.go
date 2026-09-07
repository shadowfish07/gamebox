// Package scratch stores voluntarily published local collection snapshots.
// These snapshots are not authoritative game scores or cloud save backups.
package scratch

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"me.zqydev/gamebox/server/internal/clock"
)

var ErrInvalid = errors.New("invalid collection")

const CatalogSize = 24

type Service struct {
	db    *sql.DB
	clock clock.Clock
}

func New(db *sql.DB, clock clock.Clock) *Service { return &Service{db: db, clock: clock} }

type Player struct {
	UserID    string `json:"userId"`
	Nickname  string `json:"nickname"`
	Counts    []int  `json:"counts"`
	UpdatedAt int64  `json:"updatedAt"`
}
type Page struct {
	Players    []Player `json:"players"`
	NextCursor string   `json:"nextCursor"`
}

func (s *Service) Publish(ctx context.Context, userID string, counts []int) error {
	if len(counts) != CatalogSize {
		return ErrInvalid
	}
	for _, count := range counts {
		if count < 0 || count > 1000000000 {
			return ErrInvalid
		}
	}
	raw, err := json.Marshal(counts)
	if err != nil {
		return err
	}
	_, err = s.db.ExecContext(ctx, `INSERT INTO scratch_collections(user_id,counts_json,updated_at) VALUES (?,?,?) ON CONFLICT(user_id) DO UPDATE SET counts_json=excluded.counts_json, updated_at=excluded.updated_at`, userID, string(raw), s.clock.Now().UnixMilli())
	return err
}
func (s *Service) Remove(ctx context.Context, userID string) error {
	_, err := s.db.ExecContext(ctx, `DELETE FROM scratch_collections WHERE user_id=?`, userID)
	return err
}
func (s *Service) List(ctx context.Context, after string) (Page, error) {
	result := Page{Players: []Player{}}
	rows, err := s.db.QueryContext(ctx, `SELECT c.user_id,u.nickname,c.counts_json,c.updated_at FROM scratch_collections c JOIN users u ON u.id=c.user_id WHERE u.enabled=1 AND c.user_id>? ORDER BY c.user_id LIMIT 31`, after)
	if err != nil {
		return result, err
	}
	defer rows.Close()
	for rows.Next() {
		var p Player
		var raw string
		if err = rows.Scan(&p.UserID, &p.Nickname, &raw, &p.UpdatedAt); err != nil {
			return result, err
		}
		if err = json.Unmarshal([]byte(raw), &p.Counts); err != nil {
			return result, err
		}
		result.Players = append(result.Players, p)
	}
	if err = rows.Err(); err != nil {
		return result, err
	}
	if len(result.Players) > 30 {
		result.Players = result.Players[:30]
		result.NextCursor = result.Players[29].UserID
	}
	return result, nil
}
