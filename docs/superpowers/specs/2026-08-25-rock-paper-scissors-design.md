# Rock Paper Scissors Design

## Goal and Scope

Add `rps` (石头剪刀布) as Gamebox's second online two-player game. It reuses
the existing authenticated invite, durable server-authoritative match,
WebSocket, reconnect, cancellation, resignation, completion, and slot-release
lifecycles.

The first release supports only online two-player invite matches. It excludes
AI, local multiplayer, matchmaking, chat, spectating, replay, filters, and
new social systems.

## Match Configuration

The match initiator selects the format before sending an invitation:

- `single_round`: the first non-draw round determines the match winner.
- `best_of_three`: the first player to win two non-draw rounds determines the
  match winner.

The server persists the selected format as part of authoritative initial match
state. It is visible to both players before play begins and cannot be changed
after match creation.

## Rules and Authoritative State

`rps` has exactly two players. A round accepts one sealed choice from each
player: `rock`, `paper`, or `scissors`.

1. During a round, each player may submit one choice.
2. The server records a submitted choice as locked but does not expose its
   value to the other player.
3. Once both choices are recorded, the server calculates the round outcome,
   persists one authoritative reveal state/event, then broadcasts it to both
   players.
4. A draw changes no score and starts the next round automatically.
5. A non-draw increments the winner's round score. The server completes the
   match on the first non-draw for `single_round`, or on either player reaching
   two wins for `best_of_three`.

Snapshots sent before a reveal may expose only the requesting player's own
choice and each player's lock status. They must never reveal the opponent's
choice before both submissions are accepted. Reconnect uses the same snapshot
and event-replay authority, therefore preserving this secrecy boundary.

The existing generic lifecycle remains authoritative for disconnects,
reconnects, zero-action cancellation, resignation, terminal outcomes, and
active-match slot release.

## Components and Responsibilities

### Go server

- Register `rps` alongside `gomoku` in the immutable game registry.
- Implement RPS-specific rules, initial state, action validation, score
  calculation, round transitions, and terminal outcome generation.
- Extend the versioned match protocol with RPS initial state, sealed-choice
  action, lock-state snapshots, reveal events, and terminal state.
- Reuse the existing generic match service and HTTP/WebSocket transport; no
  client decides legality, opponent choice, score, or winner.

### Flutter host

- Add Rock Paper Scissors to the game catalog and opponent-selection flow.
- Let only the initiator choose `single_round` or `best_of_three` before an
  invitation is created.
- Display the selected format to the invitee before acceptance.
- Pass the resulting `gameId` and existing non-secret launch configuration to
  Godot exactly as it does for other games.

### Godot runtime

- Register an `rps` scene in the game registry.
- Render a portrait lightweight two-player round UI with match format, score,
  round status, and three equal public choice targets.
- On a local choice, submit the sealed action then disable choices and display
  local locked state. The opponent view says only that the opponent is waiting
  or locked until reveal.
- Render both gestures, the round result, updated score, draws, terminal
  win/loss, shared reconnect/error affordances, and return-to-lobby actions.
- Use Gamebox Material 3 design tokens and shared runtime controls; do not
  inherit Gomoku's board-specific rendering.

## Error Handling and Safety

The server rejects invalid hand values, duplicate choices, actions after a
player is locked, actions outside an active round, and actions after terminal
completion with existing safe protocol error semantics. The client retains the
last confirmed state, does not infer an outcome locally, and presents an
explicit retry or return path when authority cannot be restored.

Logs and retained acceptance artifacts must not contain invite credentials,
launch/resume tickets, access tokens, or opponent choices before authoritative
reveal.

## Verification and Acceptance

- Go unit tests cover both formats, every hand comparison, draws, scoring,
  invalid and duplicate actions, post-terminal actions, and snapshots that do
  not disclose an opponent's sealed choice.
- Godot tests cover action locking, waiting, reveal, score and terminal state,
  reconnect restoration, and safe error presentation.
- Flutter tests cover format selection, initiator-only creation data, and
  invitee-visible format display.
- The two-emulator integration flow covers invitation, a completed round, a
  draw followed by a repeat round, best-of-three completion, and reconnect.
- Visual acceptance runs the built Android application and captures relevant
  RPS states without credentials in the frame. Static rendering, fixtures, and
  headless tests do not substitute for that screenshot evidence.

## Out of Scope

- AI, local pass-and-play, public matchmaking, spectators, chat, replay,
  filters, rankings, rematches, and configurable rule variants beyond the two
  selected formats.
