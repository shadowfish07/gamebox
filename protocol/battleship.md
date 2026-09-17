# Battleship asynchronous HTTP contract

`battleship` uses the existing bearer account authentication and API error envelope.
Its durable matches are independent of the real-time WebSocket games, launch
credentials, active slots, presence, and abandonment sweeper. No gameplay deadline
is imposed. All routes require authentication; only participants can read or act
on a match. The authenticated account is the actor; a request cannot supply one.

- `GET /v1/battleship/opponents?after=<uuid>`: enabled opponents, including offline
  accounts; `{players: [{id, nickname}], nextCursor}`. Excludes the current account.
- `GET /v1/battleship/matches?after=<uuid>`: participant views of active and ended
  matches; `{matches: [view], nextCursor}`. Both lists use ascending UUID keyset
  pagination, at most 30 entries, and an empty next cursor at the end.
- `POST /v1/battleship/matches`: `{id, opponentId}`. Client-generated UUID `id`
  identifies the creation request, so retries return the same match. Server selects
  the first player uniformly. An ID collision with different participants fails.
- `GET /v1/battleship/matches/{id}`: latest participant view.
- `POST /v1/battleship/matches/{id}/actions`: `{actionId, revision, kind, ships, cell}`.
  All five fields are present. Use `ships: []` and `cell: 0` when unused.
  `actionId` is a new canonical UUID per intent; retries preserve the exact body.

Actions: `save` (partial legal fleet), `ready` (complete legal fleet), `fire`,
`cancel` (placement only), `resign` (battle only), `offer_end` (offer or consent),
`decline_end` (decline or withdraw), and `rematch` (ended match only). Both rematch
consents atomically create one fresh match, reversing the previous first player.

A ship is `{id: 0..4, cell: 0..99, vertical: bool}`; IDs have lengths 5/4/3/3/2.
Cell `row * 10 + column` corresponds to rows A–J and columns 1–10. A shot is
`{cell, hit}`. Fleets may touch but cannot overlap, bend, wrap rows or exceed bounds.

A view contains `id`, `revision`, `opponentId`, `opponentName`, `phase`
(`placement|battle|finished|cancelled`), `yourTurn`, `ready`, `enemyReady`,
`ownShips`, `enemyShips`, `shots`, `incoming`, `winner`, `endOffer`,
`rematchRequested`, `enemyRematchRequested`, and `nextMatchId`. Optional IDs are
empty strings; lists are never null. `shots` are the caller's outgoing attacks.
`enemyShips` contains only sunk enemy ships until the match ends, when all enemy
placements are revealed. It never exposes partial enemy placements, unsunk ship
identity or unhit coordinates during play. The list route applies the same filter.

Each accepted action atomically changes the state, increments the revision and
records actor plus canonical request JSON in `battleship_actions`. An exact retry
returns the latest view without another action, including after a restart or later
moves. Reusing an action ID with different semantics or an outdated revision returns
HTTP 409 `stale_revision`. Invalid actions return 400 `invalid_request`;
nonparticipants and unknown matches return 404 `match_not_found`.

The Flutter client persists an uncertain action before sending, scoped by account
and match. It shows pending state until acknowledgement; retries reuse the durable
identity. It stops foreground polling in the background and refreshes on return.
Network-request timeouts never skip a turn or settle a game. Completed matches
remain available for full-board review and mutually accepted rematches.
