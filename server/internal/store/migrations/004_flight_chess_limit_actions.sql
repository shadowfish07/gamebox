-- Keep request deduplication separate from the actorless system event.
CREATE TABLE flight_chess_limit_actions (
  match_id TEXT NOT NULL PRIMARY KEY,
  event_revision INTEGER NOT NULL CHECK (event_revision > 0),
  actor_user_id TEXT NOT NULL REFERENCES users(id),
  action_id TEXT NOT NULL,
  request_type TEXT NOT NULL,
  piece_index INTEGER NOT NULL,
  FOREIGN KEY (match_id, event_revision) REFERENCES match_events(match_id, revision) ON DELETE CASCADE,
  CHECK (
    (request_type = 'flight_chess.roll.requested' AND piece_index = -1) OR
    (request_type = 'flight_chess.move.requested' AND piece_index BETWEEN 0 AND 3)
  )
);
