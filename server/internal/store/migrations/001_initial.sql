CREATE TABLE users (
  id TEXT NOT NULL PRIMARY KEY,
  nickname TEXT NOT NULL,
  normalized_nickname TEXT NOT NULL UNIQUE,
  enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0,1)),
  last_seen_at INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE invite_codes (
  code_hash TEXT NOT NULL PRIMARY KEY,
  created_at INTEGER NOT NULL,
  consumed_by TEXT REFERENCES users(id),
  consumed_at INTEGER,
  CHECK ((consumed_by IS NULL) = (consumed_at IS NULL))
);

CREATE TABLE refresh_tokens (
  token_hash TEXT NOT NULL PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id),
  expires_at INTEGER NOT NULL,
  revoked_at INTEGER,
  created_at INTEGER NOT NULL
);

CREATE TABLE matches (
  id TEXT NOT NULL PRIMARY KEY,
  game_id TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('active','cancelled','finished','abandoned')),
  revision INTEGER NOT NULL DEFAULT 0,
  both_offline_since INTEGER,
  result TEXT,
  winner_user_id TEXT REFERENCES users(id),
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  finished_at INTEGER
);

CREATE TABLE match_players (
  match_id TEXT NOT NULL REFERENCES matches(id),
  user_id TEXT NOT NULL REFERENCES users(id),
  seat INTEGER NOT NULL CHECK (seat IN (0,1)),
  color TEXT NOT NULL CHECK (color IN ('black','white')),
  PRIMARY KEY (match_id, user_id),
  UNIQUE (match_id, seat),
  UNIQUE (match_id, color)
);

CREATE TABLE match_events (
  match_id TEXT NOT NULL REFERENCES matches(id),
  revision INTEGER NOT NULL,
  event_type TEXT NOT NULL,
  action_id TEXT,
  actor_user_id TEXT REFERENCES users(id),
  payload_json TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (match_id, revision),
  UNIQUE (match_id, actor_user_id, action_id)
);

CREATE TABLE active_game_slots (
  game_id TEXT NOT NULL,
  user_id TEXT NOT NULL REFERENCES users(id),
  match_id TEXT NOT NULL REFERENCES matches(id),
  PRIMARY KEY (game_id, user_id),
  UNIQUE (game_id, match_id, user_id)
);

CREATE TABLE launch_tickets (
  token_hash TEXT NOT NULL PRIMARY KEY,
  match_id TEXT NOT NULL REFERENCES matches(id),
  user_id TEXT NOT NULL REFERENCES users(id),
  game_id TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  consumed_at INTEGER,
  created_at INTEGER NOT NULL
);

CREATE TABLE resume_tokens (
  token_hash TEXT NOT NULL PRIMARY KEY,
  match_id TEXT NOT NULL REFERENCES matches(id),
  user_id TEXT NOT NULL REFERENCES users(id),
  expires_at INTEGER NOT NULL,
  last_used_at INTEGER NOT NULL,
  revoked_at INTEGER,
  created_at INTEGER NOT NULL
);

CREATE INDEX idx_match_events_match_id_revision
  ON match_events(match_id, revision);
CREATE INDEX idx_launch_tickets_expires_at
  ON launch_tickets(expires_at);
CREATE INDEX idx_resume_tokens_expires_at
  ON resume_tokens(expires_at);
CREATE INDEX idx_matches_status_both_offline_since
  ON matches(status, both_offline_since);
