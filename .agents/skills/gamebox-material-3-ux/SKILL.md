---
name: gamebox-material-3-ux
description: Use when changing, reviewing, auditing, or accepting user-facing Flutter or Godot UI in the Gamebox repository, including Material 3 themes, navigation, game HUDs, interaction states, and Android screenshot evidence.
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
5. Run focused tests, the repository gate, and the actual Android App or Godot game.
6. Capture the affected runtime states without credentials or user-specific data, then issue the acceptance verdict.

## Completion Red Lines

- Do not force a common visible shell onto every game.
- Do not treat mock, fixture, source inspection, static rendering, or golden output as target-runtime evidence.
- Do not claim a UI change complete without relevant Android screenshots; report the exact blocker instead.
- Do not add or gate delivery on accessibility work; TalkBack, screen-reader metadata, accessibility services, focus order, enlarged-font checks, and accessibility conformance are explicit non-goals.
- Preserve existing `Semantics.identifier`, `Key`, UI Automator, and host-smoke selectors as automation compatibility contracts, not accessibility requirements.
- Do not expand a UI task into gameplay, protocol, server-authority, or unrelated platform changes.
