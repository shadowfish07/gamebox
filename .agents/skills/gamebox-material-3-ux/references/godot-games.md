# Godot Game Guidance

## Core Contract versus Visible Shell

Every Godot game MUST meet the shared Core Contract whether or not it adopts a visible Gamebox shell. Shared semantics and generated tokens are platform obligations; scene layout is a game choice. Keep scene art, boards, characters, gameplay HUDs, scoring, and audio game-owned. Never replace Godot rendering with Flutter components or make a developer-machine Material skill a runtime dependency.

## Profile Selection

Declare one default orientation and one appropriate UX Profile, or Core Contract only, in onboarding. Profiles are MAY choices, not universal templates. Select `Lightweight Board` for Gomoku because it is a light, turn-based, fixed-board game, while preserving the fact that this Profile is optional for other games. Select `Immersive` for action, role-playing, or existing full-HUD games.

## Lightweight Board Profile

The optional lightweight floating shell uses a return target of at least 48dp. Emphasize connection state only during connect, reconnect, or failure. The game HUD shows turn, player identity, and pending action. Keep the board as the dominant visual region and secondary actions outside it. Resign and cancel use the shared dangerous-confirmation Dialog.

## Immersive Profile

Do not show a persistent Gamebox shell by default. Android Back opens the game's own pause or exit surface. Platform faults MAY appear as temporary overlays but MUST NOT permanently occupy the scene. The game may fully customize visuals while retaining shared state, recovery, back, danger, accessibility, and evidence semantics.

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

Board intersections and other necessary playfield targets MAY be smaller than 48dp. This exception never applies to Back, confirmation, menu, or other public controls. The entire playfield remains continuously hittable without dead gaps; input snaps to the nearest legal target and resolves ambiguity; pressed, pending, accepted, and rejected states are clear; assistive technology receives understandable coordinates, state, or an equivalent interaction.

## Theme and Token Mapping

Map generated token roles through Godot `Theme`, `StyleBox`, fonts, and GDScript semantic constants. Consume `sys` roles for public UI, `comp` roles for shared components, and controlled `game` roles for game art such as `playfield_surface` or `piece_pending`. Do not read `ref` directly or scatter public hard-coded styles.

Keep matching `on-*` foreground/container pairs, shared focus/disabled/error meanings, light/dark readability, and reduced-motion behavior. A server-authoritative move remains `piece_pending` until accepted; rejection, stale revision, or reconnect snapshot removes or rebuilds it from authority.

## Android Accessibility Capability Gate

Give interactive `Control` and custom nodes usable accessibility name, description, flow, role/action, and live-region metadata. Metadata or desktop behavior alone cannot prove Android screen-reader support. On the packaged, project-locked Godot Android export, verify `AccessibilityServer.is_supported()` and complete real TalkBack interaction. If the bridge is unsupported, track it as an explicit incomplete platform capability; do not silently waive it or claim full support.

Also verify focus order, non-color status cues, safe-area placement, relevant contrast, restrained announcements for reconnect/error/turn changes, and an equivalent interaction for dense playfields.

## Scene, Interaction, and Runtime Checks

Scene tests cover relevant default, pressed, focus, disabled, pending, loading, error, empty, success/result, light/dark, enlarged text, content growth, and safe-area states. Flow tests cover pending moves and server accept/reject, disconnect/reconnect and snapshot recovery, resign/cancel confirmation, results, return to lobby, background recovery, and game Activity exit.

In the packaged Android game, verify its declared orientation and affected phone viewports. Explicitly exercise Android system Back and visible Back and confirm they navigate identically without resigning or discarding progress. Exercise resignation through an explicit consequence-named confirmation before any server request. For linked play, retain real two-device verification; deterministic fake services prove wiring only, not the live boundary. Capture non-sensitive screenshots of every affected state.
