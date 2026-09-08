// Package scratch stores automatically synchronized local collection snapshots.
// These snapshots are not authoritative game scores or cloud save backups.
package scratch

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"me.zqydev/gamebox/server/internal/clock"
)

var ErrInvalid = errors.New("invalid collection")

const LegacyCatalogSize = 24
const CatalogSize = 48

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
	if len(counts) != CatalogSize && len(counts) != LegacyCatalogSize {
		return ErrInvalid
	}
	for _, count := range counts {
		if count < 0 || count > 1000000000 {
			return ErrInvalid
		}
	}
	legacy := len(counts) == LegacyCatalogSize
	normalized := make([]int, CatalogSize)
	copy(normalized, counts)
	update := "excluded.counts_json"
	if legacy {
		// A cat-only client must not erase dogs published by a newer client.
		update = "json_set(excluded.counts_json"
		for i := LegacyCatalogSize; i < CatalogSize; i++ {
			update += fmt.Sprintf(", '$[%d]', COALESCE(json_extract(scratch_collections.counts_json, '$[%d]'), 0)", i, i)
		}
		update += ")"
	}
	raw, err := json.Marshal(normalized)
	if err != nil {
		return err
	}
	_, err = s.db.ExecContext(ctx, `INSERT INTO scratch_collections(user_id,counts_json,updated_at) VALUES (?,?,?) ON CONFLICT(user_id) DO UPDATE SET counts_json=`+update+`, updated_at=excluded.updated_at`, userID, string(raw), s.clock.Now().UnixMilli())
	return err
}
func (s *Service) List(ctx context.Context, after string, card *int) (Page, error) {
	result := Page{Players: []Player{}}
	query := `SELECT u.id,u.nickname,COALESCE(c.counts_json,'null'),COALESCE(c.updated_at,0) FROM users u LEFT JOIN scratch_collections c ON u.id=c.user_id WHERE u.enabled=1 AND u.id>? `
	args := []any{after}
	if card != nil {
		if *card < 0 || *card >= CatalogSize {
			return result, ErrInvalid
		}
		query += " AND json_extract(c.counts_json, ?) > 0"
		args = append(args, fmt.Sprintf("$[%d]", *card))
	}
	query += " ORDER BY u.id LIMIT 31"
	rows, err := s.db.QueryContext(ctx, query, args...)
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
		normalized := make([]int, CatalogSize)
		copy(normalized, p.Counts)
		p.Counts = normalized
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
