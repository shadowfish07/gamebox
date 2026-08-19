# Gamebox realtime protocol v1

This directory is the shared wire contract for the Go server and Godot game
runtime. The JSON files in `fixtures/` are executable examples consumed by both
runtimes; changing one is a protocol change.

Every message is one JSON object with this versioned envelope:

| Field | Rule |
| --- | --- |
| `protocolVersion` | Required integer. Version 1 is the only supported value. |
| `type` | Required, non-empty message type. |
| `gameId`, `matchId` | Required together for match-bound messages. Omitted only by the initial `platform.connect` and an unbound `platform.error`. |
| `revision` | Required by match-bound server messages. Mutually exclusive with `expectedRevision`. |
| `expectedRevision` | Required by client game actions. Mutually exclusive with `revision`. |
| `actionId` | Required by client game actions. A server action result may echo it. |
| `payload` | Required non-null JSON object owned by the message type or game. |

Client game actions are `gomoku.move.requested` and
`gomoku.resign.requested`. Control messages `platform.connect`,
`platform.pong`, and `platform.snapshot.requested` do not carry either revision
field or an action ID. `platform.pong` and `platform.snapshot.requested` remain
match-bound.

Version 1 accepts only the following directions and types:

- Client to server: `platform.connect`, `platform.pong`,
  `platform.snapshot.requested`, `gomoku.move.requested`, and
  `gomoku.resign.requested`.
- Server to client: `platform.connected`, `platform.ping`,
  `platform.snapshot`, `platform.error`, `gomoku.move.accepted`,
  `gomoku.resigned`, `platform.match.cancelled`, and
  `platform.match.abandoned`.

Apart from the three revisionless client control messages above and an unbound
handshake `platform.error`, match-bound server messages carry `revision`.

The envelope is closed: unknown top-level fields are rejected. The payload is
deliberately opaque at this layer and may contain message-specific fields. Go
stores it as `json.RawMessage`; it does not define a cross-game board model.
JSON `null` and integer values inside payloads therefore survive envelope
round trips without being coerced into a second schema. Explicit JSON `null` is
not accepted for optional envelope fields: omit an unused field instead. Godot
normalizes whole JSON numbers to runtime integers after parsing and leaves
fractional payload values as floats.

The four fixtures freeze a snapshot, a requested Gomoku move, its accepted
server event, and a match-bound error. `snapshot.json` contains a 15 by 15 board
with exactly 225 integer cells.
