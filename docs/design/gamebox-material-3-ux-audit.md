# Gamebox Material 3 UX Retrofit Audit

## Scope and Selected Profile

This is the pre-change audit for the Gamebox Flutter App and the packaged Godot Gomoku game on Android phones. It is based on source and deterministic test inspection at `bf280fb`; it is not target-runtime acceptance evidence. The App scope is registration, session recovery, game catalog, active-match actions, opponent selection, and the update entry. The game scope is the current Gomoku scene, controller, board input, public status, return, resign, and result surfaces.

The Flutter App uses the **Flutter App** guidance. Gomoku declares the optional **Lightweight Board** profile in `docs/design/profiles/gomoku.md`, with portrait as its one default orientation. The profile choice applies only to Gomoku and does not make a visible Gamebox shell the default for another game. The Core Contract remains mandatory in both runtimes.

Inspected production surfaces and their present responsibility:

| File | Current evidence |
| --- | --- |
| `app/lib/app.dart` | App lifecycle restoration/foreground refresh is wired at lines 128–146; `MaterialApp` enables Material 3 with a `deepPurple` seed at lines 232–242; restoring and invalid-credential loading states are at lines 255–290. |
| `app/lib/features/auth/registration_page.dart` | Registration, restore retry, and credential-cleanup states are at lines 99–279; stable automation identifiers are declared at lines 128–194. |
| `app/lib/features/home/home_page.dart` | Home loading/error/catalog selection is at lines 85–128; the Gomoku card and active-match actions are at lines 154–277. |
| `app/lib/features/home/opponent_page.dart` | Initial/in-place loading, empty/error, opponent availability, and create-pending states are at lines 104–205. |
| `app/lib/features/update/update_action.dart` | The secondary App Bar update entry is at lines 6–38; update dialog states and progress are at lines 40–190. |
| `game_runtime/games/gomoku/gomoku_scene.tscn` | The current visible shell and board use fixed portrait offsets, sizes, colors, and font overrides at lines 15–110. |
| `game_runtime/games/gomoku/gomoku_controller.gd` | Move/resign/Back handlers are at lines 127–159; reconnect/snapshot/error handling is at lines 162–214; visible game states and action gating are at lines 217–290. |
| `game_runtime/games/gomoku/gomoku_board.gd` | Board tokens are currently literal colors at lines 6–21; coordinate snapping and touch handling are at lines 83–168; accepted, last-move, and pending rendering are at lines 171–203. |

The Godot project already requests portrait and expanded canvas stretching (`game_runtime/project.godot:15–21`), and its headless test asserts the portrait setting (`game_runtime/test/test_main.gd:144–155`). Target Android orientation, cutouts, and safe areas still require runtime verification.

## Existing Strengths to Preserve

- **Server authority is not bypassed.** A local move request only refreshes presentation (`game_runtime/games/gomoku/gomoku_controller.gd:127–133`); the controller renders the reducer's confirmed board plus a separate pending coordinate (`game_runtime/games/gomoku/gomoku_controller.gd:217–229`), disables a second move while an action is pending (`game_runtime/games/gomoku/gomoku_controller.gd:242–246`), and the board draws pending separately from stones (`game_runtime/games/gomoku/gomoku_board.gd:185–203`). Tests explicitly assert that pending does not place a stone and only an accepted event commits it (`game_runtime/test/test_gomoku_board.gd:99–112`, `game_runtime/test/test_gomoku_scene.gd:267–283`, `game_runtime/test/test_gomoku_state.gd:117–130,155–173`).
- **Reconnect preserves authority and locks actions.** Connection or snapshot recovery sets `_awaiting_snapshot`, keeps actions disabled, and unlocks only after an applied authoritative snapshot (`game_runtime/games/gomoku/gomoku_controller.gd:162–187,237–246`). Scene tests cover stale-revision locking, older/invalid snapshots, reconnect, and recovery (`game_runtime/test/test_gomoku_scene.gd:80–228`). Preserve the last confirmed board during this path.
- **Back is source-level non-destructive.** Visible Back and `ui_cancel` converge on `_on_back_pressed`, which disposes the client and exits without calling resign (`game_runtime/games/gomoku/gomoku_controller.gd:145–159`). The scene test proves direct Back does not add a resignation and quits once (`game_runtime/test/test_gomoku_scene.gd:242–264`). Packaged Android visible/system Back parity is not yet proved.
- **Safe public copy and terminal states exist.** Protocol errors map to fixed user-safe Chinese messages (`game_runtime/games/gomoku/gomoku_controller.gd:9–20,204–214`), and win, loss, draw, cancelled, and abandoned copy is selected without exposing revisions (`game_runtime/games/gomoku/gomoku_controller.gd:250–266`). Tests cover the public connection/error strings and terminal outcomes (`game_runtime/test/test_gomoku_scene.gd:31–77,231–239`).
- **Flutter already prevents duplicate mutations.** Registration exposes visible progress and disables submit (`app/lib/features/auth/registration_page.dart:177–193`); continue/cancel share mutation gating and continue exposes a live pending message (`app/lib/features/home/home_page.dart:246–272`). Tests assert duplicate registration, launch, create, and cancel suppression (`app/test/features/auth/registration_page_test.dart:81–112`, `app/test/features/home/home_page_test.dart:110–217`, `app/test/features/home/opponent_page_test.dart:76–119`).
- **Recovery paths remain actionable.** Registration offers restore and credential-cleanup retry (`app/lib/features/auth/registration_page.dart:203–279`), Home replaces an initial failure with a retry action (`app/lib/features/home/home_page.dart:106–114,131–151`), and opponent selection retains/reloads content around recoverable failures (`app/lib/features/home/opponent_page.dart:46–95,125–153`).
- **Navigation and emphasis are already restrained.** The catalog is the sole top-level destination and has no unnecessary `NavigationBar`; the update entry is an App Bar icon (`app/lib/features/update/update_action.dart:6–38`) rather than a competing page primary action. Opponent selection uses the standard Navigator and a secondary page App Bar (`app/lib/features/home/home_page.dart:57–67`, `app/lib/features/home/opponent_page.dart:104–109`).
- **Stable automation targets must not drift.** Preserve semantics identifiers `invite-code`, `nickname`, `register`, `game-gomoku`, `choose-opponent`, `continue-match`, `cancel-match`, `opponent-<user-id>`, `opponent-error`, and `app-update`, plus established keys for session/cleanup loading and retry, Home, opponent loading, update install, and host smoke. Their production declarations are in `app/lib/app.dart:255–364`, `app/lib/features/auth/registration_page.dart:128–194,219–272`, `app/lib/features/home/home_page.dart:88–89,180–205,246–300`, `app/lib/features/home/opponent_page.dart:112–179`, and `app/lib/features/update/update_action.dart:17–34,101–115`. The identifier-driven integration checks are at `app/integration_test/semantics_test.dart:23–147`.

## MUST Findings

| ID | Finding and exact evidence | Required closure without changing gameplay/server authority |
| --- | --- | --- |
| M1 | **No shared semantic token pipeline is consumed.** Flutter's only app theme is the inline `deepPurple` seed (`app/lib/app.dart:232–240`); page spacing and progress sizes are literal values, for example registration at `app/lib/features/auth/registration_page.dart:110–199` and update at `app/lib/features/update/update_action.dart:65–120,154–189`. Godot public UI uses literal colors/font sizes in `game_runtime/games/gomoku/gomoku_scene.tscn:23–110`, while board roles are literal colors in `game_runtime/games/gomoku/gomoku_board.gd:6–21`. | Add the schema-validated `1.0.0` Gamebox token source, committed generated Dart/GDScript mappings, drift checks, and production consumption of `sys`, `comp`, and controlled `game` roles. No public UI may read `ref` or silently fall back. |
| M2 | **The fixed Gamebox Teal light/dark contract is absent.** `MaterialApp` supplies only `theme` from `Colors.deepPurple` and has no `darkTheme`/scheme selection (`app/lib/app.dart:232–242`). Godot exposes one hard-coded light presentation (`game_runtime/games/gomoku/gomoku_scene.tscn:15–23,39–64,83–96`; `game_runtime/games/gomoku/gomoku_board.gd:15–21`). | Generate/version light and dark schemes from `#006B60`; map matching container/on-container pairs and verify all public text, controls, board pieces, last move, and pending move in both schemes. Do not use wallpaper dynamic color. |
| M3 | **Dangerous actions send immediately without consequence-named confirmation.** Home `_cancelMatch` directly calls cancellation (`app/lib/features/home/home_page.dart:74–76`), and its text button calls that handler directly (`app/lib/features/home/home_page.dart:261–272`). Gomoku `_on_resign_pressed` directly calls `request_resign` (`game_runtime/games/gomoku/gomoku_controller.gd:136–142`). Existing tests encode the immediate behavior (`app/integration_test/semantics_test.dart:110–147`; `game_runtime/test/test_gomoku_scene.gd:242–258`). | Insert shared confirmation surfaces whose title/action state the object and consequence; cancel must send only after confirming “cancel this unstarted match,” and resign only after confirming “resign and end this match.” Cancel/close sends no request; retain duplicate gating after confirmation. |
| M4 | **Safe-area and scalable layout conformance is not established in Godot.** The scene is a fixed 1080×1920 absolute layout (`game_runtime/games/gomoku/gomoku_scene.tscn:25–110`). The existing test freezes those positions and minimum sizes (`game_runtime/test/test_gomoku_scene.gd:286–297`) but does not exercise cutouts, gesture regions, rounded corners, normal-size long copy, or both target phone viewports. | Move public shell placement to safe-area-aware layout containers while leaving the board dominant; retain ≥48dp Back/resign/dialog targets and verify portrait on narrow and large Android phones. |
| M5 | **The dense board lacks a visible pressed state.** Touch capture, drag cancellation, and release submission exist (`game_runtime/games/gomoku/gomoku_board.gd:133–168`), but drawing covers only confirmed stones, last move, and pending move (`game_runtime/games/gomoku/gomoku_board.gd:171–203`). The headless test proves snapping and safe release only (`game_runtime/test/test_gomoku_board.gd:19–112`). | Keep the entire playfield continuously hittable, snap to the nearest intersection, and show pressed → pending → accepted/rejected distinctly in the packaged Android game. |
| M6 | **Background recovery and Android Back parity are only partially evidenced.** Flutter refreshes session/Home after App resume (`app/lib/app.dart:128–146`) and Godot reconnect/snapshot logic is tested headlessly, but the inspected sources/tests do not prove a backgrounded packaged game synchronizes before re-enabling moves or that Android system Back matches visible Back in the actual Game Activity. | Exercise background/resume, authoritative synchronization, visible Back, system Back, and Game Activity exit on packaged Android. Back must never resign/cancel/discard progress, and returning to the lobby must leave the active match resumable. |
| M7 | **Required state and visual acceptance evidence is missing.** Current Widget/headless tests cover useful wiring, but not the complete light/dark, normal-size content-growth, safe-area, confirmation, interaction-state, and screenshot gates. This documentation-only task intentionally captures no runtime screenshots. | Pass focused component/flow tests, the repository gate, real two-device linked flow, and every screenshot row below on the final clean HEAD. Fake services remain wiring evidence only. |
| M8 | **Ordinary update feedback is incorrectly forced through one Dialog.** An idle tap awaits `checkNow()` and then unconditionally calls `showDialog` (`app/lib/features/update/update_action.dart:40–52`); the single `AlertDialog` hosts every state (`app/lib/features/update/update_action.dart:54–121`), including ordinary checking, up-to-date success, download progress, and failure (`app/lib/features/update/update_action.dart:127–150`). This conflicts with the skill's rule to use component/Snackbar/inline feedback for ordinary state and Dialog only for decisions or danger, never ordinary success (`.agents/skills/gamebox-material-3-ux/references/ux-standard.md:56–60`; `.agents/skills/gamebox-material-3-ux/references/flutter-app.md:29–33`). | In Task 5, keep the existing `UpdateController`, service/installer calls, state transitions, `app-update` identifier, and `downloadAndInstall` business behavior, but route checking/downloading to an inline or anchored non-blocking progress surface, up-to-date to quiet transient feedback, and recoverable failure to non-blocking feedback with retry. Reserve an App Dialog only for a real release/install decision; preserve Android's system permission/installer confirmation where the user must decide. |

## SHOULD Findings and Decisions

| ID | Current deviation or decision | Reason and alternative measure |
| --- | --- | --- |
| S1 | Registration uses separate labels plus empty `InputDecoration` borders and reports all validation in one form-level region (`app/lib/features/auth/registration_page.dart:120–175`), rather than outlined floating labels with field-local errors. | No exception is approved for the retrofit. Preserve entered input and stable identifiers while moving invite/nickname validation to the applicable field; keep service failures in a stable form region. |
| S2 | The catalog card title uses `headlineSmall` (`app/lib/features/home/home_page.dart:180–195`) instead of the standard `titleMedium`, and repeated page dimensions are literals rather than the 4dp/8dp token rhythm. | No exception is approved. Retain the one-card catalog and action hierarchy, but consume generated typography/spacing/component mappings. |
| S3 | Opponent availability already uses understandable “在线/离线/游戏中” text, but the rows have no tokenized supplemental status treatment (`app/lib/features/home/opponent_page.dart:156–188`). | Add an icon, shape, or status treatment if it improves ordinary visual clarity; this is not an accessibility or release-completion gate. |
| S4 | Loading/error/content branches replace one another without an explicitly reserved stable content region on Home and initial opponent load (`app/lib/features/home/home_page.dart:97–124`; `app/lib/features/home/opponent_page.dart:112–153`). | No exception is approved. Use stable page/card regions and scrolling/reflow so async arrival and normal-size long copy do not move or clip the primary action. |
| S5 | Gomoku permanently shows `ConnectionLabel`, including “已连接” (`game_runtime/games/gomoku/gomoku_controller.gd:231–233,281–290`), although the Lightweight Board profile emphasizes connection only during connect, reconnect, or failure. | **Recorded Gomoku profile deviation.** Reason: the current baseline exposes connection status as a separate always-visible line. Alternative measure for the retrofit: keep explicit connecting/sync/reconnect/failure status, collapse the steady connected detail, and continue to expose turn/pending state through `StatusLabel`. |

No other SHOULD deviation is approved. Token use, safe areas, dangerous confirmation, state feedback, and runtime evidence are MUST items and cannot be waived as profile deviations.

## MAY Decisions

- Keep the App without a `NavigationBar`; the game catalog remains its sole stable top-level destination (`app/lib/features/home/home_page.dart:85–128`).
- Retain a small App Bar and the update entry as a secondary icon action (`app/lib/features/update/update_action.dart:6–38`); update/settings must not compete with start or continue.
- Adopt the optional Lightweight Board visible shell for Gomoku: return, title, transient connection/recovery status, turn/player/pending HUD, dominant board, and resign outside the playfield. This is a Gomoku choice only.
- Keep Gomoku's board, grid, pieces, last-move marker, and pending marker game-owned. Only their semantic roles/values cross runtimes; Widgets/rendering code do not.
- Use Snackbar for transient recoverable Flutter failures, inline/page state for content failures, shared Dialog for cancel/resign decisions, and the shared result/return panel for terminal game states.
- Use only lightweight reproducible motion. Decorative transitions remain optional and cannot replace the required pressed/pending/result states.

## Out of Scope

- Go server implementation or deployment.
- Wire protocol, event envelopes, server authority, or reconnect algorithm changes.
- Gomoku matching rules, cancellation eligibility, turn logic, scoring, board size, or win rules.
- Other current or future games and any rule that makes Gomoku's visible shell their default.
- Tablet, foldable, ChromeOS, desktop, or simultaneous portrait/landscape layout support.
- Android wallpaper-derived dynamic color; Gamebox uses fixed versioned schemes from `#006B60`.
- Cross-runtime shared rendering, Flutter-rendered gameplay, or replacing Godot board/game art with App components.
- Silent update installation, new App destinations, gameplay audio, or unrelated platform behavior.
- Accessibility conformance, TalkBack, screen-reader metadata/roles/live regions, `AccessibilityServer` probes, focus-order gates, enlarged-font acceptance, WCAG contrast thresholds, or reduced-motion gates. The prior accessibility findings were removed from MUST by the user's explicit scope update; existing semantics identifiers remain automation contracts only.

## Test Plan

All Flutter/Dart commands inherit the retrofit plan's [Locked Execution Baseline](../superpowers/plans/2026-08-22-gamebox-material-3-ux-retrofit.md#locked-execution-baseline). This reusable audit does not duplicate a machine installation path. In every new shell, apply that baseline and verify tool ownership and versions before running any Flutter/Dart command:

```bash
command -v flutter
flutter --version
command -v dart
dart --version
(cd app && flutter pub get --enforce-lockfile --dry-run)
```

Expected: the selected executables are the plan-locked tools, `flutter --version` reports Flutter 3.47.1 with Dart 3.13.1, `dart --version` reports Dart 3.13.1, and the lockfile dry-run exits 0. If any check differs, stop rather than falling back to another SDK.

Deterministic closure plan, in order:

1. Validate the design-token schema, required `ref`/`sys`/`comp`/`game` roles, legal values, matching container/on-container pairs, generated Dart/GDScript output, and zero drift. The resulting design-system verifier must be part of `bash tool/verify_fast.sh`.
2. Run focused Flutter tests for registration, Home, opponents, update, confirmations, identifiers, pending/disabled states, launch failure/retry, light/dark schemes, 360×800 and 412×915 constraints, normal-size text, content growth, and safe-area padding:

   ```bash
   (cd app && flutter test test/features/auth/registration_page_test.dart test/features/home/home_page_test.dart test/features/home/opponent_page_test.dart test/features/update/update_action_test.dart)
   ```

   `app/test/features/update/update_action_test.dart` does not exist in the pre-change baseline; Task 5 creates it test-first before executing this command. It must cover non-blocking checking, up-to-date, downloading, and failure; the available-update install decision; permission/installer handoff; stable identifiers; retry; scrolling; and overflow across the required themes and viewports at normal text size without changing update business logic.

   Run `integration_test/semantics_test.dart` only through the leased Android path in `bash tool/e2e_android.sh`, which supplies the managed device with `-d "$SERIAL_A"`; do not start or address an unleased emulator.

3. Run deterministic Godot board/scene/state tests for nearest-intersection touch, pressed/pending/accepted/rejected states, stale revision, reconnect/snapshot recovery, Back, cancel/resign confirmation, result, theme mapping, and layout:

   ```bash
   bash tool/verify_godot_tests.sh
   ```

4. Run the repository gates on the exact candidate HEAD:

   ```bash
   bash tool/verify_fast.sh
   bash tool/verify.sh
   ```

5. With the repository's shared Android lease, run the actual built App and packaged Godot game on `Gamebox_A_API_36` and `Gamebox_B_API_36`; drive the real two-device flow with `bash tool/e2e_android.sh`. Assert logs/state as well as pixels. Deterministic fake services prove UI/state wiring, not the live WebSocket/server boundary.
6. On both Android phone viewports, verify visible/system Back parity, background/resume authority sync, declared portrait orientation, touch targets, safe areas, normal-size text wrapping, and overflow.
7. Capture every row in the screenshot matrix from the actual built runtime using safe scripted identities; inspect each PNG for clipping, state accuracy, and sensitive data. Re-run the full gate and screenshot harness from the final clean HEAD before changing the verdict.

Existing regression anchors that must continue to pass include Flutter identifier semantics (`app/integration_test/semantics_test.dart:23–147`), Home mutation gating/retry (`app/test/features/home/home_page_test.dart:110–217,310–340`), opponent status/create recovery (`app/test/features/home/opponent_page_test.dart:20–119`), board touch/pending (`game_runtime/test/test_gomoku_board.gd:19–112`), and scene reconnect/Back/pending/result (`game_runtime/test/test_gomoku_scene.gd:37–297`).

## Android Screenshot Matrix

Every listed capture is currently **missing** and is required after the retrofit. `N` means a narrow 360×800 Android phone viewport; `L` means a large 412×915 Android phone viewport. Both are portrait on API 36 at normal system text size. Capture both light and dark unless a row explicitly concerns system UI.

| Runtime/surface | Required state | Viewport/theme evidence |
| --- | --- | --- |
| Flutter registration | Default outlined fields and update entry | N + L, light + dark, 1.0× |
| Flutter registration | Field-local invite error; field-local nickname error; service/form error with retained input | N + L, light + dark |
| Flutter registration | Submit pending/disabled with explicit progress | N + L, light + dark, 1.0× |
| Flutter session | First restore loading; restore retry; credential cleanup pending; cleanup retry | N + L, light + dark |
| Flutter catalog | Initial loading; recoverable page error/retry; idle Gomoku card | N + L, light + dark |
| Flutter active match | Continue primary at revision >0; revision-zero cancel available | N + L, light + dark |
| Flutter active match | Continue launch pending/disabled; launch failure with retry path | N + L, light + dark, 1.0× |
| Flutter active match | Consequence-named cancel confirmation; post-cancel return state | N + L, light + dark |
| Flutter opponents | Initial loading; empty list; online/idle, offline/idle, and busy rows | N + L, light + dark |
| Flutter opponents | Row create pending; recoverable inline error with retained rows; full-page load error/retry | N + L, light + dark, 1.0× |
| Flutter update | Checking; up to date; update available | N + L, light + dark |
| Flutter update | Download progress; permission required; failed/retry; installer opened | N + L, light + dark, 1.0× |
| Android installer | System unknown-app permission and final installer confirmation | One real target device per distinct system surface; no credentials |
| Godot Gomoku | First connect and initial snapshot synchronization | N + L, light + dark, 1.0× |
| Godot Gomoku | Local turn/black and local turn/white; opponent turn | N + L, light + dark |
| Godot Gomoku | Board pressed intersection; pending move; accepted move with last-move marker | N + L, light + dark, 1.0× |
| Godot Gomoku | Rejected move/error with interaction restored | N + L, light + dark, 1.0× |
| Godot Gomoku | Reconnecting with last confirmed board preserved; resynchronized state; terminal connection failure/return action | N + L, light + dark, 1.0× |
| Godot Gomoku | Consequence-named resign confirmation; post-cancel state; resign pending | N + L, light + dark |
| Godot Gomoku | Win, loss, draw, cancelled, and abandoned result/return panels | N + L across the set, with both light and dark represented |
| Cross-runtime flow | Visible Back return; Android system Back return; background/resume synchronized state | N + L, actual App/Game transition, light + dark represented |

Artifacts must not contain invite codes, access/refresh/launch tokens, private user data, internal URLs, revisions, or connection implementation details.

## Pre-change Verdict

`incomplete`

The current implementation has valuable authority, reconnect, recovery, Back, and stable-identifier foundations, but it does not yet satisfy the shared token/light-dark contract, dangerous confirmations, Godot adaptive safe-area layout, full interaction-state feedback, or actual Android evidence. Source inspection and current deterministic tests cannot substitute for the missing packaged-runtime, two-device, and screenshot gates.

## Post-change Closure Evidence

The implementation and deterministic repository checks are present, but the final packaged-runtime evidence is not verified in this checkout. The required two-AVD run, sanitized artifact manifest, and screenshot review must complete before closure; no artifact path or passed result is recorded here.

## Post-change Verdict

`incomplete`

The source-level UX retrofit and deterministic checks can be reviewed, but closure remains blocked on the actual Android two-device runtime and screenshot evidence. Accessibility conformance remains an explicit non-goal per the recorded scope.
