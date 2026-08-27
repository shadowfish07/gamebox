---
name: gamebox-material-3-ux
description: Use when changing, reviewing, auditing, or accepting user-facing Flutter or Godot UI in the Gamebox repository, including Material 3 themes, navigation, game HUDs, interaction states, deterministic two-device E2E logic, and Android UX acceptance.
---

# Gamebox Material 3 UX

## Core Principle

Unify Gamebox interaction semantics and tokens while preserving each game's visual identity. `useMaterial3` alone is not conformance, and a visible Gamebox shell is optional.

## Load the Relevant Rules

- Always read [references/ux-standard.md](references/ux-standard.md).
- For Flutter App work, read [references/flutter-app.md](references/flutter-app.md).
- For Godot or game work, read [references/godot-games.md](references/godot-games.md).
- Before an audit verdict or completion claim, read [references/acceptance.md](references/acceptance.md).
- For cross-runtime tokens or changes affecting both hosts, read both platform references.

## Workflow

1. Inspect the real source, tests, target runtime, and affected state transitions.
2. Classify each requirement as MUST, SHOULD, or MAY and choose the one appropriate UX Profile.
3. Audit before editing; keep gameplay visuals and server-authoritative behavior outside the shared shell.
4. Implement behavior changes test-first and consume semantic tokens instead of public hard-coded styles.
5. For Godot UX work, iterate first in a directly launched Godot scene or deterministic preview at representative phone viewports. Capture and inspect each affected state there before paying the Android build/emulator cost.
6. Add or update focused Godot state, controller, and scene-contract tests for the changed behavior and layout invariants; do not use screenshot goldens as deterministic tests.
7. Keep Android host smoke thin: prove the packaged Godot game starts, reaches its ready marker, renders in the declared orientation, and exits correctly. Do not rerun Godot-internal state matrices through UI Automator merely because the UI changed.
8. Run deeper Android/two-device flows only when the change affects the Flutter-Godot bridge, lifecycle, protocol, networking, or another cross-runtime boundary.
9. Separate deterministic evidence from UX inspection: use Godot preview screenshots for fast iteration, then inspect the affected states once in the actual Android runtime for final target-runtime acceptance.

## Completion Red Lines

- Do not force a common visible shell onto every game.
- Do not treat mock, fixture, source inspection, static rendering, or golden output as target-runtime evidence.
- Do not add screenshots, pixel crops, SSIM, or image artifacts to a fixed deterministic E2E gate. Its pass proves runtime logic/state only, not UX quality.
- Do not claim a UI change complete until the implementing agent has captured and inspected the affected Android states. Screenshots are transient inspection inputs, not deliverables; their absence from a commit, pull request, or final response is never a finding by itself.
- Do not require Android UI automation to duplicate state transitions already covered by focused Godot tests. Android smoke and target-runtime inspection cover packaging and platform integration; Godot tests cover game-owned behavior.
- Do not add or gate delivery on accessibility work; TalkBack, screen-reader metadata, accessibility services, focus order, enlarged-font checks, and accessibility conformance are explicit non-goals.
- Preserve existing `Semantics.identifier`, `Key`, UI Automator, and host-smoke selectors as automation compatibility contracts, not accessibility requirements.
- Do not expand a UI task into gameplay, protocol, server-authority, or unrelated platform changes.
