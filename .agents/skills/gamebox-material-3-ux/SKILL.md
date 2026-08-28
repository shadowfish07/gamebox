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
5. Add focused tests for changed behavior, state bindings, and layout invariants; never use screenshot goldens as deterministic tests.
6. For Godot, iterate with the production scene or deterministic preview at representative phone viewports and inspect every affected state.
7. Before runtime acceptance, perform the requirements-grounded implementation review in [references/acceptance.md](references/acceptance.md); fix blocking findings and re-review.
8. Keep Android host smoke thin: prove launch, ready marker, orientation, usable host surface, and exit. Do not duplicate Godot state matrices in UI Automator.
9. Use deeper Android/two-device flows only for affected bridge, lifecycle, protocol, networking, or cross-runtime boundaries.
10. Follow the repository's `docs/testing-strategy.md`: keep deterministic evidence separate from UX inspection and finish by inspecting affected states in the relevant actual target runtime.

## Completion Red Lines

- Do not force a common visible shell onto every game.
- Do not enter final runtime acceptance or claim completion while the requirements-grounded implementation review is missing or has unresolved blocking findings.
- Do not treat mock, fixture, source inspection, static rendering, or golden output as target-runtime evidence.
- Do not add screenshots, pixel crops, SSIM, or image artifacts to a fixed deterministic E2E gate. Its pass proves runtime logic/state only, not UX quality.
- Do not claim a UI change complete until the implementing agent has captured and inspected the affected states in the relevant actual target runtime. Android packaging is required when the Android host, package, system UI, lifecycle boundary, or release candidate is in scope. Screenshots are transient inspection inputs, not deliverables; their absence from a commit, pull request, or final response is never a finding by itself.
- Do not require Android UI automation to duplicate state transitions already covered by focused Godot tests. Android smoke and target-runtime inspection cover packaging and platform integration; Godot tests cover game-owned behavior.
- Do not add or gate delivery on accessibility work; TalkBack, screen-reader metadata, accessibility services, focus order, enlarged-font checks, and accessibility conformance are explicit non-goals.
- Preserve existing `Semantics.identifier`, `Key`, UI Automator, and host-smoke selectors as automation compatibility contracts, not accessibility requirements.
- Do not expand a UI task into gameplay, protocol, server-authority, or unrelated platform changes.
