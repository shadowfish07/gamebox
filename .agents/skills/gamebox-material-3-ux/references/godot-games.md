# Godot Game Guidance

## Core Contract versus Visible Shell

Every Godot game MUST meet the shared Core Contract whether or not it adopts a visible Gamebox shell. Shared semantics and generated tokens are platform obligations; scene layout is a game choice. Keep scene art, boards, characters, gameplay HUDs, scoring, and audio game-owned. Never replace Godot rendering with Flutter components or make a developer-machine Material skill a runtime dependency.

## Profile Selection

Declare one default orientation and one appropriate UX Profile, or Core Contract only, in onboarding. Profiles are MAY choices, not universal templates. Select `Lightweight Board` for Gomoku because it is a light, turn-based, fixed-board game, while preserving the fact that this Profile is optional for other games. Select `Immersive` for action, role-playing, or existing full-HUD games.

## Lightweight Board Profile

The optional lightweight floating shell uses a return target of at least 48dp. Emphasize connection state only during connect, reconnect, or failure. The game HUD shows turn, player identity, and pending action. Keep the board as the dominant visual region and secondary actions outside it. Resign and cancel use the shared dangerous-confirmation Dialog.

## Immersive Profile

Do not show a persistent Gamebox shell by default. Android Back opens the game's own pause or exit surface. Platform faults MAY appear as temporary overlays but MUST NOT permanently occupy the scene. The game may fully customize visuals while retaining shared state, recovery, back, danger, and evidence semantics.

## Shared Platform Components

The initial shared set contains only:

- return control;
- connection/reconnect status;
- generic Snackbar;
- dangerous-action confirmation;
- loading overlay;
- result and return-to-lobby panel.

Boards, pieces, character status, scoring, and other gameplay components stay inside each game module. Promote a game-specific component only when a second real consumer exists.

## Dense Playfield Target Exception

Board intersections and other necessary playfield targets MAY be smaller than 48dp. This exception never applies to Back, confirmation, menu, or other public controls. The entire playfield remains continuously hittable without dead gaps; input snaps to the nearest legal target and resolves ambiguity; pressed, pending, accepted, and rejected states are clear.

## Theme and Token Mapping

Map generated token roles through Godot `Theme`, `StyleBox`, fonts, and GDScript semantic constants. Consume `sys` roles for public UI, `comp` roles for shared components, and controlled `game` roles for game art such as `playfield_surface` or `piece_pending`. Do not read `ref` directly or scatter public hard-coded styles.

Keep matching `on-*` foreground/container pairs, shared disabled/error meanings, and light/dark readability. A server-authoritative move remains `piece_pending` until accepted; rejection, stale revision, or reconnect snapshot removes or rebuilds it from authority.

## Automation Contracts and Excluded Work

Preserve existing launch markers, state markers, node paths, input actions, and E2E selectors used by automation. Accessibility metadata, `AccessibilityServer` probes, TalkBack operation, screen-reader cell models, focus-order gates, enlarged-font acceptance, accessibility contrast thresholds, and reduced-motion checks are explicit non-goals. Continue to verify safe-area placement, public 48dp targets, normal-size text wrapping, and continuous dense-playfield hit behavior as ordinary UX.

## Scene, Interaction, and Runtime Checks

Scene tests cover relevant default, pressed, disabled, pending, loading, error, empty, success/result, light/dark, normal-size text, content growth, and safe-area states. Flow tests cover pending moves and server accept/reject, disconnect/reconnect and snapshot recovery, resign/cancel confirmation, results, return to lobby, background recovery, and game Activity exit.

In the packaged Android game, verify its declared orientation and affected phone viewports. Explicitly exercise Android system Back and visible Back and confirm they navigate identically without resigning or discarding progress. Exercise resignation through an explicit consequence-named confirmation before any server request. For linked play, retain real two-device verification; deterministic fake services prove wiring only, not the live boundary. The fixed E2E records these interaction and authority assertions without screenshots. The implementing agent also captures and inspects non-sensitive screenshots of affected UI states as transient inputs; do not require the images in commits, pull requests, or final responses unless the user explicitly asks.
