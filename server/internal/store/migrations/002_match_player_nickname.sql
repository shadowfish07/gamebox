ALTER TABLE match_players RENAME TO match_players_v1;

CREATE TABLE match_players (
  match_id TEXT NOT NULL REFERENCES matches(id),
  user_id TEXT NOT NULL REFERENCES users(id),
  nickname_snapshot TEXT NOT NULL,
  seat INTEGER NOT NULL CHECK (seat IN (0,1)),
  color TEXT NOT NULL CHECK (color IN ('black','white')),
  PRIMARY KEY (match_id, user_id),
  UNIQUE (match_id, seat),
  UNIQUE (match_id, color)
);

INSERT INTO match_players(match_id,user_id,nickname_snapshot,seat,color)
SELECT players.match_id,players.user_id,users.nickname,players.seat,players.color
FROM match_players_v1 AS players
JOIN users ON users.id=players.user_id;

DROP TABLE match_players_v1;
