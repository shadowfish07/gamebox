-- Async matches intentionally have no presence, active-slot or expiry linkage.
CREATE TABLE battleship_matches (
 id TEXT PRIMARY KEY NOT NULL,
 player_a TEXT NOT NULL REFERENCES users(id),
 player_b TEXT NOT NULL REFERENCES users(id),
 revision INTEGER NOT NULL DEFAULT 0 CHECK(revision >= 0),
 state_json TEXT NOT NULL CHECK(json_valid(state_json)),
 updated_at INTEGER NOT NULL,
 CHECK(player_a <> player_b)
);
CREATE INDEX battleship_player_a ON battleship_matches(player_a,id);
CREATE INDEX battleship_player_b ON battleship_matches(player_b,id);
CREATE TABLE battleship_actions (
 match_id TEXT NOT NULL REFERENCES battleship_matches(id),
 action_id TEXT NOT NULL,
 actor_id TEXT NOT NULL REFERENCES users(id),
 request_json TEXT NOT NULL,
 PRIMARY KEY(match_id,action_id)
);
