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

### Fast UX iteration in Godot

Launch the real Godot project directly for visual tuning instead of rebuilding and driving Android after every spacing, typography, or scene-layout edit. Prefer a deterministic preview entry point that instantiates the production scene and controller with safe fixture state; it may bypass registration and networking, but it must not replace production UI nodes with a mock rendering.

- Run representative phone viewports, especially the narrow supported viewport, and inspect screenshots of every affected state.
- Keep preview states deterministic and selectable, such as ready, pending, locked, reveal, reconnecting, and finished.
- Treat these screenshots as target-runtime evidence for Godot-owned presentation and rapid design feedback, not as Android package/host evidence or checked-in golden tests.
- Preserve production node paths, theme application, layout containers, and controller bindings so preview findings transfer to the packaged game.

### Godot-owned automated tests

Move game-owned confidence into fast Godot tests rather than reproducing it with Android UI automation:

- reducer/state tests for authoritative snapshots, pending/accepted/rejected actions, reveal deduplication, reconnect recovery, and terminal outcomes;
- controller tests for state-to-presentation bindings, visibility exclusivity, input locking, animation completion, and stable automation markers;
- scene-contract tests for production node paths, semantic theme roles, public-control target sizes, container-driven layout, equal choice targets, content growth, and required state surfaces;
- focused launch tests that instantiate the production scene at representative viewport sizes and fail on parser/runtime errors.

Add or update these tests whenever a Godot UX change introduces an invariant that can be asserted semantically. Do not assert pixel coordinates, screenshots, image similarity, or incidental child ordering unless the order is itself an interaction contract.

### Android boundary

When a Godot change affects export/package, Android hosting, orientation integration, visible/system Back, Activity lifecycle, or the Flutter–Godot bridge, Android automation is a thin host smoke: install and launch the actual package, confirm the Godot ready marker appears, confirm the affected host surface is usable, exercise Back and Activity exit when affected, and ensure there is no startup crash. Ordinary Godot-owned styling, layout, copy, and state presentation use focused Godot tests plus direct production-scene runtime inspection; do not replay the complete Godot state matrix through UI Automator.

Run linked two-device or deeper Android flows only when the change touches the Flutter-Godot bridge, launch tickets, lifecycle recovery, networking/protocol behavior, or another cross-runtime boundary. Those flows prove the boundary; they still do not replace focused Godot tests.

When the packaged Android boundary is in scope, verify its declared orientation and affected phone viewports. Explicitly exercise Android system Back and visible Back and confirm they navigate identically without resigning or discarding progress. Exercise resignation through an explicit consequence-named confirmation before any server request. For linked play changes, retain real two-device verification; deterministic fake services prove wiring only, not the live boundary. Fixed automation records these interaction and authority assertions without screenshots. The implementing agent captures and inspects non-sensitive screenshots in the relevant target runtime as transient inputs; do not require the images in commits, pull requests, or final responses unless the user explicitly asks.
