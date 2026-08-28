# Gamebox

<!-- markdownlint-disable MD013 -->

> A server-authoritative Android game collection built with Flutter, Godot, and Go.

[![CI](https://github.com/shadowfish07/gamebox/actions/workflows/ci.yml/badge.svg)](https://github.com/shadowfish07/gamebox/actions/workflows/ci.yml)
[![Android](https://img.shields.io/badge/platform-Android-3DDC84?logo=android&logoColor=white)](https://github.com/shadowfish07/gamebox/releases)
[![Flutter 3.47.1](https://img.shields.io/badge/Flutter-3.47.1-02569B?logo=flutter&logoColor=white)](https://docs.flutter.dev/)
[![Godot 4.7](https://img.shields.io/badge/Godot-4.7-478CBF?logo=godot-engine&logoColor=white)](https://godotengine.org/)
[![Go 1.25](https://img.shields.io/badge/Go-1.25-00ADD8?logo=go&logoColor=white)](https://go.dev/)

Gamebox combines a Flutter app shell, embedded Godot games, and a Go service backed by SQLite. The server owns match rules and outcomes; clients render authoritative state and remain recoverable across disconnects and process restarts.

## Features

- **Two online games**: Gomoku and Rock Paper Scissors, each with a dedicated Godot interface
- **Server-authoritative matches**: moves, choices, revisions, results, and active game slots are validated by the Go service
- **Invite-only accounts**: one-time registration codes, automatic sign-in, and rotating access sessions
- **Resilient play**: reconnect, snapshot recovery, force-stop recovery, resignation, cancellation, and return-to-lobby flows
- **Match history**: paginated Gomoku results, win/loss/draw statistics, and win rate
- **Material 3 experience**: shared Flutter/Godot design tokens, light and dark themes, and responsive portrait layouts
- **Safe Android updates**: signed APK verification, checksum validation, and side-by-side debug builds backed by staging
- **Layered verification**: focused Flutter, Godot, Go, Android host, and deterministic two-device tests

## Architecture

```text
Flutter app shell
  registration · catalog · opponents · history · updates
            │
            ├─ Android bridge ─ Embedded Godot runtime
            │                   rendering · input · reconnect
            │
            └─ HTTP / WebSocket ─ Go service ─ SQLite
                                  auth · rules · events · outcomes
```

| Path | Responsibility |
| --- | --- |
| [`app/`](app/) | Flutter entry point, Android host, account and catalog UI, match launch, history, and updates |
| [`game_runtime/`](game_runtime/) | Embedded Godot runtime, game scenes, interaction, reconnect behavior, and authoritative state rendering |
| [`server/`](server/) | Go HTTP/WebSocket service, authentication, game rules, event persistence, and SQLite storage |
| [`protocol/`](protocol/) | Versioned wire contract and compatibility fixtures |
| [`design_system/`](design_system/) | Shared design-token source and generated Flutter/Godot outputs |
| [`tool/`](tool/) | Bootstrap, verification, worktree, Android smoke, E2E, and release tooling |

Flutter and Godot never decide whether a move or result is valid. Kotlin only bridges the Flutter host to the full-screen `GodotActivity` and passes a game ID, a one-time launch ticket, and non-secret configuration. The Go service persists accepted events before broadcasting them.

## Requirements

- Flutter 3.47.1 with Dart 3.13
- Go 1.25
- Godot 4.7 (`GODOT_BIN` can point to a non-standard installation)
- JDK 17 or newer
- Android SDK platform 36 with accepted licenses
- Bash and zsh

The complete local E2E additionally uses `adb`, Android Emulator, curl, Git, jq, lsof, OpenSSL, ripgrep, Ruby, sed, `shasum`, and unzip. Its managed devices require `system-images;android-36;google_apis_playstore_ps16k;arm64-v8a`.

Check the toolchain without installing packages or accepting licenses:

```bash
# Build and source-test requirements
bash tool/bootstrap.sh --build-only

# Full two-emulator E2E requirements
bash tool/bootstrap.sh
```

## Quick start

### 1. Start the server

The server requires independent JWT and token-pepper secrets of at least 32 bytes. Use an isolated SQLite directory for local development:

```bash
gamebox_data_dir="$(mktemp -d)"
export GAMEBOX_DB_PATH="$gamebox_data_dir/gamebox.db"
export GAMEBOX_JWT_SECRET="$(openssl rand -base64 32)"
export GAMEBOX_TOKEN_PEPPER="$(openssl rand -base64 32)"
export GAMEBOX_ADDR="127.0.0.1:8080"
(cd server && go run ./cmd/gameboxd)
```

Verify the service from another terminal:

```bash
curl --fail http://127.0.0.1:8080/healthz
```

The response is exactly `{"status":"ok"}`. The default address is `127.0.0.1:8080`; the default database path is `server/data/gamebox.db` when the daemon is started from the repository root.

### 2. Create registration invites

Use the same `GAMEBOX_TOKEN_PEPPER` value as the running service:

```bash
(cd server && go run ./cmd/gameboxctl invite create \
  --count 2 --db "$GAMEBOX_DB_PATH" --json)
```

Each plaintext invite is shown only once. A batch is atomic, and `--count` must be between 1 and 1000.

### 3. Build or run the Android app

Android emulators map `10.0.2.2` to the host loopback interface, so debug builds use `http://10.0.2.2:8080` by default:

```bash
cd app
flutter pub get
flutter run
```

Override the service endpoint when needed:

```bash
flutter run \
  --dart-define=GAMEBOX_API_BASE_URL=http://10.0.2.2:8080
```

You can also download a packaged build from [GitHub Releases](https://github.com/shadowfish07/gamebox/releases). Stable releases use `https://gamebox.zqydev.me`; rolling debug builds use the isolated `https://staging-gamebox.zqydev.me` service and install alongside the stable app.

## Development

For parallel linked worktrees, use the repository lifecycle wrapper so ports, databases, and shared Android devices remain isolated:

```bash
bash tool/worktree.sh setup
bash tool/worktree.sh status
bash tool/worktree.sh up       # foreground server with isolated DB and port
bash tool/worktree.sh down
bash tool/worktree.sh e2e      # shared Android lease + two-device gate
```

Setup preserves local state and never copies deployed secrets. Database write-back to the primary checkout is intentionally blocked because authentication and gameplay share one SQLite file. See [Worktree development](docs/worktree-development.md) for lifecycle hooks, state paths, port allocation, and recovery.

### Inspect a match

`gameboxctl` can replay an authoritative match without mutating the source database:

```bash
(cd server && go run ./cmd/gameboxctl match show \
  --id 11111111-1111-4111-8111-111111111111 \
  --db "$GAMEBOX_DB_PATH" --json)
```

For management commands, exit code `0` means success, `1` an operational failure, and `2` invalid syntax.

## Testing

Use the lowest layer that proves the changed boundary. The standard repository gates are:

```bash
# Go, Flutter, and Godot tests; Flutter analysis; smoke parser fixtures
bash tool/verify_fast.sh

# CI-equivalent gate, including Kotlin tests and debug APK assertions
bash tool/verify.sh
```

Successful output is compact. To stream passing subprocess output while debugging:

```bash
GAMEBOX_TEST_OUTPUT=verbose bash tool/verify.sh
```

The local two-device acceptance gate is reserved for network, protocol, multiplayer, lifecycle, or release-candidate boundaries:

```bash
bash tool/e2e_android.sh --self-test
bash tool/e2e_android.sh
```

The harness owns only its leased devices, restores display and theme settings, validates APK provenance, and writes sanitized diagnostics under `artifacts/e2e/`. It verifies logic and lifecycle rather than visual design. See the [testing strategy](docs/testing-strategy.md) for the evidence expected at each layer.

## Releases

Stable Android releases are built from semantic-version tags by [the release workflow](.github/workflows/release.yml). The workflow verifies source, builds signed APK and AAB artifacts, checks the APK signature, performs Android host smoke testing, generates checksums, and publishes the artifacts.

```bash
# Validate the next version without modifying Git state
bash tool/release.sh patch --dry-run

# Increment, commit, push, and trigger a release
bash tool/release.sh patch  # or minor / major
```

Release builds require these GitHub Actions secrets:

- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_STORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

The [debug workflow](.github/workflows/debug.yml) publishes branch builds to the rolling `debug-latest` prerelease. Stable and debug packages have different application IDs, so both can be installed on one device.

## Deployment

The supported backend deployment target is macOS. The installer places binaries under `~/.local/libexec/gamebox`, stores secrets in the login Keychain, keeps data under `~/Library/Application Support/Gamebox/server`, and installs launch agents for the service, health checks, Cloudflare Tunnel, and daily verified backups.

```bash
zsh deploy/macos/install.sh
curl --fail http://127.0.0.1:18080/healthz
```

An isolated staging installation is available through `deploy/macos/install-staging.sh`. It uses its own binaries, port, database, secrets, and launch agents while sharing the production tunnel configuration.

## Security

Never commit or share invite plaintext, JWT or pepper values, access or refresh tokens, launch or resume tickets, SQLite databases, or private runtime input. Server logs identify requests, connections, and matches without credential plaintext.

If you discover a security issue, report it privately to the repository owner instead of opening a public issue.

## Contributing

Issues and pull requests are welcome. Before submitting a change:

1. Keep the change focused and add tests at the lowest relevant layer.
2. Run `bash tool/verify.sh`.
3. For user-facing UI changes, run the actual target interface and inspect the affected states in both relevant themes and viewports.
4. Do not include generated runtime state, credentials, E2E artifacts, or screenshots containing user-specific data.

## Project status

Gamebox is under active development and currently targets Android. AI opponents, local multiplayer, matchmaking, friends, chat, spectating, push notifications, iOS, and desktop clients are not currently implemented.

## License

No open-source license has been published yet. The source is publicly available, but copyright law applies until the repository includes an explicit license.
