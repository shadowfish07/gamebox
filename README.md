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

- Flutter 3.47.1 with its Dart 3.13 SDK
- Go 1.25
- Godot 4.7 (set `GODOT_BIN` when it is not installed as the macOS app)
- JDK 17 or newer
- Android SDK platform 36 and accepted Android licenses

The complete local E2E additionally requires `adb`, `emulator`, Bash, curl,
Git, jq, lsof, OpenSSL, ripgrep, Ruby, sed, `shasum`, and unzip. It requires the installed
`system-images;android-36;google_apis_playstore_ps16k;arm64-v8a` image. Check
the build/CI toolchain or the complete E2E toolchain without modifying it:

```bash
bash tool/bootstrap.sh --build-only
bash tool/bootstrap.sh
```

`bootstrap.sh` is deliberately non-destructive: it reports missing versions,
SDK components, or licenses and exits nonzero; it does not install or accept
anything. `--build-only` omits only the E2E-specific `adb` and emulator checks;
the no-argument form retains them.

## Development and submission workflow

完成开发并通过本地自测后，可以提交改动并直接 push。固定 Android E2E 只验证
协议、状态和生命周期逻辑，不要求截图；UI 视觉验收另行进行。

如果当前分支已关联 Pull Request，push 后等待 GitHub CI、Codex 和 CodeRabbit
自动 review 完成；只处理仍然有效的意见，修复后重新自测并 push。

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

For parallel linked-worktree development, use the repository lifecycle wrapper
instead of sharing this default port or database:

```bash
bash tool/worktree.sh setup
bash tool/worktree.sh status
bash tool/worktree.sh up       # foreground, isolated DB and stable port
bash tool/worktree.sh down
bash tool/worktree.sh e2e      # shared Android lease + two-AVD gate
```

Setup preserves existing local state, uses the committed Flutter lockfile, and
never copies the deployed service or Keychain. An explicit `data:pull` can copy
a consistent primary *development* snapshot into a linked worktree with a target
backup; reverse database synchronization is blocked because auth and gameplay
data share one SQLite file. See
[`docs/worktree-development.md`](docs/worktree-development.md) for state paths,
port/lease ownership, Orca hooks, exclusions, and recovery.

The Android debug client defaults to `http://10.0.2.2:8080`. Android emulators
map `10.0.2.2` to the host machine's loopback interface, whereas `127.0.0.1`
inside an emulator refers to that emulator. Override the client endpoint at
build time when required:

```bash
(cd app && flutter build apk --debug \
  --dart-define=GAMEBOX_API_BASE_URL=http://10.0.2.2:8080)
```

`GET /healthz` returns exactly `{"status":"ok"}`. The daemon emits JSON-line
operational logs to stderr. On the first `SIGINT` or `SIGTERM` it stops accepting
new HTTP work, allows a 10-second HTTP grace period, then stops workers,
WebSockets, and SQLite. Once graceful shutdown begins, normal signal handling
is restored, so a second termination signal force-stops a stuck process.

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
For both management commands, exit status 0 means success (including help), 1
means an operational failure, and 2 means invalid syntax; unknown flags and
extra positional arguments are rejected.

Keep invite output, JWT/pepper values, access and refresh tokens, launch and
resume tickets, databases, and private input outside logs, shell history,
commits, and shared artifacts. Server logs use request/connection/match IDs,
never credential plaintext.

## Android releases and in-app updates

The Android app checks the latest stable GitHub Release at startup, with a
six-hour local cache. The update button in the app bar can bypass that cache.
When a newer semantic version is available, Gamebox downloads the APK into its
private application-support directory, verifies its SHA-256 digest, then asks
Android's system package installer to install it. The native bridge also rejects
APKs with the wrong package name, a non-incrementing version code, or a different
signing certificate. Network or update failures do not block registration or
gameplay.

The reusable implementation lives in the independent
[`flutter_release_updater`](https://github.com/shadowfish07/flutter_release_updater)
repository and is pinned here through the `v0.1.2` Git tag. Other Android
Flutter applications can pin the same tag and provide their own update UI. The
plugin contributes
`REQUEST_INSTALL_PACKAGES` through manifest merging because Android requires
that special access for a normal application that installs its own downloaded
APK; it never requests the signature-only `INSTALL_PACKAGES` permission or
attempts silent installation. Store-hosted update APIs can avoid this access
only by moving download and installation ownership to the store.

The release workflow is `.github/workflows/release.yml`. Configure these
repository Actions secrets before the first release:

- `ANDROID_KEYSTORE_BASE64`: the release JKS encoded as one base64 string
- `ANDROID_STORE_PASSWORD`: the keystore password
- `ANDROID_KEY_ALIAS`: the signing key alias
- `ANDROID_KEY_PASSWORD`: the signing key password

Back up the keystore and passwords outside the repository. Every published APK
must use the same release key. Losing or replacing it prevents installed copies
from accepting future in-app updates.

Release builds use `https://gamebox.zqydev.me` as their API origin. Local debug
builds retain the emulator-friendly `http://10.0.2.2:8080` default unless
overridden with `GAMEBOX_API_BASE_URL`. CI-published debug builds use the
staging origin `https://staging-gamebox.zqydev.me` (see below).

For a stable release, update `app/pubspec.yaml` to the intended version, commit
and push it, then create and push the matching tag:

```bash
git tag v1.0.1
git push origin v1.0.1
```

The workflow checks that the tag and pubspec versions match, runs the complete
repository verification gate, builds signed APK and AAB files, verifies the APK
signature, generates `checksums.txt` for manual verification, and publishes all
three files to GitHub Releases. A manually dispatched run requires an
already-existing matching tag.
GitHub's `releases/latest` endpoint excludes drafts and prereleases, so only a
stable published release is offered automatically to normal installations.

## Debug artifact distribution

`.github/workflows/debug.yml` builds a debug APK on every push to `main` that
touches app or runtime sources, and on manual `workflow_dispatch`. It publishes
immutable SHA-named APK and checksum assets to the rolling pre-release tagged
`debug-latest`; the release notes identify the current pair, while previous
assets remain available if a later upload fails. The workflow uses the same
repository signing secrets as the stable release workflow, so an installed
debug build can accept the next rolling build without an uninstall.

The published debug build uses the independent application id
`me.zqydev.gamebox.debug` (enabled by the `GAMEBOX_DEBUG_ARTIFACT` environment
variable in `app/android/app/build.gradle.kts`), so it installs and runs
alongside a release install on the same device and is labeled `gamebox debug`.
It targets the staging server `https://staging-gamebox.zqydev.me` by default;
`workflow_dispatch` can override the API origin.

## macOS backend deployment

`deploy/macos/install.sh` builds and installs `gameboxd` and `gameboxctl` under
`~/.local/libexec/gamebox`, stores the JWT secret and token pepper in the login
Keychain, and keeps the SQLite database under
`~/Library/Application Support/Gamebox/server`. It installs LaunchAgents for
the server, five-minute local/public health checks, and daily verified SQLite
backups retained for 14 days.

```bash
zsh deploy/macos/install.sh
curl --fail --silent http://127.0.0.1:18080/healthz
```

The Cloudflare Tunnel public hostname `gamebox.zqydev.me` must route to
`http://127.0.0.1:18080`. The installer manages a dedicated Gamebox Tunnel
LaunchAgent so failures or configuration changes do not affect other hostnames.

### Staging server

`deploy/macos/install-staging.sh` installs a second, fully isolated server
instance on the same machine for staging use. It keeps an executable prefix
(`~/.local/libexec/gamebox-staging`) separate from production, shares the
production Cloudflare Tunnel, and keeps its own port (`127.0.0.1:18081`), SQLite
database, Keychain secrets, and launchd agents. It is published at
`https://staging-gamebox.zqydev.me`. Rerun it after pulling the latest `main` to
refresh staging with current server code:

```bash
git pull
zsh deploy/macos/install-staging.sh
curl --fail --silent http://127.0.0.1:18081/healthz
```

The tunnel ingress for the staging hostname lives in
`deploy/macos/cloudflared-config.yml` (shared with the production tunnel). It
requires the one-time DNS record `staging-gamebox.zqydev.me` pointing at the
tunnel, which `cloudflared tunnel route dns <tunnel-id>
staging-gamebox.zqydev.me` creates. Debug builds distributed through the
`debug-latest` release target this staging server.

## Verification

Run the fast source gate while iterating, or the unified CI-equivalent gate
before committing:

```bash
bash tool/verify_fast.sh
bash tool/verify.sh
```

`verify_fast.sh` runs Go, Flutter, and Godot tests, Flutter analysis, and the
Android smoke-log parser fixture. `verify.sh` first runs the non-destructive
build-only bootstrap check, then the fast gate, Kotlin unit tests, a Flutter
debug APK build, and APK assertions. The APK must contain a non-empty
`libgodot_android.so` for exactly `armeabi-v7a`, `arm64-v8a`, and `x86_64`.
It may contain generated Godot imports only as the exact safe
`assets/.godot/imported/*.ctex` shape; other `.godot` paths and Godot test/editor
cache paths are rejected. A component-local path classifier rejects suspicious
secret/token/credential/private-key and test names, while a separate content
scan rejects the two fixed server-only configuration identifiers
`GAMEBOX_JWT_SECRET` and `GAMEBOX_TOKEN_PEPPER`. This is not a claim that every
possible secret value can be recognized. Branch and pull-request CI runs
`bash tool/verify.sh` and does not install or start emulator tooling. Tag pushes
are excluded because the release workflow runs the source tests itself.

Before publishing, the release workflow builds and signs the APK and app bundle
once, stages the final assets and checksums, then starts an API 35 x86_64
emulator. `tool/smoke_android_release_apk.sh` installs the staged APK, signs a
release-targeting instrumentation helper with the same certificate, and starts
the packaged non-exported `GameActivity` twice with Godot's self-terminating
host-smoke arguments. On an ARM64 device, both runs must log
Godot's native-layer initialization and setup events,
`GAMEBOX_GODOT_MAIN_LOOP_STARTED`, `GAMEBOX_GODOT_READY`, then
`GAMEBOX_GODOT_EXITING` without a Java/native crash or ANR. GitHub's x86_64
emulator runs the same APK twice in explicitly renderer-limited mode: it must
reach both native-layer events without a crash or ANR, covering release signing,
installation, packaged native-library loading, JNI initialization, and Godot
native setup. It does not claim that SwiftShader started the main loop or
rendered the packaged scene. The checksum is
checked again immediately before those exact staged files are uploaded.
Manual workflow runs default to a non-publishing dry run against the current
default-branch commit; publishing an existing tag requires explicitly enabling
the `publish` input. Tag-triggered runs continue to publish automatically.

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
but not created, wiped, restarted, or stopped. Managed AVD A runs in light mode
at a 1080x2400 large-phone viewport and B in dark mode at a 720x1600 narrow-
phone viewport. Supplied devices keep their display overrides and must
naturally provide portrait viewports with A at least 1080 pixels wide and B at
most 720 pixels wide. The harness restores each selected device's original UI
mode and every managed display override on success and through its exit trap.

The semantics integration test always uses the selected A-device explicitly:

```bash
(cd app && flutter test -d emulator-5560 \
  integration_test/semantics_test.dart)
```

Replace `emulator-5560` with the selected Gamebox-owned serial. UI automation
selects stable resource IDs, not translated labels or content descriptions.
Match and revision progress require independent signals to agree: bounded
device ready/state logs plus the authoritative read-only `gameboxctl` snapshot.
The fixed E2E harness asserts protocol, state, and lifecycle logic; it does not
capture screenshots or make an E2E-only board model authoritative. Pending
logic pauses only the verified E2E-owned server PID before the move and resumes
it after the local pending marker is visible. Reconnect and failed states stop
and restart that same owned server with its temporary database, port, and test
secrets; the trap will not signal a PID that fails the ownership checks.

Artifacts are written under `artifacts/e2e/<UTC timestamp>/` only after
sanitization and secret scanning. They include serial/API level, commit and APK
provenance, logic assertions, sanitized server output, and the final read-only
match snapshot, but no screenshots, invites, or tokens. Each adb/UI operation
and build has a bounded watchdog; `GAMEBOX_E2E_*_TIMEOUT_SECONDS` variables
exist for shorter fault-injection bounds, not for removing timeouts. Visual UX
review, when required by the UI acceptance contract, is a separate target-
runtime activity and is not a fixed E2E artifact gate.

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
