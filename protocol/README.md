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

Client game actions are the game-specific `*.requested` messages listed below.
Control messages `platform.connect`,
`platform.pong`, and `platform.snapshot.requested` do not carry either revision
field or an action ID. `platform.pong` and `platform.snapshot.requested` remain
match-bound.

New clients advertise `"capabilities":["player_presence_v1"]` beside the one
launch or resume credential in `platform.connect`. The server accepts legacy
connect payloads without `capabilities` and then preserves the original v1
message shapes, so already released clients do not receive message types or
fields they cannot decode.

Version 1 accepts only the following directions and types:

- Client to server: `platform.connect`, `platform.pong`,
  `platform.snapshot.requested`, `chinese_checkers.move.requested`,
  `chinese_checkers.resign.requested`, `flight_chess.roll.requested`,
  `flight_chess.move.requested`, `flight_chess.resign.requested`,
  `gomoku.move.requested`, `gomoku.resign.requested`,
  `rps.choice.requested`, and `rps.resign.requested`.
- Server to client: `platform.connected`, `platform.ping`,
  `platform.presence.changed`, `platform.snapshot`, `platform.error`,
  the matching game-specific accepted/resigned messages,
  `rps.round.revealed`, `platform.match.cancelled`, and
  `platform.match.abandoned`.

Flight Chess uses an empty payload for `flight_chess.roll.requested`; the
server generates and persists the die result. `flight_chess.move.requested`
contains one integer `pieceIndex` in `[0,3]`, and resign also uses an empty
payload. An accepted roll includes `color`, `userId`, `value`, and
`movablePieceIndices`. An accepted move includes
the acting color and user, selected piece and roll, `from`/`to` positions,
movement `effect`, and `capturedPieceIndices`. The client applies only accepted
events in contiguous revision order; a gap requests a fresh authoritative
snapshot.

Apart from the three revisionless client control messages above and an unbound
handshake `platform.error`, match-bound server messages carry `revision`.

For clients that advertised `player_presence_v1`, `platform.connected` is the
reusable initial presence snapshot. Its `players`
array contains unique `{ "userId", "online" }` entries for every player in the
match. Later zero-to-one and one-to-zero connection boundaries are delivered as
`platform.presence.changed` with `{ "userId", "online" }`. Presence messages
carry the connection's latest game `revision` as an ordering anchor but do not
consume or advance game revision; game-specific state reducers must not apply
them. A player is online while at least one live match connection remains, and
heartbeat expiry produces the same offline boundary as an explicit close.

The envelope is closed: its field names use the exact camelCase spelling shown
above, each top-level field may occur only once, and unknown top-level fields
are rejected. Standard JSON syntax is required, including no trailing commas.
Escapes, delimiters, or field-like text inside string values are treated only
as string content. The payload remains deliberately opaque at this layer and
may contain message-specific fields. Go stores it as `json.RawMessage`; it does
not define a cross-game board model. Extra payload fields are therefore allowed
even though extra envelope fields are not.

Godot 4.7 cannot construct a `String` containing U+0000 without replacing it.
To keep valid escaped NUL data lossless and diagnostic-free, its decoder exposes
any such payload string as a `PackedByteArray` containing the exact UTF-8 bytes;
typed message fields that require `String` reject that variant. All other JSON
strings remain ordinary Godot `String` values.

Explicit JSON `null` is not accepted for optional envelope fields: omit an
unused field instead. `null` remains valid inside payloads. Every JSON number
must be finite. Any mathematically integral JSON number, including one written
with a decimal point or exponent, must be within
`[-9007199254740991, 9007199254740991]` (`±(2^53-1)`). Larger integer values
must travel as decimal strings. Go checks every raw number token with
`json.Number` while retaining the payload as `json.RawMessage`; Godot checks
the original number spelling before parsing, then normalizes safe whole values
to runtime integers and leaves fractional values as floats.

Version 1 also rejects a mathematically fractional token when conversion to
binary64 would silently produce an integer. This covers underflow to zero,
over-precise fractions such as `1.00000000000000001`, and half steps near the
safe-integer boundary. Exponent signs and leading zeroes do not affect the
mathematical value: `1e0000000` is 1 and `1e+0000001` is 10. Godot encodes
successful actions with `JSON.stringify(..., full_precision=true)` before
running the result through the strict decoder.

Parsing is bounded before payload materialization or arbitrary-precision
number work:

| Limit | Version 1 value |
| --- | --- |
| Maximum UTF-8 message size | 65,536 bytes (64 KiB) |
| Maximum JSON container depth | 32, including the envelope object |
| Maximum individual number token | 128 ASCII bytes |

The current 15 by 15 snapshot fixture is about 1.1 KiB, so the message limit
leaves substantial room for the complete board and future payload fields.
Messages over any limit fail before normal envelope decoding. Number scanning
remains linear in the bounded token size; Godot removes exponent and mantissa
leading zeroes with one forward pass.

Protocol failures expose only a fixed, bounded `code` and `message`. Neither
runtime includes an unknown field name, message type, number spelling, or
payload content in the public error. Resource failures use
`message_too_large`, `json_too_deep`, or `number_token_too_long`; unsafe numeric
values use `unsafe_number`.

`Protocol.encode_action(...)` in Godot returns `{"ok":true,"text":"..."}` on
success. Invalid types, identifiers, revisions, cyclic containers, non-finite
numbers, unsafe integers, non-string object keys, and non-JSON variants return
`{"ok":false,"code":"...","message":"..."}` and never produce wire text.
Before serialization, encoding walks the complete envelope with a remaining
byte and depth budget. Strings use a constant-time character-count lower bound
before bounded UTF-8 and JSON-escape counting; arrays and objects use their
element count to reject an impossible budget before visiting their contents.
This prevents a wide container or huge string from forcing an unbounded walk or
temporary JSON allocation. Serialization still performs the authoritative
UTF-8 byte-size check, and every successful encoding is passed through the same
strict decoder before it is returned. A complete message of exactly 65,536
bytes is accepted; 65,537 bytes is rejected.

The four compatibility fixtures freeze a snapshot, a requested Gomoku move, its
accepted server event, and a match-bound error. `snapshot.json` contains a 15
by 15 board with exactly 225 integer cells. The compatibility fixture under
`fixtures/compat/` is consumed by both runtimes to keep JSON string escape,
UTF-16 surrogate, and escaped NUL byte semantics aligned with Go v1.
