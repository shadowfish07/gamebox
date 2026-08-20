# Gamebox

Gamebox is an Android game collection. Its first complete playable loop is a
two-player, server-authoritative Gomoku match.

## Architecture and scope

- `app/` is the Flutter entry point and Android host. It owns registration,
  automatic login, the catalog, opponent selection, and launching a game.
- `game_runtime/` is the embedded Godot runtime. It owns game rendering,
  input, reconnect behavior, and applying authoritative snapshots/events.
- `server/` is the Go HTTP/WebSocket service and SQLite authority. It owns
  identity, one-time invites, game slots, rules, revisions, and outcomes.
- `protocol/` contains the versioned wire contract; `tool/` owns repeatable
  verification and the isolated two-emulator release gate.

Flutter and Godot do not decide whether a move or result is valid. Kotlin only
bridges the Flutter host to the full-screen `GodotActivity`, and passes a
`gameId`, one-time launch ticket, and required non-secret configuration. The Go
service persists accepted events before broadcasting them.

This phase is Android-only and includes registration, lobby/opponent selection,
one Gomoku game, force-stop recovery, completion, slot release, and zero-move
cancellation. It does not include AI, local multiplayer, friends, matchmaking,
chat, spectating, push notifications, public deployment, or account migration.

## Required development tools

- Flutter 3.35.1 with its Dart 3.9 SDK
- Go 1.25
- Godot 4.7 (set `GODOT_BIN` when it is not installed as the macOS app)
- JDK 17 or newer
- Android SDK platform 36, `adb`, `emulator`, and accepted Android licenses

The complete local E2E additionally uses Bash, curl, ffmpeg, Git, jq, lsof,
OpenSSL, ripgrep, Ruby, sed, `shasum`, and unzip. It requires the installed
`system-images;android-36;google_apis_playstore_ps16k;arm64-v8a` image. Check
the toolchain without modifying it:

```bash
bash tool/bootstrap.sh
```

`bootstrap.sh` is deliberately non-destructive: it reports missing versions,
SDK components, or licenses and exits nonzero; it does not install or accept
anything.

## Local server

The server requires two independent secrets of at least 32 bytes. Its SQLite
file must have an existing direct parent owned by the service user and not be
group- or world-writable.

```bash
gamebox_data_dir="$(mktemp -d)"
export GAMEBOX_DB_PATH="$gamebox_data_dir/gamebox.db"
export GAMEBOX_JWT_SECRET="$(openssl rand -base64 32)"
export GAMEBOX_TOKEN_PEPPER="$(openssl rand -base64 32)"
export GAMEBOX_ADDR="127.0.0.1:8080"
(cd server && go run ./cmd/gameboxd)
```

`GAMEBOX_ADDR` defaults to `127.0.0.1:8080`. `GAMEBOX_DB_PATH` defaults to
`server/data/gamebox.db` when the daemon is launched from the repository root;
create `server/data` with mode `0700` before using that default. Runtime SQLite
data and its WAL/SHM sidecars are local state and are ignored by Git.

The Android debug client defaults to `http://10.0.2.2:8080`. Android emulators
map `10.0.2.2` to the host machine's loopback interface, whereas `127.0.0.1`
inside an emulator refers to that emulator. Override the client endpoint at
build time when required:

```bash
(cd app && flutter build apk --debug \
  --dart-define=GAMEBOX_API_BASE_URL=http://10.0.2.2:8080)
```

`GET /healthz` returns exactly `{"status":"ok"}`. The daemon emits JSON-line
operational logs to stderr and supports graceful `SIGINT`/`SIGTERM` shutdown.

## One-time invites and read-only inspection

Generate invites only after setting `GAMEBOX_TOKEN_PEPPER` to the same value as
the running service:

```bash
(cd server && go run ./cmd/gameboxctl invite create \
  --count 2 --db "$GAMEBOX_DB_PATH" --json)
```

The command prints each plaintext invite only in its one success response;
SQLite stores domain-separated hashes. A batch is atomic, and `--count` must be
between 1 and 1000.

Inspect an existing match without mutating application data:

```bash
(cd server && go run ./cmd/gameboxctl match show \
  --id 11111111-1111-4111-8111-111111111111 \
  --db "$GAMEBOX_DB_PATH" --json)
```

`match show` reuses authoritative event replay rather than a second board
implementation. It opens a closed database read-only without creating sidecar
files. For an active WAL database it reads through verified read-only handles
into a private temporary snapshot, then removes that snapshot. It never
migrates or repairs the source and does not change source bytes or metadata.

Keep invite output, JWT/pepper values, access and refresh tokens, launch and
resume tickets, databases, and private input outside logs, shell history,
commits, and shared artifacts. Server logs use request/connection/match IDs,
never credential plaintext.

## Verification

Run the fast source gate while iterating, or the unified CI-equivalent gate
before committing:

```bash
bash tool/verify_fast.sh
bash tool/verify.sh
```

`verify_fast.sh` runs Go, Flutter, and Godot tests, Flutter analysis, and the
Android smoke-log parser fixture. `verify.sh` first runs the non-destructive
bootstrap check, then the fast gate, Kotlin unit tests, a Flutter debug APK
build, and assertions that the APK includes the Godot runtime while excluding
Godot tests/editor caches and secret-named or server-secret assets. CI runs
only `bash tool/verify.sh`; it does not start an emulator.

The two-emulator local release gate is:

```bash
bash tool/e2e_android.sh --self-test
bash tool/e2e_android.sh
```

The full E2E requires a clean worktree and records the exact starting commit
and built/installed APK SHA-256 values. It takes the Git common-directory lease
before using Android. With no serial overrides it creates/starts only
`Gamebox_A_API_36` and `Gamebox_B_API_36` on ports 5560/5562 and cleans up only
those processes/packages; it does not stop, wipe, clear logcat, or change an
unrelated emulator such as `emulator-5554`. Alternatively, set both
`GAMEBOX_E2E_SERIAL_A` and `GAMEBOX_E2E_SERIAL_B`; supplied devices are selected
but not created, wiped, restarted, or stopped.

The semantics integration test always uses the selected A-device explicitly:

```bash
(cd app && flutter test -d emulator-5560 \
  integration_test/semantics_test.dart)
```

Replace `emulator-5560` with the selected Gamebox-owned serial. UI automation
selects stable resource IDs, not translated labels or content descriptions.
Match and revision progress require independent signals to agree: bounded
device ready/state logs plus the authoritative read-only `gameboxctl` snapshot;
board crops from both devices are also checked against that snapshot before the
next move. This proves wiring and rendered state without making UI text or an
E2E-only board model authoritative.

Artifacts are written under `artifacts/e2e/<UTC timestamp>/` only after
sanitization and secret scanning. They include serial/API level, commit and APK
provenance, assertions, screenshots, sanitized server output, and the final
read-only match snapshot, but no invites or tokens. Each adb/UI operation and
build has a bounded watchdog; `GAMEBOX_E2E_*_TIMEOUT_SECONDS` variables exist
for shorter fault-injection bounds, not for removing timeouts.

## Continue after this phase

Deferred features remain recorded in
`docs/superpowers/specs/2026-08-19-gamebox-playable-loop-design.md`. Continue one
as a separate `brainstorming -> spec -> plan -> implementation` cycle using its
stable identifier:

- `继续 F2 公网部署` — Cloudflare Tunnel, boot startup, health monitoring, log
  rotation, and SQLite backup/restore.
- `继续 F3 迁移码` — one-time device migration, old-session invalidation, and
  administrator recovery codes.
- `继续 F4 对战记录` — history, statistics, filtering, and replay from the
  already-persisted event stream.
- `继续 F5 多游戏与跨端` — another game module plus iOS/desktop adapters and
  release paths.

The current design document is the architecture baseline for those follow-up
specifications; deferred work is not silently part of this playable-loop phase.
