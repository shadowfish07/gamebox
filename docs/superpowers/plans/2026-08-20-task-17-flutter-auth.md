# Task 17 Flutter Authentication Implementation Plan

## Scope

Implement the Flutter HTTP/authentication boundary, refresh-token persistence,
session lifecycle, invite registration UI, and authenticated home shell without
changing the existing native Godot launcher bridge.

## TDD sequence

1. Add controller tests for restore, registration, refresh serialization,
   refresh rotation storage failure, lifecycle expiry, and disposal/stale work.
2. Add API boundary tests for strict envelopes, safe diagnostics,
   authorization, single 401 hook invocation, safe GET retry, and no POST body
   replay.
3. Add registration widget tests for rune validation, stable semantics,
   submitting/double-tap behavior, Chinese server errors, safe fallback errors,
   and authenticated navigation.
4. Run the focused tests and capture the expected compile-time RED.
5. Implement the smallest API, token-store, session, controller, registration,
   and app-routing surface that makes the tests pass.
6. Refactor only with the focused tests green, then run Flutter analyze/tests,
   high-count tests, repository fast verification, Android unit/build checks,
   and diff checks.

## Security and lifecycle invariants

- The access token exists only in controller memory.
- The refresh token uses secure-storage key `gamebox.refresh_token.v1` and is
  overwritten before a rotated session becomes visible.
- Refresh is a single-flight Future; a failed API call or failed secure-store
  rotation clears in-memory and persisted authentication.
- API errors retain only bounded `code` and `message`, never response bodies or
  credentials; session diagnostic strings redact credentials.
- A 401 may replay one safe GET after refresh, but never replays a POST body.
- Disposed or superseded controller operations cannot notify listeners or
  publish authenticated state.

## Verification

Run `flutter pub get`, `flutter analyze`, `flutter test`, focused high-count
controller/widget tests, `bash tool/verify_fast.sh`, Android JVM unit tests, a
debug APK compile if practical, and `git diff --check` before the task-scoped
commit.
