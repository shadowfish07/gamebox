# Gomoku UX Profile

```yaml
gameId: gomoku
displayName: 五子棋
defaultOrientation: portrait
uxProfile: lightweight-board
inputMethods: [touch, android-back]
gameThemeRoles: [board, grid, blackPiece, whitePiece, whitePieceOutline, lastMove, pendingMove]
```

This onboarding declaration targets Gamebox design-system version `2.0.0`. Gomoku selects the optional **Lightweight Board** profile because it is a light, turn-based, fixed-board game. The visible return/title/status shell is a Gomoku choice, not the default for another current or future game. Another game must independently select its profile or Core Contract only.

## Shell and Dense Playfield

The selected shell contains a safe-area-aware return control, game title, turn/player/pending status, connection/recovery status only when relevant, a dominant board, resign outside the board, shared dangerous confirmation, and a result/return-to-lobby surface. Gameplay rendering remains Godot-owned; Flutter does not render the board.

The 15×15 board uses the Dense Playfield Target Exception. Its individual intersections may be smaller than 48dp, but the entire board region is continuously hittable with no dead gaps between intersections. Touch resolves to the nearest intersection; ties use one deterministic coordinate rule. Occupied or otherwise illegal intersections do not submit. Pressed, `pendingMove`, accepted/`lastMove`, and rejected/restored states are visibly distinct. Back, resign, dialog, and result actions remain public ≥48×48dp targets and do not receive the exception.

The board rounds a point to an intersection, bounds the outer half-cell region, safely submits a same-cell single-finger release, and tests coordinate inverse, expanded viewports, drag/multitouch cancellation, and pending separation. The Material 3 retrofit preserves those behaviors while adding token-backed board rendering plus distinct pressed, pending, accepted, and restored interaction states.

## Inputs and Navigation

- **Touch:** selects the nearest legal board intersection and operates Back, resign, confirmation, retry, and result actions. A move stays `pendingMove` until acknowledged; the confirmed board is not mutated locally (`game_runtime/games/gomoku/gomoku_controller.gd:127–133,217–246`; `game_runtime/test/test_gomoku_scene.gd:267–283`).
- **Android Back:** Android system Back and visible Back must reach the same non-destructive return result. Back never resigns, cancels, or discards the active online match. Current source routes `ui_cancel` to the visible handler (`game_runtime/games/gomoku/gomoku_controller.gd:145–159`) and its test proves no resign request (`game_runtime/test/test_gomoku_scene.gd:242–264`); packaged Android parity remains required.
- **Resign:** available only when the authoritative state permits it, then opens the shared consequence-named confirmation. Only its confirm action calls the request path; cancellation and Android Back close the dialog without resigning.

## Key UI States and Visual Review States

The game must present and test these states in portrait on both narrow 360×800 and large 412×915 Android phone viewports, in light and dark where applicable:

1. Connect and initial snapshot loading.
2. Local turn as black, local turn as white, and opponent turn.
3. Board pressed, move pending, move accepted with last-move marker, and move rejected with restored interaction.
4. Reconnecting with the last confirmed board preserved, authoritative resynchronization, and connection failure with an explicit return/retry next step.
5. Resign confirmation open, confirmation cancelled, and confirmed resign pending.
6. Win, loss, draw, cancelled, and abandoned result/return states.
7. Visible Back return, Android system Back return, background/resume synchronization, and Game Activity exit.
8. Safe areas and normal-size long-copy wrapping without clipping public actions.

The fixed Android E2E asserts the state and protocol transitions for these
states without taking screenshots. If visual acceptance is required, the full
capture combinations and sensitive-data rules are authoritative in
`docs/design/gamebox-material-3-ux-audit.md#android-screenshot-matrix`; a
headless scene, fixture, golden, or static render is not runtime visual evidence.

## Final Visual Evidence

The fixed E2E intentionally produces no screenshot list. Any separate visual
review must record its final clean HEAD and artifact details here before the
profile can claim visual closure.

Visual closure was performed on the final UI source commit `cad84f9` with the
separate, logic-free capture matrix below. Later acceptance-only changes do not
alter the rendered application UI. The final two-device logic run records its
exact clean branch HEAD in `artifacts/e2e/<run>/summary.json` as
`sourceRevision`.

| Mode | Android viewport | Runtime capture |
| --- | --- | --- |
| Light / large | 1080×2400 | `artifacts/visual/issue-7-material3/gomoku-online-light-large.png` |
| Dark / narrow | 720×1600 | `artifacts/visual/issue-7-material3/gomoku-online-dark-narrow.png` |

Both captures show the active online-presence HUD, board dominance, safe
portrait margins, and no clipping or overlap. The fixed E2E separately covers
online → offline → unknown → restored-online presence transitions without
embedding screenshots.

## Token Roles

Public shell components consume generated `sys`/`comp` roles for surfaces, text, disabled, error, dialogs, status, shape, spacing, typography, and motion. Game art consumes only these controlled `game` roles; it may not override public error, text, disabled, or system-state semantics:

| Role | Meaning |
| --- | --- |
| `board` | Dominant playfield surface. |
| `grid` | Grid lines and star points that remain visibly distinct in both schemes. |
| `blackPiece` | Confirmed black stone. |
| `whitePiece` | Confirmed white stone fill. |
| `whitePieceOutline` | Boundary that keeps the white stone distinguishable on both schemes. |
| `lastMove` | Marker for the most recently accepted authoritative move. |
| `pendingMove` | Non-final requested move marker; never interchangeable with a confirmed piece. |

The current literals in `game_runtime/games/gomoku/gomoku_board.gd:15–21` map one-to-one to these semantic roles only as migration evidence; the generated GDScript mapping becomes authoritative. The game must pair public containers with their on-colors and remain readable/state-distinguishable in both versioned Gamebox Teal schemes.

## SHOULD Deviations

| Deviation | Current reason | Alternative measure and retrofit decision |
| --- | --- | --- |
| Connection detail remains visible after recovery as “已连接” (`game_runtime/games/gomoku/gomoku_controller.gd:231–233,281–290`). | The existing fixed HUD dedicates one line to connection state at all times. | Record the deviation for the pre-change baseline only. During retrofit, preserve explicit connect/sync/reconnect/failure copy but collapse the steady connected detail; turn, player identity, and pending status remain visible. |

There are no remaining approved SHOULD deviations. Board dominance, secondary actions outside the playfield, and the optional visible shell are selected profile behavior rather than deviations. Accessibility conformance and assistive-technology work are explicitly outside this profile's completion scope; existing automation selectors remain compatibility contracts only.

## Current Evidence to Preserve

- Portrait is requested in `game_runtime/project.godot:15–21` and asserted in `game_runtime/test/test_main.gd:144–155`; the declared orientation still needs packaged Android verification.
- Reconnect and snapshot recovery keep moves/resign locked until authority is restored (`game_runtime/games/gomoku/gomoku_controller.gd:162–187,237–246`; `game_runtime/test/test_gomoku_scene.gd:80–228`).
- Pending, last-move, terminal, and safe public error states already have distinct source paths (`game_runtime/games/gomoku/gomoku_controller.gd:204–290`; `game_runtime/games/gomoku/gomoku_board.gd:185–203`).
- Existing safe Back, logging markers, launch boundaries, server messages, match rules, reducer behavior, and network protocol remain outside visual/profile redesign.
