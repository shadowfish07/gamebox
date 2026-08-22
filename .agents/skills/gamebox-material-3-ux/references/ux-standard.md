# Gamebox UX Standard

## Scope and Fixed Decisions

This standard covers the Gamebox Flutter App, its Android host boundary, and all Godot games. Use stable Material 3 as the base and only cross-runtime typography, shape, and lightweight motion that Flutter and Godot can reproduce reliably. Keep a fixed Gamebox brand rather than Android wallpaper-derived color. Generate and version light and dark schemes from the Gamebox Teal seed `#006B60`.

The supported device scope is Android phones. Each game declares one most-appropriate default orientation; simultaneous portrait and landscape support is not required. Shared interaction semantics, feedback, accessibility, and tokens are mandatory. Scene art, gameplay HUDs, audio, and controlled game extensions remain game-owned. A visible Gamebox shell is optional.

## Requirement Levels

- **MUST** applies to every App page and game. A deviation prevents a completed release verdict.
- **SHOULD** is the default. Record any deviation, its reason, and its alternative measure in the game onboarding document.
- **MAY** is selected according to page, game type, or visual direction.

## Core Contract

Every game MUST:

- consume shared semantic tokens for public color, typography, spacing, shape, state, and motion;
- declare one default orientation and verify it in the target Android runtime;
- handle safe areas, Android back, background recovery, and game Activity exit correctly;
- never make Back implicitly resign, cancel a match, or discard progress;
- use the common loading, pending, reconnect, error, dangerous-confirmation, and result semantics;
- satisfy accessibility and target-runtime visual-evidence requirements.

The Core Contract does not own scene art, boards, characters, gameplay scoring, gameplay animation, or the choice to adopt a visible shell.

## Token Layers and Ownership

`gamebox.tokens.json` is the single hand-edited numeric token source. It MUST be schema-validated and generate committed Dart and GDScript mappings; drift, missing roles, illegal values, or generation failures MUST fail at build time rather than silently fall back.

| Layer | Ownership and consumers |
| --- | --- |
| `ref` | Seeds, tonal values, base fonts, and raw dimensions; business UI MUST NOT read it directly. |
| `sys` | Material semantic roles such as `primary`, `on_surface`, `title_large`, and `corner_medium`; pages and games consume these first. |
| `comp` | Shared component mappings such as primary-button container, dialog shape, and status-chip type. |
| `game` | Controlled roles such as `game_accent`, `playfield_surface`, and `piece_pending`; game visuals consume these without overriding public error, text, focus, disabled, or system-state roles. |

Pair containers with their matching `on-*` foregrounds. Use `error` only for error or danger. Public controls and text MUST support both schemes; fixed game art MUST remain readable and state-distinguishable in both. Use the Material typography roles, a 4dp base grid with an 8dp layout rhythm, 16dp page margins, 24dp content groups, and 48×48dp public control targets. Prefer tonal surface hierarchy; reserve shadows for floating controls over complex content. Respect reduced motion.

## Interaction State Machine

All App operations and game actions follow:

```text
enabled → pressed → pending → success
                         └──→ failure → enabled
```

Pressed state gives immediate visual, light scale, or haptic feedback. Pending MUST prevent duplicate submission and show progress or explicit status, not only disable the control. Ordinary reversible actions MAY update optimistically. Server-authoritative actions MUST remain visibly pending and MUST NOT become final before acknowledgement. Failure restores interaction, retains still-valid input, and offers a next step.

For Gomoku, render a requested move as `piece_pending`; only server acceptance creates the final piece. On rejection, stale revision, or reconnect synchronization, remove it or rebuild it from the authoritative snapshot.

## Feedback, Network, and Recovery

Use component feedback for immediate local state, Snackbar for transient non-blocking recovery, inline/page state for content-affecting conditions, Dialog for decisions or danger, and full-screen blocking only when the product cannot continue. Do not use Dialog for ordinary success or Snackbar for an error the user must resolve.

Show explicit first-connect loading. During reconnect, preserve the last confirmed view, pause authoritative actions, and show recovery status. On success, quietly restore interaction. On failure, offer retry or return to the lobby without presenting local unconfirmed state as confirmed. Never expose internal codes, tokens, URLs, revisions, or connection details. After background resume, synchronize authority before enabling new actions.

## Back and Dangerous Actions

Android system Back and the visible back control MUST lead to the same navigation result. Back MUST never resign, cancel a match, or discard progress implicitly. An active online match remains resumable after returning to the lobby.

Resign, cancel, and exit-with-discard are separately named dangerous actions. Their confirmation MUST state the object and result, such as “Resign and end this match”; a generic “Confirm” is insufficient. Consequences, not button color, determine whether confirmation is required. Audit and verify Android Back behavior and dangerous confirmation even when a requested change is described as visual-only.

## Accessibility

Accessibility is MUST. Normal text contrast is at least 4.5:1; large text, control boundaries, and essential non-text graphics are at least 3:1. Color MUST NOT be the only signal for online, busy, win/loss, error, or pending. Focus order follows visual order, and sound or haptics remain supplemental.

Flutter MUST support system text scaling and TalkBack names, roles, current state, and important updates. Text may reflow or scroll but MUST NOT clip the primary action. Godot interactive `Control` and custom nodes MUST define usable accessibility name, description, flow, role/action, and live-region metadata. Godot Android screen-reader support additionally requires the capability gate in the Godot guidance. Public controls avoid status bars, gesture regions, cutouts, and rounded-corner clipping.

## Game Onboarding Declaration

Each new game MUST declare in its onboarding document or registration description:

- `gameId` and display name;
- one default orientation;
- selected UX Profile, or Core Contract only;
- game extension colors and their semantics;
- supported inputs;
- key UI states and screenshot matrix;
- every SHOULD deviation and its alternative measure.

Keep documentation-only fields out of a runtime DSL until implementation or automated validation needs them.

## Version Governance

Version the design system independently, starting at `1.0.0`, and record its version in token metadata and onboarding documents. Token-name, public interaction-semantic, or shared component-interface changes are breaking changes and need migration guidance. Non-breaking numeric changes increment at least the minor version and regenerate both mappings. Game-only art changes do not increment the design-system major version. Record any MUST deviation with reason, impact, and alternative measure; a code comment alone is insufficient.

## Explicit Non-goals

- Android wallpaper dynamic color.
- Tablet, foldable, ChromeOS, or desktop layouts.
- A mandatory visible shell for all games.
- Shared rendering code between Flutter and Godot.
- Runtime dependence on a developer-machine Material skill.
- A complex runtime DSL for all game declarations.
- Shared abstractions for gameplay components without a second real consumer.
- Expressive APIs that cannot be reproduced reliably in both runtimes.

## Quick Reference

| Item | Decision |
| --- | --- |
| `MUST` | Required everywhere; deviation prevents a completed verdict. |
| `SHOULD` | Default; document the reason and alternative for a deviation. |
| `MAY` | Optional by page, game type, or visual direction. |
| Brand seed | Fixed Gamebox Teal `#006B60`; version light and dark schemes. |
| Device scope | Android phones only in this version. |
| Orientation | Each game declares and verifies one default orientation. |
| Visible shell | Optional; Core Contract remains mandatory without it. |

## Common Mistakes

- Treating a visual-only scope as permission to skip Android Back verification or explicit confirmation before resignation. These interaction semantics remain in scope even when existing callbacks are preserved.
