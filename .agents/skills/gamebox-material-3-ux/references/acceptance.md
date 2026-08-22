# Acceptance and Evidence

## Audit Output Contract

Every audit or completion review returns these sections in order:

1. Scope and selected profile
2. MUST findings
3. SHOULD findings and recorded deviations
4. MAY decisions
5. Tests and target-runtime commands
6. Screenshot matrix
7. Verdict: complete, incomplete, or blocked

Use only `complete`, `incomplete`, or `blocked`. Missing required evidence produces `incomplete`, or `blocked` with the exact external blocker; it can never be softened to “mostly complete.”

## Skill Gate

Validate the skill metadata, directory shape, reference paths, and progressive routing. Compare against the recorded no-skill baseline, then run the same realistic tasks and at least one new task with the skill. Verify that the result loads the correct platform guidance, classifies MUST/SHOULD/MAY, requires Android Back and dangerous-action confirmation, and refuses completion without runtime evidence. Re-run affected scenarios whenever the skill changes; reading the prose is not a behavioral pass.

## Token Gate

Check schema and required roles, matching containers and `on-*` values, legal types/units/enums, and generated Dart/GDScript mappings against the single token source. Fail on drift or new public hard-coded color, typography, shape, or motion values. Confirm Flutter and Godot share meanings and values without sharing rendering code.

## Component and Flow Gate

Run relevant Flutter Widget and Godot scene tests for default, pressed, focus, disabled, pending, loading, empty, error, success/result, light/dark, standard/enlarged text, content growth, and safe areas.

Exercise affected end-to-end flows: registration and identity recovery; catalog and opponent selection; launch failure/retry; pending move and server accept/reject; disconnect/reconnect and authoritative snapshot recovery; resignation/cancellation confirmation; result and return to lobby; Android Back and visible Back parity; background recovery and game Activity exit. For linked games, deterministic fake services prove state wiring but do not replace the real two-device boundary.

## Android Runtime Screenshot Gate

Every user-facing UI change MUST run as the actual built Android App or packaged Godot game in the relevant declared orientation and phone viewports. Capture every affected state; use multiple screenshots when one cannot demonstrate the change. A mock, fixture, Visual Companion, source inspection, static render, golden, or unit test is not target-runtime visual evidence.

If required screenshots are missing, the verdict is `incomplete` or `blocked` with the exact reason and an explicit statement that visual verification remains incomplete. Approval to release with risk does not convert missing evidence into `complete`.

## Accessibility Gate

Check contrast, non-color cues, 48×48dp public targets, focus order, safe areas, text scaling, roles/names/current state, and important announcements. Verify Flutter with TalkBack. For Godot, verify node metadata and then gate the packaged Android export on both `AccessibilityServer.is_supported()` and real TalkBack operation. Record unsupported bridging as an incomplete platform capability.

## Sensitive-data Rules

Screenshots and retained artifacts MUST exclude invite codes, access tokens, credentials, private user information, internal URLs, revisions, and connection implementation details. Redact or create safe test data before capture; do not rely on post-hoc disclosure.

## Completion Checklist

- [ ] Scope and one profile/Core Contract choice are explicit.
- [ ] MUST, SHOULD deviations, and MAY choices are separated.
- [ ] Token source and both generated mappings are consistent when affected.
- [ ] Relevant component and flow tests pass.
- [ ] Server-authoritative actions remain pending until acknowledged.
- [ ] Android system and visible Back behavior match.
- [ ] Every dangerous action has consequence-named confirmation.
- [ ] Android accessibility capability is verified or explicitly incomplete.
- [ ] Actual target runtime was exercised in the declared orientation/viewports.
- [ ] The screenshot matrix covers all affected states without sensitive data.
- [ ] The repository verification gate passes.
- [ ] Verdict is exactly `complete`, `incomplete`, or `blocked` and matches the evidence.

## Full Audit Example

**Input:** The Gomoku resign button was changed to send the server request immediately. Flutter Widget and Godot tests pass, but no Android screenshot is available.

1. **Scope and selected profile:** Godot Gomoku resign flow; select `Lightweight Board` as a MAY profile while enforcing the Core Contract.
2. **MUST findings:** Fails dangerous-action semantics because resignation reaches the server without a consequence-named confirmation. Android system Back versus visible Back has not been exercised. The built Android game and affected resign state have no runtime screenshot, so runtime visual acceptance is missing.
3. **SHOULD findings and recorded deviations:** No relevant SHOULD deviation is documented.
4. **MAY decisions:** Retain the Lightweight Board floating shell; this choice does not waive Core Contract requirements.
5. **Tests and target-runtime commands:** Flutter Widget and Godot tests passed as reported. Still required: run the packaged Android game, exercise visible Back and system Back, open and cancel/confirm the resign Dialog, and verify that only confirmation sends the server request.
6. **Screenshot matrix:** Missing: Gomoku normal state, consequence-named resign confirmation, and post-cancel state in the declared Android orientation. Capture without user-specific data.
7. **Verdict: incomplete.** Tests alone do not prove dangerous confirmation, Android Back behavior, or target-runtime presentation; add the confirmation and complete Android runtime checks and screenshots.
