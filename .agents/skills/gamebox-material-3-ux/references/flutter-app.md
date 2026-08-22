# Flutter App Guidance

## Theme Contract

Use `ThemeData`, `ColorScheme`, `TextTheme`, component themes, and only necessary `ThemeExtension`s to map the generated Gamebox tokens. Both light and dark schemes come from the fixed Gamebox Teal seed `#006B60`; do not follow wallpaper colors. Flutter and Godot share token names, meanings, and generated values, not Widgets or rendering code.

Pages consume `sys` roles and shared components consume `comp` roles. Do not add public hard-coded colors, typography, corner radii, or animation durations. `useMaterial3: true` is only an enabling setting, not proof that the page conforms.

## Navigation Decision

The App enters, discovers, configures, starts, and resumes games; it does not render gameplay. The current surface has registration, game catalog, opponent selection, and update entry only. The game catalog is the sole top-level destination, so MUST NOT add a `NavigationBar` merely because Material 3 is enabled. Add one only after 3–5 stable top-level destinations exist.

Use a small Material 3 Top App Bar by default. Secondary pages expose visible Back consistent with Android system Back. Show a clear pending state before entering Godot. If launch fails, remain on the source page with retry. On return from a game, refresh match state without a forced redirect or ordinary-success Dialog.

## Page Patterns

- **Registration:** outlined text fields with floating labels; field errors belong to fields, service errors to the form region, and failed submission retains input.
- **Game catalog:** Feed/Card presentation with name, player count, match state, and one primary action.
- **Opponent selection:** List Items; combine text with a secondary visual signal for online, offline, and busy.
- **Active match:** “Continue match” is primary; cancellation before start is a low-emphasis dangerous action with consequence-based confirmation.
- **Update entry:** platform operations such as update or settings MUST NOT compete with start/continue for primary emphasis.

## Component Hierarchy

Each page has at most one highest-emphasis `FilledButton`. Use Filled Tonal or Outlined for secondary actions and Text Button for low-frequency or cancel actions. Use `title_large` for Top App Bar, `title_medium` for card titles, `body_large`/`body_medium` for body, `label_large` for buttons and chips, `body_medium` for supporting text and Snackbar, and `headline_small` for Dialog titles.

Public controls have at least 48×48dp hit targets and use the shared spacing, shape, state, focus, disabled, and error semantics. A dangerous action is identified by consequence, not merely by an error color.

## Async and Error States

Reserve stable layout regions for loading, empty, and error states so content arrival does not cause large shifts. Pending prevents duplicates and communicates progress or status. Keep server-authoritative data pending until accepted; do not turn optimistic UI into a final result. Failure restores usable controls, preserves valid input, and offers retry or another explicit next step.

Use inline validation for fields, Snackbar for transient recoverable events, page state for content failures, Dialog for dangerous decisions, and full-screen blocking only when the App cannot continue. Do not expose internal connection details.

## Responsive and Text Scaling

Verify typical narrow and large Android phones. Pages MUST handle safe areas and system text scaling. At standard and enlarged text, allow reflow, wrapping, or scrolling; do not clip labels, status, or the primary action. This version does not promise tablet, foldable, ChromeOS, desktop, or simultaneous orientation layouts.

## Semantics

Expose TalkBack names, roles, values/current states, focus order, and important state changes. Use restrained live regions for errors and async changes. Never use color alone. Preserve existing stable semantics identifiers and keys so accessibility, automation, and users do not lose established targets; if a change is necessary, update all callers and tests deliberately.

## Widget and Android Checks

Widget tests cover default, pressed, focus, disabled, pending, loading, empty, error, success, light/dark, standard/enlarged text, content growth, and safe areas as relevant. Flow checks cover registration/identity recovery, catalog/opponent selection, Godot launch failure/retry, and return-state refresh.

Run the actual built Android App at the affected viewports and states. Verify visible and system Back parity, TalkBack behavior, text scaling, touch targets, and absence of overflow. Capture non-sensitive screenshots of every affected state; Widget tests, goldens, mocks, and static inspection do not replace them.
