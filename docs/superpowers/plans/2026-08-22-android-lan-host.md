# Gamebox Android LAN Host Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让两台面对面的 Android 手机在没有公网和邀请码时，通过同一 Wi-Fi 或房主热点完成五子棋开房、扫码加入、断线与房主服务崩溃恢复，并把公网和局域网终局统一保存为本地战绩。

**Architecture:** Flutter 持有唯一的本地昵称、房间 UI、LAN 客户端和本地战绩；Android 主进程中的 `LanHostService` 以前台服务方式托管经 gomobile 绑定的纯 Go 单房间权威引擎；房主和客人的 Godot `:game` 进程都继续作为现有 WebSocket 协议客户端。Go journal 是房主持久化真相，Kotlin Keystore 只保护可恢复密钥，公共账号/令牌与 LAN 身份/令牌彻底隔离。

**Tech Stack:** Go 1.25, `golang.org/x/mobile` gomobile AAR, `coder/websocket`, Kotlin/JVM 17, Android SDK 36/minSdk 24, Flutter 3.47.1/Dart 3.13, `mobile_scanner 7.4.0`, `qr_flutter 4.1.0`, `flutter_secure_storage`, Godot 4.7, Bash/ADB two-emulator E2E.

**Spec:** `docs/superpowers/specs/2026-08-22-android-lan-host-design.md`

## Global Constraints

- Keep the existing public `ApiClient`, refresh-token storage, matchmaking service and public WSS path separate from every LAN client, credential and endpoint.
- Do not import `modernc.org/sqlite`, `internal/auth`, `internal/users`, or `internal/matches` from the gomobile-bound package. Reuse only the mobile-safe `internal/games`, `internal/games/gomoku`, `internal/protocol`, standard library, and `coder/websocket` boundaries.
- Preserve the existing wire envelope at protocol version 1. Add only explicit message/payload types with shared Go/Godot fixtures; do not silently reinterpret an existing payload.
- Commit journal records before mutating published in-memory state or broadcasting. Never repair a journal gap, hash mismatch, duplicate action conflict, or rules-replay mismatch automatically.
- Treat navigation, backgrounding, transport loss and Godot process exit as non-terminal. Only revision-0 cancel or an explicit confirmed resignation/abandon action may close an active LAN room.
- Persist `PendingGameResult` before launching Godot. Persist and fsync the authoritative result before LAN `result.persisted` acknowledgement or clearing pending state.
- Keep `GameResult.source` internal. The history UI mixes `public` and `lan` and exposes no source label or filter; LAN results have no upload path.
- Current target SDK is 36: do not declare or request `ACCESS_LOCAL_NETWORK` yet. Keep a version-gated platform abstraction and a manifest test that requires it when the project moves to target 37. Official Android guidance says SDK 36 and lower receive LAN access through `INTERNET`.
- Build the gomobile AAR for exactly `android/arm`, `android/arm64`, and `android/amd64`, matching APK ABIs `armeabi-v7a`, `arm64-v8a`, and `x86_64`. The APK gate must find one non-empty `libgojni.so` and one non-empty `libgodot_android.so` in each ABI.
- Never log, screenshot, or save in E2E artifacts any QR payload, room key, launch ticket, candidate token, resume token, public access token, or public refresh token.
- Follow `AGENTS.md`: every user-facing UI change must be exercised in a built Android app and captured in credential-free screenshots. Mock/widget evidence is supplementary, not runtime acceptance.
- After each task, run the focused test first. At each milestone, run `bash tool/verify.sh`. Before completion also run the existing `bash tool/e2e_android.sh`, the new LAN E2E, and the real two-phone hotspot checklist.

## Milestone 1: Retire the highest-risk mobile-hosting unknowns

Milestone 1 comprises Tasks 1–5. It is complete only when a real Android build contains both native runtimes, `LanHostService` listens from a phone, a second client completes a minimal WebSocket handshake, and a committed journal event survives service/process restart. Keep this slice intentionally UI-free; if the AAR, ABI packaging, foreground-service policy, or filesystem durability cannot meet the assertions, stop and revise the design before building product screens.

### Task 1: Pin gomobile and make the AAR/APK build spine executable

**Files:**

- Modify: `server/go.mod`
- Modify: `server/go.sum`
- Create: `server/mobile/lanengine/engine.go`
- Create: `server/mobile/lanengine/engine_test.go`
- Create: `tool/build_lan_aar.sh`
- Modify: `tool/bootstrap.sh`
- Modify: `app/android/app/build.gradle.kts`
- Modify: `tool/verify.sh`

- [ ] **Step 1: Write a failing mobile-boundary test**

Add `server/mobile/lanengine/engine_test.go` with a compile-time surface test and a dependency-closure test:

```go
func TestEngineRejectsBlankRoot(t *testing.T) {
    if _, err := NewEngine(""); !errors.Is(err, ErrInvalidConfiguration) {
        t.Fatalf("NewEngine blank root error = %v", err)
    }
}

func TestBoundPackageHasNoForbiddenImports(t *testing.T) {
    forbidden := []string{"modernc.org/sqlite", "/internal/auth", "/internal/users", "/internal/matches"}
    output := goListDeps(t, "me.zqydev/gamebox/server/mobile/lanengine")
    for _, fragment := range forbidden {
        if strings.Contains(output, fragment) {
            t.Fatalf("mobile dependency closure contains %q", fragment)
        }
    }
}
```

Run: `cd server && go test ./mobile/lanengine`

Expected: FAIL because `NewEngine` and the package do not exist.

- [ ] **Step 2: Add the smallest bindable API**

Create a gomobile-compatible exported surface using only strings, integers, booleans and errors:

```go
var ErrInvalidConfiguration = errors.New("invalid configuration")

type Engine struct {
    root string
}

func NewEngine(root string) (*Engine, error)
func (engine *Engine) Start(roomSecretsJSON string) (string, error)
func (engine *Engine) CreateRoom(createJSON string) (string, error)
func (engine *Engine) IssueHostLaunch() (string, error)
func (engine *Engine) Status() string
func (engine *Engine) Stop() error
```

At this task, every method except `NewEngine` and `Status` returns a stable `not_ready` error. `Status` returns strict JSON `{"schemaVersion":1,"state":"empty"}`. Do not introduce fake networking.

- [ ] **Step 3: Pin the Go 1.25-compatible mobile toolchain**

Add `golang.org/x/mobile v0.0.0-20260821151724-5c0595f4cdbb` to `server/go.mod` and record both tool commands with Go 1.25 tool directives:

```go
tool (
    golang.org/x/mobile/cmd/gobind
    golang.org/x/mobile/cmd/gomobile
)
```

This commit is the last upstream revision before the module raised its Go directive to 1.26. Do not replace it with `@latest` while the repository gate requires Go 1.25.

- [ ] **Step 4: Add a deterministic AAR builder**

Create `tool/build_lan_aar.sh` with one output argument and these invariants:

```bash
usage: tool/build_lan_aar.sh OUTPUT_AAR
```

It must:

1. resolve the repository root without changing caller state;
2. reject output paths outside the ignored repository build root `app/build/`;
3. run from `server/`;
4. use `go tool gomobile bind -target=android/arm,android/arm64,android/amd64 -androidapi=24 -trimpath -o "$output" ./mobile/lanengine`;
5. write to a temporary sibling and rename only after a successful build;
6. inspect the AAR and require `classes.jar` plus exactly the three expected `jni/<abi>/libgojni.so` entries.

Add `gomobile`/`gobind` availability and the installed Android NDK to `tool/bootstrap.sh`. Extend its `--self-test` fixture so build-only mode checks the pinned tool path without needing ADB/emulator.

- [ ] **Step 5: Wire Gradle to the generated AAR**

Add a cacheable `BuildLanAar` task whose output is `app/build/app/generated/gameboxLan/gamebox-lan.aar` (the current Gradle `:app` build directory); make `preBuild` depend on it and add that exact file as an `implementation(files(...))` dependency. Preserve `selectedGameboxAbi` filtering so the AAR follows the existing per-ABI debug build path.

- [ ] **Step 6: Extend the native archive gate**

Refactor `validate_apk_native_runtime` so every supported ABI requires both:

```text
lib/<abi>/libgodot_android.so
lib/<abi>/libgojni.so
```

Update the good/bad self-test listings to catch a missing Go JNI library, an empty Go JNI library, an extra ABI, and duplicate entries.

- [ ] **Step 7: Run the focused build checks**

Run:

```bash
cd server && go test ./mobile/lanengine
bash tool/bootstrap.sh --self-test
bash tool/verify.sh --self-test
bash tool/build_lan_aar.sh app/build/manual/gamebox-lan.aar
unzip -Z1 app/build/manual/gamebox-lan.aar | LC_ALL=C sort
```

Expected: all tests pass; the listing contains `classes.jar` and only `armeabi-v7a`, `arm64-v8a`, `x86_64` JNI variants.

- [ ] **Step 8: Commit the build spine**

```bash
git add server/go.mod server/go.sum server/mobile/lanengine tool/build_lan_aar.sh tool/bootstrap.sh app/android/app/build.gradle.kts tool/verify.sh
git commit -m "build: add Android LAN engine AAR"
```

### Task 2: Implement the crash-safe append-only room journal

**Files:**

- Create: `server/internal/lan/journal/record.go`
- Create: `server/internal/lan/journal/store.go`
- Create: `server/internal/lan/journal/store_test.go`
- Create: `server/internal/lan/journal/fault_test.go`
- Create: `server/internal/lan/journal/testdata/corrupt_hash/0000000000000001.json`
- Create: `server/internal/lan/journal/testdata/sequence_gap/0000000000000001.json`
- Create: `server/internal/lan/journal/testdata/sequence_gap/0000000000000003.json`

- [ ] **Step 1: Specify the record and durable-store contracts in tests**

Define the canonical record shape in tests before implementation:

```go
type Record struct {
    SchemaVersion   int             `json:"schemaVersion"`
    JournalSequence int64           `json:"journalSequence"`
    GameRevision    *int64          `json:"gameRevision"`
    Type            string          `json:"type"`
    ActionID        *string         `json:"actionId"`
    Payload         json.RawMessage `json:"payload"`
    PreviousHash    string          `json:"previousHash"`
    Hash            string          `json:"hash"`
}
```

Tests must cover: first append, consecutive append, canonical encoding, temp-file cleanup, file fsync before rename, directory sync after rename, append failure leaving sequence unchanged, manifest lag, gap, reorder, duplicate filename, invalid JSON, unknown field, wrong previous hash, wrong current hash, and context cancellation before commit.

Use injected `FileOps` hooks in `fault_test.go` to fail each boundary deterministically rather than killing the test process.

Run: `cd server && go test ./internal/lan/journal`

Expected: FAIL because the journal package does not exist.

- [ ] **Step 2: Implement canonical hashing and strict decoding**

Use SHA-256 over canonical JSON containing every field except `hash`. Require schema version 1, a positive sequence, a canonical lower-case hex hash, exact keys, UTF-8, bounded payload size and no trailing JSON document. `gameRevision` is present only for game events.

Expose:

```go
type FileOps interface {
    WriteFileSync(path string, data []byte, mode fs.FileMode) error
    Rename(oldPath, newPath string) error
    SyncDir(path string) error
}

func Open(root string, ops FileOps) (*Store, []Record, error)
func (store *Store) Append(ctx context.Context, draft Draft) (Record, error)
func (store *Store) Records() []Record
```

Production `WriteFileSync` must open with `O_CREATE|O_EXCL|O_WRONLY`, write all bytes, call `Sync`, close, then rename. After rename, call directory `Sync`. A failed directory sync returns an error and forces callers to reopen/replay before accepting another action because the rename may already be durable.

- [ ] **Step 3: Implement recovery and manifest projection**

`Open` deletes only recognized `*.tmp` files, then loads zero-padded sequence filenames in lexical order. It rejects any non-contiguous or unverifiable committed record. Add `WriteManifestProjection(roomID, gameID, endpoint string, formatVersion int)` as a non-authoritative atomic projection; recovery may rewrite a missing/stale manifest from valid journal records.

- [ ] **Step 4: Run durability tests**

Run:

```bash
cd server && go test ./internal/lan/journal -run 'Test(Append|Open|Manifest|Fault)' -count=20
cd server && go test -race ./internal/lan/journal
```

Expected: PASS with no race. The fault suite proves no in-memory sequence advances before a committed record is replayable.

- [ ] **Step 5: Commit the journal**

```bash
git add server/internal/lan/journal
git commit -m "feat: add durable LAN room journal"
```

### Task 3: Build the single-room authoritative state machine and recovery replay

**Files:**

- Create: `server/internal/lan/room/models.go`
- Create: `server/internal/lan/room/service.go`
- Create: `server/internal/lan/room/recovery.go`
- Create: `server/internal/lan/room/service_test.go`
- Create: `server/internal/lan/room/recovery_test.go`
- Create: `server/internal/nickname/rules.go`
- Create: `server/internal/nickname/rules_test.go`
- Create: `protocol/fixtures/nickname_cases.json`
- Modify: `server/internal/users/service.go`
- Modify: `server/internal/users/service_test.go`
- Modify: `server/mobile/lanengine/engine.go`
- Modify: `server/mobile/lanengine/engine_test.go`
- Modify: `server/internal/games/gomoku/rules.go`
- Modify: `server/internal/games/gomoku/rules_test.go`

- [ ] **Step 1: Write state-machine tests around externally observable behavior**

Cover these commands and invariants:

```go
type CreateRequest struct {
    RoomID          string
    HostPlayerID    string
    HostNickname    string
    RoomKey         string
    TokenPepper     string
    HostResumeToken string
    JoinExpiresAt   int64
}

type JoinRequest struct {
    RoomID               string
    Nickname             string
    JoinAttemptID        string
    CandidateResumeToken string
    RoomKey              string
}

func (service *Service) Create(ctx context.Context, request CreateRequest) (CreatedRoom, error)
func (service *Service) Join(ctx context.Context, request JoinRequest) (JoinedPlayer, error)
func (service *Service) IssueLaunch(ctx context.Context, playerID, resumeToken string) (LaunchTicket, error)
func (service *Service) Connect(ctx context.Context, credential ConnectCredential) (ConnectionCredential, error)
func (service *Service) Apply(ctx context.Context, request ActionRequest) (Event, Snapshot, *GameResult, error)
func (service *Service) Cancel(ctx context.Context, playerID string) (Event, error)
func (service *Service) AcknowledgeResult(ctx context.Context, playerID, resultHash string) error
func (service *Service) Snapshot() Snapshot
```

Test host/guest identities, two seats, random color allocation, room lock, third-player rejection, one-time launch-ticket consumption, resume-token binding, revision checks, move/resign actions, revision-0 cancel, revision>0 abandon-as-resignation, idempotent action replay, same action ID/different payload conflict, and terminal result acknowledgements.

Run: `cd server && go test ./internal/lan/room`

Expected: FAIL because the room package does not exist.

- [ ] **Step 2: Extract one mobile-safe nickname implementation**

Move `NormalizeNickname` and all Unicode helpers from `internal/users` into `internal/nickname`; keep `users.NormalizeNickname` as a compatibility wrapper so public auth callers do not change semantics. Put exact input/display/valid fixture cases in `protocol/fixtures/nickname_cases.json`, including Unicode whitespace, 2–16 rune limits, controls, separators, ordinary spaces, emoji ZWJ, text ZWNJ, forbidden formatting and invisible-only names. Both public users tests and LAN room tests load this fixture. Export the same normalization through `mobile/lanengine.NormalizeNickname` later; do not duplicate Unicode category logic in Kotlin or Dart.

- [ ] **Step 3: Make Gomoku initial seating explicit without duplicating rules**

Add a mobile-safe optional setup API to the Gomoku package:

```go
func NewSnapshot(blackUserID, whiteUserID string) (gameapi.Snapshot, error)
```

Keep `Rules.Apply` and `Rules.Rebuild` as the sole move implementation. Extend rule tests to prove the seeded snapshot is revision 0, black moves first, both IDs are canonical UUIDs, and replay yields byte-equivalent state.

- [ ] **Step 4: Implement room commands as journal transactions**

For every command:

1. validate against an immutable current projection;
2. derive one or more `journal.Draft` records;
3. append all required records under the room mutex;
4. rebuild/advance the projection only from committed records;
5. return a clone safe for transport.

Use journal types `room.created`, `player.joined`, `credential.issued`, `credential.consumed`, `game.event`, `room.cancelled`, `room.finished`, and `result.persisted`. Store only HMAC/SHA-256 credential digests. Never persist room keys, token pepper, launch tickets, or resume tokens in plaintext.

- [ ] **Step 5: Make join response-loss idempotent**

On first accepted join, commit the guest ID, seat, nickname, `joinAttemptId`, and candidate token digest before returning. On retry, accept only the exact attempt ID plus matching candidate token, issue a fresh launch ticket, and return the original player ID. Any different attempt after `player.joined` is committed returns `room_locked` even if the initial QR has not expired yet.

- [ ] **Step 6: Implement strict replay**

Recovery must validate room identity, journal sequence, game revision, unique action IDs, action payload fingerprints, credential lifecycle, result acknowledgements, and Gomoku rule replay. Manifest lag is recoverable; journal corruption is `ErrRecoveryCorrupt` and leaves every source file untouched.

- [ ] **Step 7: Exercise crash boundaries**

Add table tests whose injected journal append fails:

- before the record is renamed;
- after rename but before directory sync;
- after commit but before the caller receives the event;
- after terminal commit but before any result ack.

Reopen the room and retry the same action/join attempt. Assert no duplicate move, player, identity, terminal result, or acknowledgement.

- [ ] **Step 8: Run room, nickname and rule tests**

Run:

```bash
cd server && go test ./internal/nickname ./internal/users ./internal/games/gomoku ./internal/lan/room -count=10
cd server && go test -race ./internal/lan/room
```

Expected: PASS, including the response-loss and every crash-boundary replay case.

- [ ] **Step 9: Commit the room engine**

```bash
git add protocol/fixtures/nickname_cases.json server/internal/nickname server/internal/users server/internal/games/gomoku server/internal/lan/room server/mobile/lanengine
git commit -m "feat: add authoritative LAN room engine"
```

### Task 4: Expose the LAN join, resume, result and WebSocket boundaries

**Files:**

- Create: `server/internal/lan/httpapi/router.go`
- Create: `server/internal/lan/httpapi/handlers.go`
- Create: `server/internal/lan/httpapi/hub.go`
- Create: `server/internal/lan/httpapi/router_test.go`
- Create: `server/internal/lan/httpapi/e2e_test.go`
- Modify: `server/mobile/lanengine/engine.go`
- Modify: `server/mobile/lanengine/engine_test.go`
- Modify: `server/internal/protocol/messages.go`
- Modify: `server/internal/protocol/messages_test.go`
- Create: `protocol/fixtures/lan_connected.json`

- [ ] **Step 1: Write failing HTTP and WebSocket contract tests**

Specify exact LAN routes:

```text
POST /lan/v1/rooms/{roomId}/join
POST /lan/v1/rooms/{roomId}/resume-ticket
GET  /lan/v1/rooms/{roomId}/result
POST /lan/v1/rooms/{roomId}/result-ack
GET  /lan/v1/ws
```

Every JSON body has exact fields, a 64 KiB cap, bounded depth, no redirects and stable error codes. Secrets travel only in JSON bodies or the first WebSocket data message, never URLs, headers, log fields or response diagnostics. Test room-ID mismatch, expired initial join, response-loss retry, locked room, invalid resume token, active-result request, duplicate result ack and unknown methods.

Run: `cd server && go test ./internal/lan/httpapi`

Expected: FAIL because the router does not exist.

- [ ] **Step 2: Reuse the existing protocol envelope and client actions**

Add only the LAN-safe handshake metadata needed after `platform.connect`; keep `gomoku.move.requested`, `gomoku.move.accepted`, `gomoku.resign.requested`, `gomoku.resigned`, snapshots, ping/pong and errors byte-compatible. Extend shared fixtures rather than forking a second protocol decoder.

- [ ] **Step 3: Implement a single-room hub**

Adapt the existing bounded-send-queue, heartbeat and snapshot-resync behavior to depend on a narrow room interface rather than SQLite `matches.Service`. Both host and guest consume one-time launch tickets and receive per-player resume tokens. A reconnect sends `platform.connected`, an authoritative snapshot, and—if terminal—the canonical result projection.

- [ ] **Step 4: Finish the gomobile engine facade**

`Engine.Start(roomSecretsJSON)` opens/replays `active_room`, binds `0.0.0.0` on the persisted port when possible and falls back to a random high port when necessary. Return strict status JSON:

```json
{
  "schemaVersion": 1,
  "state": "waiting|active|finished|cancelled|corrupt",
  "roomId": "uuid",
  "port": 49152,
  "gameRevision": 0,
  "endpointChanged": false
}
```

`CreateRoom` accepts the pre-persisted room ID, host player ID, normalized nickname, base64url room key/token pepper/host resume token and initial-join expiry from Kotlin, commits `room.created`, then listens. It reserves the selected high port first but does not serve requests until the journal commit succeeds. `IssueHostLaunch` returns `matchId`, `gameId`, `launchTicket`, `wsUrl=ws://127.0.0.1:<port>/lan/v1/ws`, and expiry as JSON. `Stop` stops listeners without deleting the active journal.

- [ ] **Step 5: Run real socket integration tests**

Use `httptest` only for handler contract tests. Add one test with a real `net.Listen("tcp4", "127.0.0.1:0")`, a real coder/websocket client, a committed move, engine stop, engine reopen, resume connection, and snapshot equality.

Run:

```bash
cd server && go test ./internal/protocol ./internal/lan/httpapi ./mobile/lanengine -count=10
cd server && go test -race ./internal/lan/httpapi ./mobile/lanengine
bash tool/build_lan_aar.sh app/build/manual/gamebox-lan.aar
```

Expected: PASS; the restart test sees the same room ID and game revision.

- [ ] **Step 6: Commit LAN transport**

```bash
git add server/internal/lan/httpapi server/mobile/lanengine server/internal/protocol protocol/fixtures/lan_connected.json
git commit -m "feat: expose LAN room transport"
```

### Task 5: Host the Go engine in a recoverable Android foreground service

**Files:**

- Modify: `app/android/app/src/main/AndroidManifest.xml`
- Create: `app/android/app/src/main/kotlin/me/zqydev/gamebox/LanHostService.kt`
- Create: `app/android/app/src/main/kotlin/me/zqydev/gamebox/LanHostEngine.kt`
- Create: `app/android/app/src/main/kotlin/me/zqydev/gamebox/LanSecretStore.kt`
- Create: `app/android/app/src/main/kotlin/me/zqydev/gamebox/LanHostChannel.kt`
- Create: `app/android/app/src/main/kotlin/me/zqydev/gamebox/LanNetworkAddress.kt`
- Modify: `app/android/app/src/main/kotlin/me/zqydev/gamebox/MainActivity.kt`
- Create: `app/android/app/src/test/kotlin/me/zqydev/gamebox/LanHostEngineTest.kt`
- Create: `app/android/app/src/test/kotlin/me/zqydev/gamebox/LanSecretStoreTest.kt`
- Create: `app/android/app/src/test/kotlin/me/zqydev/gamebox/LanNetworkAddressTest.kt`
- Create: `app/android/app/src/androidTest/kotlin/me/zqydev/gamebox/LanHostServiceTest.kt`
- Create: `app/android/app/src/androidTest/kotlin/me/zqydev/gamebox/LanHostAarSmokeTest.kt`
- Create: `server/cmd/lan-smoke/main.go`
- Create: `server/cmd/lan-smoke/main_test.go`
- Modify: `app/test/android_manifest_test.dart`

- [ ] **Step 1: Write failing manifest and Kotlin contract tests**

Require:

```xml
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE" />
<uses-permission android:name="android.permission.CHANGE_NETWORK_STATE" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
<uses-permission android:name="android.permission.CAMERA" />
<uses-feature android:name="android.hardware.camera.any" android:required="false" />
<service android:name=".LanHostService"
         android:exported="false"
         android:foregroundServiceType="connectedDevice" />
```

At target SDK 36, assert `ACCESS_LOCAL_NETWORK` is absent. Add a test helper taking `targetSdk` that flips the expectation to declared/runtime-requested at 37.

Test the platform API surface:

```kotlin
interface LanHostEngine {
    fun createRoom(requestJson: String): String
    fun restore(secretsJson: String): String
    fun issueHostLaunch(): String
    fun status(): String
    fun stop()
}
```

Run:

```bash
cd app && flutter test test/android_manifest_test.dart
cd app/android && ./gradlew :app:testDebugUnitTest
```

Expected: FAIL because the service and permissions are absent.

- [ ] **Step 2: Implement Keystore-protected room secrets**

Use Android Keystore AES/GCM with a non-exportable key alias `gamebox_lan_room_v1`. Store one versioned encrypted blob below `noBackupFilesDir/lan_host/room-secrets.bin`, containing room ID, room key, token pepper, host player ID and host resume token. Use `SecureRandom`; never accept caller-provided entropy in production. Kotlin generates the room/player IDs and all secret material, atomically persists this encrypted bundle first, then calls Go `CreateRoom` with the same values so `room.created` can commit without a secret-loss crash window. If Go rejects creation before committing `room.created`, delete only that newly generated unused bundle. Unit tests use an injected cipher/key provider and assert redacted `toString()` output.

- [ ] **Step 3: Implement private-IPv4 endpoint selection**

Enumerate active, non-loopback network interfaces and accept only site-local IPv4 in `10/8`, `172.16/12`, or `192.168/16`. Reject cellular/public, loopback, link-local, IPv6 and absent addresses. Keep endpoint selection separate from listener binding so `0.0.0.0:<port>` can continue while QR generation reports “connect Wi-Fi or hotspot.”

- [ ] **Step 4: Implement the foreground service lifecycle**

From a visible `MainActivity`, call `ContextCompat.startForegroundService`. In `onCreate`/`onStartCommand`, create a low-priority persistent notification and call `ServiceCompat.startForeground` with `FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE` before opening/recovering the engine. Return `START_STICKY`. `onDestroy` stops the in-process listener but does not delete journal/secrets. Explicit terminal cleanup and confirmed abandon call `stopForeground(STOP_FOREGROUND_REMOVE)`, delete only the resolved LAN active-room files, and `stopSelf()`.

- [ ] **Step 5: Add one strict MethodChannel**

Register `me.zqydev.gamebox/lan_host` through `LanHostChannel`. Exact methods:

```text
getStatus(arguments: null)
createRoom({nickname})
issueHostLaunch(arguments: null)
refreshEndpoint(arguments: null)
closeRoom({mode: cancel|resign|discard_corrupt})
stopCompletedRoom({allowMissingGuestAck: bool})
```

Return strict versioned JSON-compatible maps; reject extra/missing keys and blank nickname. Do not reuse `game_launcher` or `app_updater` channels.

- [ ] **Step 6: Run an Android vertical smoke on one device**

The instrumentation test must launch the real service/AAR, create a room, connect a real local WebSocket client to loopback, commit one legal move, stop the service, restart it, and assert the same room ID/revision/board. Also assert the foreground notification is present while active and removed only after explicit cleanup.

Run:

```bash
cd app/android && ./gradlew :app:testDebugUnitTest :app:assembleDebug :app:assembleDebugAndroidTest
adb install -r app/build/app/outputs/apk/debug/app-debug.apk
adb install -r app/build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk
adb shell am instrument -w -e class me.zqydev.gamebox.LanHostAarSmokeTest me.zqydev.gamebox.test/me.zqydev.gamebox.HostSmokeTestRunner
```

Expected: `OK (1 test)` and log markers containing only room ID/revision/state, never credentials.

- [ ] **Step 7: Verify a second client handshake without exposing its credential**

After the Step 6 room is explicitly cleaned up, create a fresh room for this check. Create `server/cmd/lan-smoke` as a bounded client that reads exactly one join JSON document from stdin, accepts only an endpoint override on the command line, joins, consumes its launch ticket in the first WebSocket message, verifies the revision-0 authoritative snapshot and prints only room ID/revision/state. Unit tests must prove it never formats its stdin or credential fields.

The instrumentation setup writes the one-use handoff to `filesDir/lan-test/handoff.json` without logging it. With service running on emulator/device A, resolve the port from redacted status, use `adb forward tcp:0 tcp:<devicePort>`, and pipe the private file directly into the smoke client without storing or printing it:

```bash
adb exec-out run-as me.zqydev.gamebox cat files/lan-test/handoff.json \
  | (cd server && go run ./cmd/lan-smoke --endpoint 127.0.0.1:<forwardedPort>)
```

Run a cleanup instrumentation method immediately afterward and assert the handoff file is gone. The external client must have received `platform.connected` plus the revision-0 snapshot through the real forwarded Android listener; Step 6 separately proves a committed event survives service restart.

- [ ] **Step 8: Run Milestone 1 gate and commit**

Run:

```bash
bash tool/verify.sh
git diff --check
```

Expected: PASS. Record the device model/API, APK SHA-256, room ID and recovered revision in `artifacts/lan-host-spike/summary.json`; keep the ignored artifact credential-free.

```bash
git add app/android app/test/android_manifest_test.dart server/cmd/lan-smoke
git commit -m "feat: host LAN engine in Android service"
```

## Milestone 2: Make local identity independent of public registration

### Task 6: Add the single local nickname and upgrade migration

**Files:**

- Create: `app/lib/core/profile/nickname_rules.dart`
- Create: `app/lib/core/profile/app_profile.dart`
- Create: `app/lib/core/profile/app_profile_store.dart`
- Create: `app/lib/features/profile/profile_controller.dart`
- Create: `app/lib/features/profile/nickname_page.dart`
- Modify: `app/lib/app.dart`
- Modify: `app/lib/features/auth/registration_page.dart`
- Modify: `app/lib/features/auth/session_controller.dart`
- Create: `app/android/app/src/main/kotlin/me/zqydev/gamebox/AppProfileChannel.kt`
- Modify: `app/android/app/src/main/kotlin/me/zqydev/gamebox/MainActivity.kt`
- Create: `app/android/app/src/androidTest/kotlin/me/zqydev/gamebox/NicknameRulesAarTest.kt`
- Create: `app/test/core/profile/nickname_rules_test.dart`
- Create: `app/test/core/profile/app_profile_store_test.dart`
- Create: `app/test/features/profile/profile_controller_test.dart`
- Create: `app/test/features/profile/nickname_page_test.dart`
- Modify: `app/test/app_test.dart`
- Modify: `app/test/features/auth/registration_page_test.dart`
- Modify: `app/test/features/auth/session_controller_test.dart`

- [ ] **Step 1: Reuse the shared nickname fixtures through the AAR**

Expose `mobile/lanengine.NormalizeNickname(raw)` from the mobile-safe Go package created in Task 3. Add MethodChannel `me.zqydev.gamebox/app_profile` with exact method `normalizeNickname({nickname})`, returning `{nickname: normalizedDisplay}` or stable `invalid_nickname`. `NicknameRules` is an async Dart interface backed by this channel; widget/controller tests inject a fixture implementation. Run `NicknameRulesAarTest` against every case in `protocol/fixtures/nickname_cases.json` so Android local validation, LAN joins and the public service use the same Go implementation. Keep the public server as uniqueness authority.

- [ ] **Step 2: Write failing profile-store and boot-flow tests**

Specify:

```dart
final class AppProfile {
  const AppProfile({required this.schemaVersion, required this.nickname,
    required this.syncState, this.lastSyncedNickname, this.blockingSyncCode});
}

abstract interface class AppProfileStore {
  Future<AppProfile?> read();
  Future<void> write(AppProfile profile);
}
```

Test first launch, atomic write failure, corrupt profile, offline old-version upgrade, successful public-session migration, user-entered local name winning over later restored public name, and no nickname field on registration.

Run: `cd app && flutter test test/core/profile test/features/profile test/app_test.dart test/features/auth`

Expected: FAIL because profile classes/pages do not exist.

- [ ] **Step 3: Implement atomic local profile storage**

Use `path_provider` and a versioned strict JSON file under app support, not `SharedPreferences`, so profile and sync state change atomically. Write temp → flush → rename. Keep public tokens out of this file. Quarantine unreadable bytes by returning a safe `ProfileLoadFailure`; never silently substitute a public nickname over a corrupt local profile.

- [ ] **Step 4: Put the profile gate before authentication**

`GameboxApp` loads the local profile and public session independently. Navigation becomes:

```text
profile loading -> local nickname setup (when absent) -> home shell
                                                   ├─ public unavailable/registration
                                                   └─ LAN always available
```

An unauthenticated or temporarily unrestorable public session no longer replaces the whole app with `RegistrationPage`. Public matchmaking owns its own signed-out/error state inside home.

- [ ] **Step 5: Remove nickname entry from registration**

Change `SessionController.register` to `register(String inviteCode, String localNickname)` but make `RegistrationPage` receive a fixed `nickname` and render it as non-editable context plus an “编辑昵称” navigation action. Its only field is invite code. Registration still sends the current local nickname to the public server.

- [ ] **Step 6: Implement old-user migration once**

After successful session restore, if and only if no local profile has ever been committed, persist `session.user.nickname`. If the user already created a local nickname while offline, retain it and mark public sync pending when it differs from the restored server nickname.

- [ ] **Step 7: Run profile tests and capture built UI**

Run:

```bash
cd app && dart analyze
cd app && flutter test test/core/profile test/features/profile test/app_test.dart test/features/auth
cd app && flutter build apk --debug
cd app/android && ./gradlew :app:assembleDebugAndroidTest
adb install -r app/build/app/outputs/flutter-apk/app-debug.apk
adb install -r app/build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk
adb shell am instrument -w -e class me.zqydev.gamebox.NicknameRulesAarTest me.zqydev.gamebox.test/me.zqydev.gamebox.HostSmokeTestRunner
```

Install the APK, clear app data, capture the nickname setup and post-setup home. Repeat with a seeded old public session and capture the migrated greeting. Store credential-free PNGs under ignored `artifacts/issue-8/profile/`.

- [ ] **Step 8: Commit local identity**

```bash
git add app/lib app/test app/android/app/src/main/kotlin/me/zqydev/gamebox/AppProfileChannel.kt app/android/app/src/main/kotlin/me/zqydev/gamebox/MainActivity.kt app/android/app/src/androidTest/kotlin/me/zqydev/gamebox/NicknameRulesAarTest.kt
git commit -m "feat: add app-local nickname profile"
```

### Task 7: Add public nickname update and non-blocking sync

**Files:**

- Modify: `server/internal/auth/service.go`
- Modify: `server/internal/auth/service_test.go`
- Modify: `server/internal/httpapi/auth_handlers.go`
- Modify: `server/internal/httpapi/router.go`
- Modify: `server/internal/httpapi/router_test.go`
- Modify: `server/internal/httpapi/errors.go`
- Modify: `app/lib/core/api/api_client.dart`
- Modify: `app/lib/features/auth/auth_api.dart`
- Modify: `app/lib/features/auth/session_controller.dart`
- Modify: `app/lib/features/profile/profile_controller.dart`
- Modify: `app/lib/features/profile/nickname_page.dart`
- Modify: `app/test/core/api/api_client_test.dart`
- Modify: `app/test/features/auth/auth_api_test.dart`
- Modify: `app/test/features/auth/session_controller_test.dart`
- Modify: `app/test/features/profile/profile_controller_test.dart`
- Modify: `app/test/features/profile/nickname_page_test.dart`

- [ ] **Step 1: Write the public PATCH contract tests**

Specify `PATCH /v1/me` exactly:

```json
request:  {"nickname":"新昵称"}
success:  200 {"user":{"id":"uuid","nickname":"新昵称"}}
```

Test exact keys/types, unauthenticated, invalid nickname, case-insensitive conflict, unchanged nickname, concurrent updates, transaction rollback and stable `nickname_taken`/`invalid_request` errors. Add `PATCH` to the method fallback `Allow` header without changing `GET /v1/me`.

Run: `cd server && go test ./internal/auth ./internal/httpapi -run 'Nickname|PatchMe|Method'`

Expected: FAIL with 405/not implemented.

- [ ] **Step 2: Add transactional account update**

Implement:

```go
func (service *Service) UpdateNickname(ctx context.Context, userID, rawNickname string) (users.User, error)
```

Call `users.NormalizeNickname`, update `nickname`, `normalized_nickname`, and `updated_at` in one immediate transaction, map the unique index to `ErrNicknameTaken`, and do not rotate/revoke sessions or rewrite match/event snapshots.

- [ ] **Step 3: Add a non-replaying Dart PATCH**

Add `ApiClient.patchJson`. Like POST, it may call the 401 refresh hook for future operations but must never automatically replay the mutation. Extend `AuthApi`:

```dart
Future<User> updateNickname(String nickname, {
  required AccessTokenProvider accessToken,
  required UnauthorizedHandler onUnauthorized,
});
```

On success, update only the in-memory `Session.user`; keep the existing refresh token and expiration values.

- [ ] **Step 4: Implement deterministic sync scheduling**

`ProfileController` immediately commits the local nickname and returns success to the page before public sync. If authenticated, attempt once immediately. On `network_error`, `timeout`, or `internal_error`, retain `pending` and retry on app start, foreground resume, explicit retry, and at most once per five-minute foreground session. On `nickname_taken` or `invalid_request`, set a blocking sync code, stop automatic retry, keep the local nickname, and keep gameplay enabled. On `unauthorized`, let session recovery own credentials and retain pending state.

- [ ] **Step 5: Prove sync failure never gates play**

Widget/controller tests must start both public and LAN navigation while sync is transiently failed and while it is conflict-blocked. Assert the public greeting uses the local nickname while opponent APIs continue to receive server IDs/tokens.

- [ ] **Step 6: Run focused and full server/app tests**

Run:

```bash
cd server && go test ./internal/auth ./internal/httpapi -count=10
cd app && flutter test test/core/api test/features/auth test/features/profile
bash tool/verify_fast.sh
```

Expected: PASS.

- [ ] **Step 7: Commit public profile sync**

```bash
git add server/internal/auth server/internal/httpapi app/lib app/test
git commit -m "feat: sync local nickname to public account"
```

## Milestone 3: Deliver LAN room creation, QR join and recovery UI

### Task 8: Implement strict QR codecs, guest credentials and LAN REST client

**Files:**

- Modify: `app/pubspec.yaml`
- Modify: `app/pubspec.lock`
- Create: `app/lib/core/lan/lan_qr_payload.dart`
- Create: `app/lib/core/lan/private_ipv4.dart`
- Create: `app/lib/core/lan/lan_credential_store.dart`
- Create: `app/lib/core/lan/lan_api.dart`
- Create: `app/lib/core/lan/lan_models.dart`
- Create: `app/test/core/lan/lan_qr_payload_test.dart`
- Create: `app/test/core/lan/private_ipv4_test.dart`
- Create: `app/test/core/lan/lan_credential_store_test.dart`
- Create: `app/test/core/lan/lan_api_test.dart`

- [ ] **Step 1: Pin QR dependencies and write parser tests first**

Add:

```yaml
mobile_scanner: 7.4.0
qr_flutter: 4.1.0
```

Keep bundled ML Kit so scanning works without Google Play/network. Do not set `dev.steenbakker.mobile_scanner.useUnbundled=true`.

Test canonical join and recovery URIs:

```text
gamebox-lan://join?v=1&room=<uuid>&host=<private-ipv4>&port=<1-65535>&key=<base64url>&exp=<unix-ms>
gamebox-lan://resume?v=1&room=<uuid>&host=<private-ipv4>&port=<1-65535>
```

Reject duplicate/unknown/missing query keys, fragments, userinfo, noncanonical UUID/base64url/integer, expired join payload, public/loopback/link-local/multicast IPv4 and recovery without a matching stored room credential.

Run: `cd app && flutter test test/core/lan`

Expected: FAIL because LAN core types do not exist.

- [ ] **Step 2: Implement immutable QR models**

Expose only `parse(raw, now)` and `encode()`; never expose a `toString()` containing the join key. Error objects carry stable codes, not raw payload. Recovery payload has no key/expiry. Allow debug emulator address `10.0.2.2` because it is in `10/8`; production has no special public-address bypass.

- [ ] **Step 3: Isolate LAN credentials**

Use `flutter_secure_storage` keys prefixed `gamebox_lan_room_v1_`, separate from `SecureTokenStore.refreshTokenKey`. Persist `roomId`, `joinAttemptId`, candidate/resume token and last endpoint as one versioned encrypted JSON value. Generate the attempt ID and candidate token before the first join request. Delete candidates on authoritative rejection; retain them on timeout/response loss; delete final credentials only after cancel/terminal/explicit abandon is committed.

- [ ] **Step 4: Implement a dedicated LAN API**

Construct `http.Client` with each validated QR endpoint; do not use `ApiClient`, public base URL, access-token provider or 401 refresh. Set bounded timeouts/body sizes and no redirects. Add:

```dart
Future<LanJoinReceipt> join(LanJoinQr qr, LanJoinCandidate candidate, String nickname);
Future<LanLaunchReceipt> resumeTicket(LanResumeQr qr, LanCredential credential);
Future<AuthoritativeGameResult> fetchResult(LanEndpoint endpoint, LanCredential credential);
Future<void> acknowledgeResult(LanEndpoint endpoint, LanCredential credential, String resultHash);
```

- [ ] **Step 5: Run dependency and LAN-core tests**

Run:

```bash
cd app && flutter pub get
cd app && flutter test test/core/lan
cd app && dart analyze
```

Expected: PASS, and `pubspec.lock` resolves exactly the pinned direct versions.

- [ ] **Step 6: Commit QR and guest client boundaries**

```bash
git add app/pubspec.yaml app/pubspec.lock app/lib/core/lan app/test/core/lan
git commit -m "feat: add secure LAN join client"
```

### Task 9: Add Flutter room orchestration and user-facing LAN flows

**Files:**

- Create: `app/lib/core/platform/lan_host_platform.dart`
- Create: `app/lib/core/platform/method_channel_lan_host_platform.dart`
- Create: `app/lib/features/lan/lan_room_controller.dart`
- Create: `app/lib/features/lan/lan_mode_page.dart`
- Create: `app/lib/features/lan/lan_host_page.dart`
- Create: `app/lib/features/lan/lan_join_page.dart`
- Create: `app/lib/features/lan/lan_recovery_card.dart`
- Modify: `app/lib/features/home/home_page.dart`
- Modify: `app/lib/app.dart`
- Create: `app/test/core/platform/method_channel_lan_host_platform_test.dart`
- Create: `app/test/features/lan/lan_room_controller_test.dart`
- Create: `app/test/features/lan/lan_mode_page_test.dart`
- Create: `app/test/features/lan/lan_host_page_test.dart`
- Create: `app/test/features/lan/lan_join_page_test.dart`
- Modify: `app/test/features/home/home_page_test.dart`
- Modify: `app/test/app_home_test.dart`

- [ ] **Step 1: Write controller state-transition tests**

Define explicit states:

```dart
sealed class LanRoomState {}
final class LanIdle extends LanRoomState {}
final class LanCreating extends LanRoomState {}
final class LanWaitingForGuest extends LanRoomState { /* join QR */ }
final class LanJoining extends LanRoomState {}
final class LanReady extends LanRoomState { /* launch receipt */ }
final class LanActive extends LanRoomState { /* revision, role */ }
final class LanEndpointChanged extends LanRoomState { /* recovery QR */ }
final class LanRecoveryCorrupt extends LanRoomState {}
final class LanFinishedAwaitingAck extends LanRoomState {}
```

Test creation, scan, manual raw input, response-loss join retry, camera denial fallback, no network address, room locked, endpoint change, app resume, revision-0 cancel, revision>0 confirmed resign, corrupt recovery discard, and public session preservation.

Run: `cd app && flutter test test/features/lan test/core/platform/method_channel_lan_host_platform_test.dart`

Expected: FAIL because controller/pages do not exist.

- [ ] **Step 2: Implement the strict platform adapter**

Decode only the version-1 maps from `me.zqydev.gamebox/lan_host`; reject unknown/missing keys as `LanHostException('invalid_response')`. Keep secrets wrapped in private model fields whose `toString()` is redacted.

- [ ] **Step 3: Add mode entry without public auth gating**

The Gomoku card renders “公网对战” and “局域网对战.” Public selection routes to current matchmaking or invite registration. LAN selection always routes to `LanModePage` after local profile exists, regardless of public session or nickname-sync state. If a local active room exists, render “继续局域网对局” and “放弃” before allowing creation.

- [ ] **Step 4: Implement host QR and recovery QR pages**

Use `QrImageView` for the exact encoded payload, but wrap screenshot/log tooling so credential-bearing QR regions are never stored as artifacts. Waiting page shows connection state and a manual “刷新网络地址.” Once the room locks, replace the initial QR with a recovery QR that contains only room ID/endpoint.

- [ ] **Step 5: Implement scan and manual entry**

`LanJoinPage` requests camera only after the user taps scan. `MobileScanner` accepts only QR format and stops after the first syntactically valid Gamebox payload. Camera denial/unavailability keeps a text field for raw payload. Every parse/network error is stable and does not expose raw input or secrets.

- [ ] **Step 6: Implement close semantics**

- revision 0: “取消房间” commits cancel and creates no result;
- revision >0: “放弃对局” requires confirmation and sends resignation;
- corrupt recovery: a separate two-step “删除损坏房间” path warns that no trustworthy result can be created;
- back/Home/background: save state and navigate without calling any close method.

- [ ] **Step 7: Run widgets and built-app screenshots**

Run:

```bash
cd app && flutter test test/features/lan test/features/home test/app_home_test.dart
cd app && dart analyze
cd app && flutter build apk --debug
```

Install the APK and capture credential-free screens for: public/LAN choice, LAN mode choice, camera-denied manual input, active-room recovery card, and abandon confirmation. For the host waiting page, mask the QR region before saving the screenshot and assert the artifact scanner cannot decode a payload.

- [ ] **Step 8: Commit LAN UI**

```bash
git add app/lib app/test
git commit -m "feat: add LAN room user flows"
```

## Milestone 4: Persist identical public and LAN game results

### Task 10: Define the canonical result projection and public single-result endpoint

**Files:**

- Create: `server/internal/results/models.go`
- Create: `server/internal/results/encode.go`
- Create: `server/internal/results/encode_test.go`
- Create: `protocol/fixtures/game_result.json`
- Create: `server/internal/store/migrations/002_match_player_nickname.sql`
- Modify: `server/internal/store/migrate.go`
- Modify: `server/internal/store/migrate_test.go`
- Modify: `server/internal/matches/service.go`
- Modify: `server/internal/matches/service_test.go`
- Modify: `server/internal/matches/hub.go`
- Modify: `server/internal/httpapi/game_handlers.go`
- Modify: `server/internal/httpapi/router.go`
- Modify: `server/internal/httpapi/errors.go`
- Modify: `server/internal/httpapi/router_test.go`
- Modify: `server/internal/httpapi/e2e_test.go`
- Modify: `server/internal/protocol/messages.go`
- Modify: `server/internal/protocol/messages_test.go`
- Modify: `server/internal/lan/room/models.go`
- Modify: `server/internal/lan/room/service.go`
- Modify: `server/internal/lan/httpapi/hub.go`

- [ ] **Step 1: Write the cross-source result fixture first**

Define one canonical payload independent of transport source:

```go
type GameResult struct {
    SchemaVersion int               `json:"schemaVersion"`
    MatchID       string            `json:"matchId"`
    GameID        string            `json:"gameId"`
    Players       [2]PlayerSnapshot `json:"players"`
    WinnerUserID  *string           `json:"winnerUserId"`
    Result        string            `json:"result"`
    StartedAt     int64             `json:"startedAt"`
    FinishedAt    int64             `json:"finishedAt"`
    FinalRevision int64             `json:"finalRevision"`
    Events        []CanonicalEvent  `json:"events"`
}
```

Each player has user ID, nickname, seat and color. Each canonical event has revision, type, action ID, actor ID, payload and committed time. `source` is deliberately absent from the authoritative payload; each client supplies it from `PendingGameResult`.

Add `platform.match.result` as a derived revision-bound server message. It does not increment game revision and is never fed into Gomoku replay. Update Go and Godot fixtures in Task 12.

- [ ] **Step 2: Write public result endpoint tests**

Specify `GET /v1/matches/{matchId}/result`:

- participant + terminal match: `200 {"result": <GameResult>}`;
- active match: `409 match_not_finished`;
- nonparticipant/missing: `404 match_not_found` with no existence leak;
- malformed path: `400 invalid_request`;
- no list/history endpoint is added.

Run: `cd server && go test ./internal/results ./internal/matches ./internal/httpapi -run 'Result|Finished'`

Expected: FAIL because projection and route do not exist.

- [ ] **Step 3: Build results from committed canonical events**

Public `matches.Service.Result` reads match, both players plus nickname snapshots, and every committed event in one read transaction. LAN `room.Service.Result` builds the same model from its verified journal projection. Both pass through `results.ValidateAndEncode`, and tests require byte-equivalent output for equivalent matches.

Do not query current user nicknames for results after match completion; persist player nickname snapshots when a match/room is created or joined. Migration `002_match_player_nickname.sql` must rebuild `match_players` with `nickname_snapshot TEXT NOT NULL`, backfill existing rows from `users.nickname` inside the migration transaction, recreate the primary/unique/foreign-key constraints, and register version 2 in `migrate.go`. Add migration tests for backfill, constraints, checksum ledger, rollback and repeat-open idempotency. Existing completed rows receive their nickname at upgrade time; no historical enumeration endpoint is introduced.

- [ ] **Step 4: Deliver terminal results on WebSocket and reconnect**

After a terminal event/snapshot is queued, queue exactly one `platform.match.result` at the same revision. A terminal reconnect always receives connected → snapshot → result. A client may receive the same result repeatedly; payload hash and match ID make it idempotent.

- [ ] **Step 5: Run contract and compatibility tests**

Run:

```bash
cd server && go test ./internal/results ./internal/matches ./internal/httpapi ./internal/lan/room ./internal/lan/httpapi ./internal/protocol -count=10
cd server && go test -race ./internal/matches ./internal/lan/room
```

Expected: PASS; public and LAN fixtures encode identically.

- [ ] **Step 6: Commit authoritative results**

```bash
git add server protocol/fixtures/game_result.json
git commit -m "feat: expose canonical match results"
```

### Task 11: Add Android cross-process result and pending markers

**Files:**

- Create: `app/android/app/src/main/kotlin/me/zqydev/gamebox/GameResultBridge.kt`
- Create: `app/android/app/src/main/kotlin/me/zqydev/gamebox/GameResultValidator.kt`
- Create: `app/android/app/src/main/kotlin/me/zqydev/gamebox/AtomicResultStore.kt`
- Create: `app/android/app/src/main/kotlin/me/zqydev/gamebox/PendingGameResultStore.kt`
- Modify: `app/android/app/src/main/kotlin/me/zqydev/gamebox/GameActivity.kt`
- Modify: `app/android/app/src/main/kotlin/me/zqydev/gamebox/MainActivity.kt`
- Modify: `app/android/app/src/main/kotlin/me/zqydev/gamebox/GameLaunchArgs.kt`
- Create: `app/android/app/src/test/kotlin/me/zqydev/gamebox/GameResultValidatorTest.kt`
- Create: `app/android/app/src/test/kotlin/me/zqydev/gamebox/AtomicResultStoreTest.kt`
- Create: `app/android/app/src/test/kotlin/me/zqydev/gamebox/PendingGameResultStoreTest.kt`
- Modify: `app/android/app/src/test/kotlin/me/zqydev/gamebox/GameLaunchArgsTest.kt`
- Create: `app/android/app/src/androidTest/kotlin/me/zqydev/gamebox/GameResultBridgeTest.kt`

- [ ] **Step 1: Write strict validator and crash-order tests**

Load `protocol/fixtures/game_result.json` and reject unknown/missing fields, invalid UUIDs, invalid result/reason/color, inconsistent winner, non-contiguous events, mismatched final revision, oversized input, duplicate JSON keys, path traversal and a result whose match ID differs from the pending marker.

Test this exact order:

```text
pending fsync+rename -> launch Godot -> result fsync+rename -> LAN ack -> pending delete
```

Failures at any arrow leave enough state for foreground recovery and never emit an ack early.

- [ ] **Step 2: Persist pending before every launch**

Extend native launch arguments with non-secret `source=public|lan` and persist `{schemaVersion, matchId, gameId, source, endpointKind}` before `startActivity`. Store no URL, ticket or token. If pending persistence fails, reject launch with `result_tracking_unavailable`.

- [ ] **Step 3: Implement the Godot Android plugin**

Create a `GodotPlugin` named `GameboxResultBridge`, register it from `GameActivity.getHostPlugins`, and expose one `@UsedByGodot` method:

```kotlin
fun persistAuthoritativeResult(resultJson: String): Boolean
```

The plugin validates against the pending marker, writes `filesDir/game_results/<matchId>.json` by temp → fd sync → rename → directory sync, treats identical existing content as success, and rejects conflicting duplicate content. Its return value means durable local persistence, not merely validation.

- [ ] **Step 4: Expose pending/result operations to Flutter**

Add methods to a separate `me.zqydev.gamebox/game_results` MethodChannel:

```text
listCommitted(arguments: null)
listPending(arguments: null)
completePending({matchId, expectedSha256})
quarantine({matchId})
```

Return bounded strict JSON and never expose LAN/public credentials.

- [ ] **Step 5: Run JVM and instrumentation tests**

Run:

```bash
cd app/android && ./gradlew :app:testDebugUnitTest :app:assembleDebug :app:assembleDebugAndroidTest
adb install -r app/build/app/outputs/apk/debug/app-debug.apk
adb install -r app/build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk
adb shell am instrument -w -e class me.zqydev.gamebox.GameResultBridgeTest me.zqydev.gamebox.test/me.zqydev.gamebox.HostSmokeTestRunner
```

Expected: PASS, including idempotent duplicate and process-restart recovery.

- [ ] **Step 6: Commit the native result bridge**

```bash
git add app/android
git commit -m "feat: persist authoritative game results"
```

### Task 12: Consume terminal results in Godot and acknowledge only durable writes

**Files:**

- Modify: `game_runtime/core/protocol.gd`
- Modify: `game_runtime/core/match_client.gd`
- Modify: `game_runtime/games/gomoku/gomoku_controller.gd`
- Modify: `game_runtime/test/test_protocol.gd`
- Modify: `game_runtime/test/test_match_client.gd`
- Modify: `game_runtime/test/test_gomoku_scene.gd`

- [ ] **Step 1: Write failing result-message tests**

Load the shared result fixture, require `platform.match.result` at the current terminal revision, reject active-state results, mismatched players/match/revision, invalid event histories and conflicting duplicate payloads. Test result-before-terminal-state as a protocol failure and duplicate-identical result as idempotent.

Run: `bash tool/verify_godot_tests.sh`

Expected: FAIL because Godot does not know the new message type/bridge.

- [ ] **Step 2: Add a result signal without mutating Gomoku revision**

Extend `MatchClient`:

```gdscript
signal authoritative_result_received(result: Dictionary)
```

Handle `platform.match.result` separately from `_game_state.apply_event`. Require `envelope.revision == _game_state.revision`, terminal status and exact result schema before emitting a deep copy. Keep reconnect/watchdog behavior unchanged.

- [ ] **Step 3: Call the native bridge from the controller**

Resolve `Engine.get_singleton("GameboxResultBridge")` only after an authoritative result arrives. Serialize the validated payload with stable JSON and call `persistAuthoritativeResult`. On `true`, leave the pending marker in place; Flutter imports the committed file and sends the LAN acknowledgement on its next foreground pass, so the `:game` process never needs public or LAN credentials. On `false` or missing singleton, retain pending, display a non-terminal “战绩保存待重试” message, and do not close or invalidate the playable terminal board.

- [ ] **Step 4: Preserve non-resignation exits**

Retain current back/Home behavior: dispose the client and quit Godot without sending resign. Only the existing explicit resign control submits `gomoku.resign.requested`.

- [ ] **Step 5: Run Godot and protocol gates**

Run:

```bash
bash tool/verify_godot_tests.sh
bash tool/verify_fast.sh
```

Expected: PASS; existing public protocol tests remain green.

- [ ] **Step 6: Commit Godot result handling**

```bash
git add game_runtime
git commit -m "feat: bridge terminal results from Godot"
```

### Task 13: Import, recover and display unified local history

**Files:**

- Create: `app/lib/core/results/game_result.dart`
- Create: `app/lib/core/results/game_result_platform.dart`
- Create: `app/lib/core/results/game_history_store.dart`
- Create: `app/lib/features/history/history_controller.dart`
- Create: `app/lib/features/history/history_page.dart`
- Modify: `app/lib/features/home/home_page.dart`
- Modify: `app/lib/features/gomoku/gomoku_repository.dart`
- Modify: `app/lib/features/home/home_api.dart`
- Modify: `app/lib/features/lan/lan_room_controller.dart`
- Create: `app/test/core/results/game_result_test.dart`
- Create: `app/test/core/results/game_history_store_test.dart`
- Create: `app/test/features/history/history_controller_test.dart`
- Create: `app/test/features/history/history_page_test.dart`
- Modify: `app/test/features/gomoku/gomoku_repository_test.dart`
- Modify: `app/test/features/lan/lan_room_controller_test.dart`
- Modify: `app/test/features/home/home_page_test.dart`

- [ ] **Step 1: Write strict import and mixed-list tests**

Define local-only enrichment:

```dart
enum GameResultSource { public, lan }

final class GameResult {
  final AuthoritativeGameResult authoritative;
  final GameResultSource source;
  final String localUserId;
}
```

Test duplicate match IDs, conflicting files, corrupt files, source preservation, local win/loss/draw projection, event continuity, stable ordering by `finishedAt` then match ID, public/LAN mixing without source labels, and public logout not deleting history.

Run: `cd app && flutter test test/core/results test/features/history`

Expected: FAIL because history code does not exist.

- [ ] **Step 2: Import committed native files into an atomic index**

Use the result MethodChannel to enumerate files, validate again in Dart, and maintain a versioned index under app support. The result file remains the source of truth; the index is rebuildable. Quarantine corruption from UI without deleting evidence. Never expose a method that uploads a LAN result.

- [ ] **Step 3: Recover pending results narrowly**

On app start/resume:

- `source=public`: call authenticated `GET /v1/matches/{matchId}/result` for that exact known ID;
- `source=lan`: call the stored room endpoint with the LAN resume token; if endpoint changed, keep pending until recovery QR supplies a new endpoint;
- active/not-finished: keep pending;
- authoritative not-found/cancel: clear pending only after exact contract validation;
- transient errors: keep pending and gameplay available.

After native persistence succeeds, LAN sends `result-ack` with SHA-256; only a successful/idempotent ack clears pending LAN credentials. Public pending clears after local persistence without any upload.

- [ ] **Step 4: Add a source-neutral history page**

Add one “战绩” entry from home. List nickname matchup, local outcome, color, reason, end time and final moves/revision. Do not render source text, icon, color, filter, debug badge or accessibility label. Empty and corrupt-file states remain usable.

- [ ] **Step 5: Run tests and built UI evidence**

Run:

```bash
cd app && flutter test test/core/results test/features/history test/features/home test/features/gomoku test/features/lan
cd app && dart analyze
cd app && flutter build apk --debug
```

Install a built APK seeded through debug-only safe result fixtures, capture a mixed two-row history list, and use semantics/UI inspection to assert no `public`, `lan`, `公网`, or `局域网` source label appears.

- [ ] **Step 6: Commit unified history**

```bash
git add app/lib app/test
git commit -m "feat: add unified local match history"
```

## Milestone 5: Automate the complete LAN loop and collect target-runtime evidence

### Task 14: Add the two-emulator real-engine LAN E2E gate

**Files:**

- Create: `tool/e2e_lan_android.sh`
- Create: `tool/fixtures/e2e_lan_fake_adb.sh`
- Modify: `tool/lib/android_lease.sh`
- Modify: `tool/test_android_lease.sh`
- Modify: `app/android/app/src/androidTest/kotlin/me/zqydev/gamebox/HostSmokeTestRunner.kt`
- Create: `app/android/app/src/androidTest/kotlin/me/zqydev/gamebox/LanE2eInputTest.kt`
- Modify: `README.md`

- [ ] **Step 1: Write harness parser/cleanup self-tests first**

`bash tool/e2e_lan_android.sh --self-test` must cover two-device serial selection, shared emulator lease, `adb forward tcp:0`, port parsing, process cleanup, timeout exit, artifact redaction, forced-stop recovery and rejection of credential-bearing output. Start with the fake ADB fixture so these fail before the real harness exists.

- [ ] **Step 2: Implement safe debug-only payload injection**

Instrumentation may carry a payload directly into B only when `BuildConfig.DEBUG`, the target package is self, the caller is the test runner, and the payload is passed through a private file/FD that is deleted immediately after parsing. Production activities, exported intents and logs must have no injection path. The test output prints only room ID and payload SHA-256.

- [ ] **Step 3: Implement the real-engine two-emulator scenario**

The script must:

1. acquire the shared `Gamebox_A_API_36`/`Gamebox_B_API_36` lease;
2. build/install the same Debug APK and androidTest APK on both;
3. set different local nicknames without public registration;
4. create a room in A's real `LanHostService`/AAR;
5. forward A's device listener to a random host port and rewrite only the debug delivery endpoint for B to `10.0.2.2:<forwardedPort>`;
6. join B through the production parser/API;
7. launch both real Godot clients and play a deterministic win;
8. disconnect/reconnect B and assert snapshot revision equality;
9. exit/relaunch host Godot without stopping the service;
10. `am force-stop` host A, reopen it, restore the same room/revision/board, refresh endpoint if needed, and continue;
11. finish and verify equal authoritative payload hashes plus both durable local result files;
12. open both history pages and assert source-neutral display.

- [ ] **Step 4: Persist only redacted artifacts**

Write `artifacts/e2e-lan-android/<run-id>/summary.json`, sanitized logcat and screenshots. Add a final recursive scanner that fails if it finds URI schemes with query keys, base64url credential-shaped values, `launchTicket`, `resumeToken`, `roomKey`, `accessToken`, or `refreshToken`.

- [ ] **Step 5: Run self-test and real two-emulator gate**

Run:

```bash
bash tool/e2e_lan_android.sh --self-test
bash tool/e2e_lan_android.sh
```

Expected: both pass; summary records same room ID across host force-stop, monotonically increasing revisions, equal result hashes and no leaked credential material.

- [ ] **Step 6: Commit the LAN E2E gate**

```bash
git add tool app/android/app/src/androidTest README.md
git commit -m "test: add Android LAN playable-loop E2E"
```

### Task 15: Close unified gates, public regression and real two-phone acceptance

**Files:**

- Modify: `tool/verify.sh`
- Modify: `.github/workflows/ci.yml`
- Modify: `README.md`
- Create: `docs/testing/android-lan-hotspot-acceptance.md`

- [ ] **Step 1: Make the unified gate own every deterministic check**

Update `bash tool/verify.sh` to run:

1. bootstrap/tool pin verification;
2. server Go tests including LAN and results;
3. Flutter analyze/widget tests;
4. Godot tests and shared protocol fixtures;
5. Kotlin JVM tests;
6. gomobile AAR build;
7. Debug APK build;
8. exact ABI checks for Godot and Go JNI;
9. manifest permission/service assertions;
10. secret/credential asset and artifact scanning.

Do not put emulator E2E inside the default build gate; keep `tool/e2e_android.sh` and `tool/e2e_lan_android.sh` as explicit runtime gates with the common lease.

- [ ] **Step 2: Add CI coverage for the deterministic build**

Pin Go 1.25, Flutter 3.47.1, Android SDK 36 and an installed NDK supported by both Flutter and gomobile. CI runs `bash tool/verify.sh`; it must inspect the merged clean checkout and cannot rely on ignored AAR/Gradle outputs.

- [ ] **Step 3: Run all local deterministic and emulator gates**

Run from a clean task-scoped worktree:

```bash
bash tool/verify.sh
bash tool/e2e_android.sh
bash tool/e2e_lan_android.sh
git diff --check
git status --short
```

Expected: every gate exits 0. The existing public two-AVD loop remains unchanged and public tokens survive switching into/out of LAN.

- [ ] **Step 4: Build one release candidate and record its identity**

Build the signed or debug-signed release candidate according to repository release policy. Record APK SHA-256, version name/code, supported ABIs, target SDK, device models and Android versions in the ignored acceptance artifact. Verify private IPv4 cleartext works while public endpoints still use the configured HTTPS/WSS origin.

- [ ] **Step 5: Execute the real two-phone hotspot checklist**

Using the exact same candidate APK on both phones:

1. host enables Android system hotspot; guest joins it;
2. disable mobile data/public reachability;
3. host creates room; guest scans the real QR with camera;
4. verify assigned colors, board and revision on both;
5. interrupt/recover guest network with resume token;
6. force-stop host app, reopen, choose continue, rescan recovery QR only if endpoint changed;
7. finish one game and verify equal result/event hashes and both history entries;
8. confirm history UI has no source distinction;
9. restore public connectivity and confirm prior public session still exists;
10. induce nickname-sync/update-check failure and confirm LAN/history remain playable.

Capture credential-free screenshots for nickname/home, host waiting with QR region masked, joined boards, recovered room, terminal result and both history pages. Record observable assertions and hashes, not secrets.

- [ ] **Step 6: Review failure semantics against the approved spec**

Check every row in spec section 11.2 and every completion criterion in section 14. Specifically verify no auto-expiry, no host migration, no implicit resignation, no LAN upload, no public-token deletion, no silent journal repair and no missing-result acknowledgement before durable write.

- [ ] **Step 7: Commit final gates and documentation**

```bash
git add tool/verify.sh .github/workflows/ci.yml README.md docs/testing/android-lan-hotspot-acceptance.md
git commit -m "test: close Android LAN hosting acceptance"
```

- [ ] **Step 8: Perform final branch verification before integration**

Use `superpowers:verification-before-completion`, then `superpowers:requesting-code-review`. Re-run the exact commands whose success will be claimed, inspect `git status`, review the full diff against Issue #8, and only then use `superpowers:finishing-a-development-branch` to choose merge/PR/cleanup. Do not push until the user explicitly requests it.

## Execution Notes

- Tasks are ordered by risk and dependency. Do not start UI work before Milestone 1 proves AAR packaging, Android hosting, second-client connectivity and journal recovery on a device.
- Red-green-refactor is mandatory inside every task: add the focused failing test, run it and observe the expected failure, implement the smallest behavior, rerun, then refactor under green tests.
- A task commit may be split further when a migration or generated lockfile needs an isolated review, but never combine unrelated cleanup or user-owned worktree changes.
- Any Android API/permission behavior that has changed since this plan's 2026-08-22 baseline must be rechecked against official Android documentation before implementation. Dependency upgrades require their own compatibility proof; do not silently float the pinned QR or gomobile versions.
