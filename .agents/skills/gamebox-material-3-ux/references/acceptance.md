# Acceptance and Evidence

## Audit Output Contract

Every audit or completion review returns these sections in order:

1. Scope and selected profile
2. MUST findings
3. SHOULD findings and recorded deviations
4. MAY decisions
5. Tests and target-runtime commands
6. Target-runtime UX inspection findings
7. Verdict: complete, incomplete, or blocked

Use only `complete`, `incomplete`, or `blocked`. Missing required runtime verification produces `incomplete`, or `blocked` with the exact external blocker; it can never be softened to “mostly complete.” A fixed deterministic E2E may complete its logic gate, but UI work also requires the implementing agent to inspect the affected runtime states.

## Skill Gate

Validate the skill metadata, directory shape, reference paths, and progressive routing. Compare against the recorded no-skill baseline, then run the same realistic tasks and at least one new task with the skill. Verify that the result loads the correct platform guidance, classifies MUST/SHOULD/MAY, requires Android Back and dangerous-action confirmation, keeps screenshots out of deterministic E2E, requires the implementing agent to inspect affected UI screenshots, and never treats unpublished screenshots as missing deliverables. Re-run affected scenarios whenever the skill changes; reading the prose is not a behavioral pass.

## Token Gate

Check schema and required roles, matching containers and `on-*` values, legal types/units/enums, and generated Dart/GDScript mappings against the single token source. Fail on drift or new public hard-coded color, typography, shape, or motion values. Confirm Flutter and Godot share meanings and values without sharing rendering code.

## Component and Flow Gate

Run relevant Flutter Widget and Godot scene tests for default, pressed, disabled, pending, loading, empty, error, success/result, light/dark, normal-size text, content growth, and safe areas.

Exercise only the end-to-end flows whose boundary is affected: registration and identity recovery; catalog and opponent selection; launch failure/retry; pending move and server accept/reject; disconnect/reconnect and authoritative snapshot recovery; resignation/cancellation confirmation; result and return to lobby; Android Back and visible Back parity; background recovery and game Activity exit. For a Godot-only UX change, cover game-owned state behavior in Godot tests and use Android only for launch/host smoke plus final visual inspection. For linked games, deterministic fake services prove state wiring but do not replace the real two-device boundary when networking, protocol, or cross-device behavior changed.

## Android Runtime Evidence Modes

Every user-facing UI change MUST run as the actual built Android App or packaged Godot game in the relevant declared orientation and phone viewports. A mock, fixture, Visual Companion, source inspection, static render, golden, or unit test is not target-runtime evidence.

### Fixed deterministic E2E

The fixed two-device E2E uses state markers, UI Automator identifiers, lifecycle checks, authoritative snapshots, and protocol assertions. It MUST NOT capture screenshots, perform pixel crops/SSIM, or retain image artifacts. A passing run proves the exercised runtime logic and state transitions; it does not prove UX quality.

Do not make fixed Android E2E the inner loop for Godot scene styling. A Godot-only UI change normally needs focused Godot tests plus a packaged-game launch smoke; reserve the full two-device matrix for changes that affect its cross-runtime or network assertions.

### Godot preview evidence

Directly launched Godot previews are the preferred inner loop for game UX. They instantiate production UI at representative phone viewports, expose deterministic states, and let the implementing agent capture and inspect screenshots quickly. They are stronger than source inspection for layout tuning but remain pre-Android evidence: they do not prove Android packaging, safe-area integration, Activity lifecycle, or host rendering.

### Agent UX inspection

For UI changes, the implementing agent captures and inspects enough screenshots from the actual target runtime to judge every affected state. If the agent cannot capture or inspect those states, the verdict is `incomplete` or `blocked` with the exact reason. The screenshots themselves are transient inspection inputs: they need not be committed, retained, uploaded, attached, or included in a pull request or final response unless the user explicitly requests publication. A reviewer MUST NOT report the absence of published screenshots as a finding.

## Layout and Interaction Gate

Check 48×48dp public targets, safe areas, normal-size text wrapping, content growth, pressed/pending/disabled feedback, and absence of overflow. Accessibility conformance, TalkBack, screen-reader metadata/roles/live regions, accessibility-service probes, focus order, enlarged-font acceptance, WCAG contrast thresholds, and reduced-motion gates are explicit non-goals. Existing semantics identifiers and selectors remain automation contracts only.

## Sensitive-data Rules

Captured UI and retained artifacts MUST exclude invite codes, access tokens, credentials, private user information, internal URLs, revisions, and connection implementation details. Redact or create safe test data before capture; do not rely on post-hoc disclosure.

## Completion Checklist

- [ ] Scope and one profile/Core Contract choice are explicit.
- [ ] MUST, SHOULD deviations, and MAY choices are separated.
- [ ] Token source and both generated mappings are consistent when affected.
- [ ] Relevant component and flow tests pass.
- [ ] Godot-owned state, controller, scene-contract, and launch tests cover changed game invariants without screenshot goldens.
- [ ] Server-authoritative actions remain pending until acknowledged.
- [ ] Android system and visible Back behavior match.
- [ ] Every dangerous action has consequence-named confirmation.
- [ ] Actual target runtime was exercised in the declared orientation/viewports.
- [ ] Fixed E2E logic assertions pass when that gate is in scope.
- [ ] The implementing agent inspected screenshots of every affected UI state and reported the UX findings; publishing the images is not required.
- [ ] The repository verification gate passes.
- [ ] Verdict is exactly `complete`, `incomplete`, or `blocked` and matches the evidence.

## Full Audit Example

**Input:** The Gomoku resign button was changed to send the server request immediately. Flutter Widget and Godot tests pass, but the implementing agent could not inspect the updated Android UI.

1. **Scope and selected profile:** Godot Gomoku resign flow; select `Lightweight Board` as a MAY profile while enforcing the Core Contract.
2. **MUST findings:** Fails dangerous-action semantics because resignation reaches the server without a consequence-named confirmation. Android system Back versus visible Back has not been exercised. The implementing agent has not inspected the affected UI in the built Android game.
3. **SHOULD findings and recorded deviations:** No relevant SHOULD deviation is documented.
4. **MAY decisions:** Retain the Lightweight Board floating shell; this choice does not waive Core Contract requirements.
5. **Tests and target-runtime commands:** Flutter Widget and Godot tests passed as reported. Still required: run the packaged Android game, exercise visible Back and system Back, open and cancel/confirm the resign Dialog, and verify that only confirmation sends the server request.
6. **Target-runtime UX inspection findings:** Unavailable because the implementing agent could not inspect the affected states. No screenshot publication is required.
7. **Verdict: incomplete.** Tests alone do not prove dangerous confirmation, Android Back behavior, or target-runtime presentation; add the confirmation and complete the Android runtime interaction and UX inspection.
