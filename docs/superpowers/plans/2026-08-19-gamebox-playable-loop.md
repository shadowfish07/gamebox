# Gamebox 首个可玩闭环 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在两台 Android 模拟器上完成一次性邀请码注册、选择指定对手、进行一局服务端权威五子棋、断线恢复、结束后释放双方游戏槽位的真实闭环。

**Architecture:** Flutter 只负责身份和大厅；Android 用独立的 `:game` 进程启动全屏 `GodotActivity`；Godot 只负责游戏表现和 WebSocket 客户端；Go 单进程通过 HTTP、WebSocket 和 SQLite WAL 维护权威状态。三个运行时都以 `gameId` 和窄注册表隔离游戏模块，但本期只实现 `gomoku`。

**Tech Stack:** Flutter 3.35.1 / Dart 3.9、Godot 4.7 stable / GDScript、Kotlin / Android API 36 / JDK 17、Go 1.25、`modernc.org/sqlite v1.56.0`、`github.com/coder/websocket v1.8.15`、`github.com/golang-jwt/jwt/v5 v5.3.1`、`github.com/google/uuid v1.6.0`。

---

## 实施约束

- 本计划实现且只实现规格 [2026-08-19-gamebox-playable-loop-design.md](../specs/2026-08-19-gamebox-playable-loop-design.md) 的本期内容。F2–F5 和 AI、同屏双人、好友、随机匹配、聊天、观战、推送不进入本计划。
- 所有命令默认从仓库根目录 `/Users/shadowfish/godot/gamebox` 执行。
- 每个行为先写失败测试，确认失败原因正确，再写最小实现；不要把多个红灯阶段积在一起。
- 每项任务只暂存列出的文件，完成测试后创建本任务自己的提交；不要改写或清理用户的无关变更。
- 时间统一保存为 UTC Unix 毫秒；ID 使用 UUID 字符串；令牌使用 32 字节加密随机数的 base64url 明文，服务端只保存 `SHA-256(pepper || token)`。
- 任何日志都不得打印邀请码、access token、refresh token、launch ticket 或 resume token 明文。
- Android 开发基址为 `http://10.0.2.2:8080`，WebSocket 为 `ws://10.0.2.2:8080/v1/ws`；release 构建不允许明文流量。
- Godot 项目通过 Android `assets` 源目录直接打包，不生成或提交 PCK。该方式是 Godot Android Library 的官方支持路径，并避免首个闭环额外依赖 Android export templates。
- `GameActivity` 使用 `android:process=":game"`。Godot 退出时只终止游戏进程，下面的 Flutter Activity 保持存活；第一个 Android 里程碑必须连续启动、退出两次验证该假设。

规格覆盖映射：

| 规格能力 | 实施任务 |
| --- | --- |
| Flutter/Godot 同包与生命周期 | Task 1–4 |
| 版本化多游戏边界 | Task 2、5、9、18 |
| 邀请码、昵称、自动登录 | Task 6–8、13、17 |
| 指定对手、一人一局、零步取消 | Task 10、13、18 |
| 服务端权威五子棋 | Task 9、11、19、20 |
| 心跳、重连、24 小时作废 | Task 12、14、19 |
| 事件持久化与服务重启恢复 | Task 6、11、15 |
| 双模拟器真实闭环与 CI | Task 21–22 |

## 目标文件结构

```text
gamebox/
├── .github/workflows/ci.yml
├── .gitignore
├── README.md
├── app/
│   ├── lib/
│   │   ├── main.dart
│   │   ├── app.dart
│   │   ├── core/api/{api_client.dart,api_error.dart}
│   │   ├── core/auth/{session.dart,token_store.dart}
│   │   ├── core/platform/{game_launch_request.dart,game_launcher.dart,method_channel_game_launcher.dart}
│   │   ├── features/auth/{auth_api.dart,session_controller.dart,registration_page.dart}
│   │   ├── features/home/{game_catalog.dart,home_api.dart,home_controller.dart,home_page.dart,opponent_page.dart}
│   │   └── features/gomoku/{gomoku_models.dart,gomoku_repository.dart}
│   ├── test/ 与 integration_test/
│   └── android/app/
│       ├── build.gradle.kts
│       └── src/
│           ├── main/AndroidManifest.xml
│           ├── debug/AndroidManifest.xml
│           ├── main/kotlin/me/zqydev/gamebox/{MainActivity.kt,GameActivity.kt,GameLaunchArgs.kt}
│           └── test/kotlin/me/zqydev/gamebox/GameLaunchArgsTest.kt
├── game_runtime/
│   ├── project.godot
│   ├── main.tscn
│   ├── main.gd
│   ├── core/{game_registry.gd,launch_config.gd,protocol.gd,match_client.gd}
│   ├── games/gomoku/{gomoku_scene.tscn,gomoku_controller.gd,gomoku_board.gd,gomoku_state.gd}
│   └── test/{run_tests.gd,test_launch_config.gd,test_registry.gd,test_protocol.gd,test_gomoku_state.gd,test_match_client.gd}
├── protocol/
│   ├── README.md
│   └── fixtures/{snapshot.json,move_action.json,move_accepted.json,error.json}
├── server/
│   ├── go.mod 与 go.sum
│   ├── cmd/gameboxd/main.go
│   ├── cmd/gameboxctl/main.go
│   └── internal/
│       ├── auth/{service.go,tokens.go,service_test.go}
│       ├── clock/{clock.go,fake.go}
│       ├── config/config.go
│       ├── games/{registry.go,rules.go}
│       ├── games/gomoku/{board.go,rules.go,rules_test.go}
│       ├── httpapi/{router.go,auth_handlers.go,game_handlers.go,errors.go,event_publisher.go,router_test.go,e2e_test.go}
│       ├── matches/{models.go,service.go,presence.go,hub.go,service_test.go,presence_test.go}
│       ├── protocol/{envelope.go,messages.go}
│       ├── store/{store.go,migrate.go,migrate_test.go,migrations/001_initial.sql}
│       ├── users/{service.go,service_test.go}
│       └── testutil/{server.go,client.go}
├── tool/
│   ├── bootstrap.sh
│   ├── verify_fast.sh
│   ├── verify.sh
│   ├── smoke_android_host.sh
│   ├── ensure_test_avds.sh
│   └── e2e_android.sh
└── artifacts/e2e/                 # 生成物，gitignored
```

## 固定协议和错误码

所有 HTTP 错误返回：

```json
{"error":{"code":"opponent_busy","message":"对手已进入其他对局","details":{}}}
```

首版固定使用这些错误码：`invalid_request`、`unauthorized`、`invite_invalid`、`nickname_taken`、`opponent_busy`、`active_match_exists`、`match_not_found`、`match_not_cancellable`、`ticket_invalid`、`resume_expired`、`stale_revision`、`not_your_turn`、`cell_occupied`、`action_conflict`、`internal_error`。

HTTP 成功 body 固定为以下模型；`DELETE /v1/matches/{matchId}` 是唯一 204 空 body：

```json
{
  "session": {
    "user": {"id":"22222222-2222-4222-8222-222222222222","nickname":"Alice"},
    "accessToken":"test-access-token",
    "accessExpiresAt":1787119263000,
    "refreshToken":"test-refresh-token",
    "refreshExpiresAt":1789711200000
  }
}
```

`POST /v1/auth/register` body 为 `{"inviteCode":"TEST-CODE","nickname":"Alice"}`，`POST /v1/auth/refresh` body 为 `{"refreshToken":"test-refresh-token"}`，两者都返回上述 session。`GET /v1/me` 只返回 `{"user":{"id":"22222222-2222-4222-8222-222222222222","nickname":"Alice"}}`。

```json
{
  "opponents": [
    {
      "id":"22222222-2222-4222-8222-222222222222",
      "nickname":"Alice",
      "availability":"idle",
      "presence":"offline"
    }
  ]
}
```

`POST /v1/games/gomoku/matches` body 为 `{"opponentId":"22222222-2222-4222-8222-222222222222"}`，成功返回 `{"match":{"id":"11111111-1111-4111-8111-111111111111","gameId":"gomoku","state":"active"}}`。`GET /v1/games` 返回 `{"games":[{"id":"gomoku","title":"五子棋","playerCount":2}]}`。

WebSocket 外壳固定为：

```json
{
  "protocolVersion": 1,
  "gameId": "gomoku",
  "matchId": "11111111-1111-4111-8111-111111111111",
  "revision": 16,
  "type": "gomoku.move.accepted",
  "actionId": "33333333-3333-4333-8333-333333333333",
  "payload": {}
}
```

已绑定对局的服务端消息必须带 `revision`，不得带 `expectedRevision`；只有握手尚未识别对局时的 `platform.error` 可以省略 revision。客户端游戏动作必须带顶层 `expectedRevision` 和 `actionId`，不得带 `revision`；例如：

```json
{
  "protocolVersion": 1,
  "gameId": "gomoku",
  "matchId": "11111111-1111-4111-8111-111111111111",
  "expectedRevision": 3,
  "type": "gomoku.move.requested",
  "actionId": "33333333-3333-4333-8333-333333333333",
  "payload": {"x": 7, "y": 7}
}
```

`platform.connect` 是唯一不含 `gameId/matchId` 的首消息，票据自行绑定身份与对局。`platform.pong` 带 game/match 并原样回传 ping payload 的 `nonce`；`platform.snapshot.requested` 带 game/match，payload 为 `{"currentRevision":3}`；这两个控制消息都不带 actionId/revision/expectedRevision。Go `Envelope` 将 `Revision` 和 `ExpectedRevision` 定义为带 `omitempty` 的指针，并按消息类型验证字段组合。

客户端只提交 `platform.connect`、`platform.pong`、`gomoku.move.requested`、`gomoku.resign.requested`、`platform.snapshot.requested`。服务端只发送 `platform.connected`、`platform.ping`、`platform.snapshot`、`platform.error`、`gomoku.move.accepted`、`gomoku.resigned`、`platform.match.cancelled`、`platform.match.abandoned`。

## Phase 1：先消除 Flutter ↔ Godot Android 风险

### Task 1：脚手架、版本和统一验证入口

**Files:**
- Create: `app/**`（Flutter 生成文件）
- Create: `server/go.mod`, `server/go.sum`
- Create: `game_runtime/project.godot`, `game_runtime/main.tscn`, `game_runtime/main.gd`
- Create: `tool/bootstrap.sh`, `tool/verify_fast.sh`, `tool/verify.sh`
- Modify: `.gitignore`

- [ ] **Step 1：生成 Flutter Android 项目**

```bash
flutter create --platforms=android --org me.zqydev --project-name gamebox app
cd app && flutter pub add http flutter_secure_storage && cd ..
```

Expected: `app/android/app/build.gradle.kts` 存在，`flutter pub get` 成功。

- [ ] **Step 2：初始化并锁定 Go 模块**

```bash
cd server
go mod init me.zqydev/gamebox/server
go get github.com/coder/websocket@v1.8.15
go get github.com/google/uuid@v1.6.0
go get github.com/golang-jwt/jwt/v5@v5.3.1
go get modernc.org/sqlite@v1.56.0
cd ..
```

Expected: `go.mod` 使用 `go 1.25`，四个直接依赖版本与本计划一致。

- [ ] **Step 3：用 `apply_patch` 建立最小 Godot 工程**

`project.godot` 固定竖屏 1080×1920、canvas_items stretch、Compatibility renderer，并把 `res://main.tscn` 设为主场景。`main.tscn` 只挂载 `main.gd`，初始显示 `Gamebox host ready`。

- [ ] **Step 4：先写会失败的验证脚本**

`tool/verify_fast.sh` 依次运行：

```bash
(cd server && go test ./...)
(cd app && flutter analyze && flutter test)
"${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}" \
  --headless --path game_runtime --script res://test/run_tests.gd
```

运行：

```bash
bash tool/verify_fast.sh
```

Expected: Go/Flutter 通过，Godot 因 `res://test/run_tests.gd` 尚不存在而失败。这证明脚本确实执行三个运行时，而不是空壳。

- [ ] **Step 5：增加最小 Godot 测试 runner 后转绿**

创建 `game_runtime/test/run_tests.gd`，继承 `SceneTree`，执行空测试数组并以 `quit(0)` 退出；异常时 `quit(1)`。再次运行 `bash tool/verify_fast.sh`。

Expected: 三段均 exit 0；Godot 输出 `0 tests, 0 failures`。

- [ ] **Step 6：完成工具检查和忽略项**

`tool/bootstrap.sh` 只做非破坏性检查并明确报缺失项：Flutter 3.35.1、Dart 3.9、Go 1.25、Godot 4.7、JDK 17+、Android SDK 36、adb/emulator，以及 Android licenses 已接受。当前机器若 license 检查失败，在开始 Android build 前明确执行一次 `yes | flutter doctor --android-licenses`，随后重新运行 bootstrap；脚本本身不能静默修改 SDK。`.gitignore` 增加 `app/build/`、`app/.dart_tool/`、`game_runtime/.godot/`、`server/data/`、`artifacts/`，保留现有 `.superpowers/`。

Run: `bash tool/bootstrap.sh && git diff --check`。

- [ ] **Step 7：提交**

```bash
git add .gitignore app game_runtime server tool
git commit -m "build: scaffold gamebox runtimes"
```

### Task 2：Godot 启动参数与多游戏注册表

**Files:**
- Create: `game_runtime/core/launch_config.gd`
- Create: `game_runtime/core/game_registry.gd`
- Create: `game_runtime/games/gomoku/gomoku_scene.tscn`
- Create: `game_runtime/games/gomoku/gomoku_controller.gd`
- Create: `game_runtime/test/test_launch_config.gd`
- Create: `game_runtime/test/test_registry.gd`
- Modify: `game_runtime/main.gd`
- Modify: `game_runtime/test/run_tests.gd`

- [ ] **Step 1：先写启动参数失败测试**

覆盖：参数顺序无关；缺少 `game-id/match-id/launch-ticket/ws-url` 时拒绝；未知参数拒绝；错误字符串不包含票据明文。

```gdscript
func test_valid_launch_args() -> void:
    var config := LaunchConfig.parse(PackedStringArray([
        "--game-id", "gomoku", "--match-id", "m1",
        "--launch-ticket", "secret", "--ws-url", "ws://host/v1/ws"
    ]))
    assert_eq(config.game_id, "gomoku")
    assert_eq(config.match_id, "m1")
```

Run: Godot test command from Task 1.

Expected: parse error because `LaunchConfig` does not exist.

- [ ] **Step 2：实现不记录秘密的 `LaunchConfig`**

`LaunchConfig.parse(OS.get_cmdline_user_args())` 只接受四个键，验证 `game_id == "gomoku"`、非空 UUID 字符串、`ws://` 或 `wss://`。测试辅助断言放在 runner，不引入 GUT 插件。

- [ ] **Step 3：先写注册表失败测试**

测试 `gomoku` 返回 `PackedScene`，未知 `gameId` 返回结构化错误，注册表中恰好只有一个游戏。

Expected: `GameRegistry` 未定义而失败。

- [ ] **Step 4：实现窄注册表和占位场景**

```gdscript
class_name GameRegistry
extends RefCounted

const SCENES := {
    "gomoku": preload("res://games/gomoku/gomoku_scene.tscn"),
}

static func scene_for(game_id: String) -> PackedScene:
    return SCENES.get(game_id)
```

`main.gd` 完成两条入口：`--host-smoke` 时显示标记并在指定毫秒数后退出；正常时解析配置并实例化注册场景。不要在日志中输出完整 args。

- [ ] **Step 5：运行测试并提交**

```bash
bash tool/verify_fast.sh
git add game_runtime
git commit -m "feat(godot): add launch context and game registry"
```

### Task 3：Flutter 可替换的 GameLauncher 与宿主烟测入口

**Files:**
- Create: `app/lib/core/platform/game_launch_request.dart`
- Create: `app/lib/core/platform/game_launcher.dart`
- Create: `app/lib/core/platform/method_channel_game_launcher.dart`
- Create: `app/test/core/platform/method_channel_game_launcher_test.dart`
- Modify: `app/lib/main.dart`
- Create: `app/lib/app.dart`
- Create: `app/test/app_test.dart`

- [ ] **Step 1：先写 MethodChannel 失败测试**

```dart
test('launch sends only the approved bridge fields', () async {
  final calls = <MethodCall>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
    calls.add(call);
    return null;
  });

  await launcher.launch(const GameLaunchRequest(
    gameId: 'gomoku', matchId: 'm1', launchTicket: 'ticket',
    wsUrl: 'ws://10.0.2.2:8080/v1/ws',
  ));

  expect(calls.single.method, 'launchGame');
  expect((calls.single.arguments as Map).keys,
      unorderedEquals(['gameId', 'matchId', 'launchTicket', 'wsUrl']));
});
```

Run: `cd app && flutter test test/core/platform/method_channel_game_launcher_test.dart`。

Expected: imports/classes missing。

- [ ] **Step 2：实现跨端接口和 Android MethodChannel 实现**

`GameLauncher` 是抽象接口；`MethodChannelGameLauncher` 只调用 `me.zqydev.gamebox/game_launcher`。空字段在 Dart 侧先抛 `ArgumentError`，不打印 request 的 `toString()`。

- [ ] **Step 3：写 App 注入测试并实现烟测页**

`GameboxApp` 构造函数接收 `GameLauncher`。只有 `bool.fromEnvironment('GAMEBOX_HOST_SMOKE')` 为真时显示 key 为 `host-smoke.launch` 的按钮，点击发送 `--host-smoke` 对应的专用调用 `launchHostSmoke`；普通构建显示固定的“身份功能将在 Phase 3 接入”未认证页。

Run: `cd app && flutter analyze && flutter test`。

- [ ] **Step 4：提交**

```bash
git add app/lib app/test app/pubspec.*
git commit -m "feat(flutter): define game launcher boundary"
```

### Task 4：Android 嵌入 Godot AAR 并验证可重复返回

**Files:**
- Modify: `app/android/app/build.gradle.kts`
- Modify: `app/android/app/src/main/AndroidManifest.xml`
- Create: `app/android/app/src/debug/AndroidManifest.xml`
- Modify: `app/android/app/src/main/kotlin/me/zqydev/gamebox/MainActivity.kt`
- Create: `app/android/app/src/main/kotlin/me/zqydev/gamebox/GameActivity.kt`
- Create: `app/android/app/src/main/kotlin/me/zqydev/gamebox/GameLaunchArgs.kt`
- Create: `app/android/app/src/test/kotlin/me/zqydev/gamebox/GameLaunchArgsTest.kt`
- Create: `tool/smoke_android_host.sh`

- [ ] **Step 1：先写纯 Kotlin 参数构造失败测试**

```kotlin
@Test fun buildsGodotUserArgumentsWithoutLoggingFields() {
    assertArrayEquals(
        arrayOf("--", "--game-id", "gomoku", "--match-id", "m1",
            "--launch-ticket", "secret", "--ws-url", "ws://host/v1/ws"),
        GameLaunchArgs.build("gomoku", "m1", "secret", "ws://host/v1/ws")
    )
}
```

增加 `testImplementation("junit:junit:4.13.2")` 后运行：

```bash
cd app/android && ./gradlew :app:testDebugUnitTest --tests '*GameLaunchArgsTest'
```

Expected: `GameLaunchArgs` 不存在而失败。

- [ ] **Step 2：配置 Godot 4.7 AAR 和 assets**

在 `app/android/app/build.gradle.kts`：

```kotlin
android {
    defaultConfig { minSdk = 24 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    sourceSets["main"].assets.srcDir(rootProject.file("../../game_runtime"))
    androidResources {
        ignoreAssetsPattern = "!.svn:!.git:!.gitignore:!.ds_store:!*.scc:<dir>_*:!CVS:!thumbs.db:!picasa.ini:!*~"
    }
}

dependencies {
    implementation("org.godotengine:godot:4.7.0.stable")
    testImplementation("junit:junit:4.13.2")
}
```

Run: `cd app && flutter build apk --debug --dart-define=GAMEBOX_HOST_SMOKE=true`。

Expected: Gradle 能解析 AAR，APK 中包含 `assets/project.godot`。

- [ ] **Step 3：实现内部 Activity 桥接**

`MainActivity.configureFlutterEngine` 验证四个字符串参数后启动：

```kotlin
Intent(this, GameActivity::class.java).apply {
    putExtra(GodotActivity.EXTRA_COMMAND_LINE_PARAMS,
        GameLaunchArgs.build(gameId, matchId, launchTicket, wsUrl))
}
```

`launchHostSmoke` 传 `arrayOf("--", "--host-smoke", "--auto-exit-ms", "800")`。`GameActivity` 只需 `class GameActivity : GodotActivity()`。

Manifest 中 `GameActivity` 必须 `exported="false"`、`process=":game"`、`screenOrientation="portrait"`，并声明 Godot 所需的完整 `configChanges`。debug manifest 仅为本机地址设置 `usesCleartextTraffic="true"`；main manifest 不设置该标志。

- [ ] **Step 4：运行 Kotlin/Flutter/Android 静态验证**

```bash
cd app/android && ./gradlew :app:testDebugUnitTest && cd ../..
cd app && flutter analyze && flutter test && flutter build apk --debug \
  --dart-define=GAMEBOX_HOST_SMOKE=true && cd ..
unzip -l app/build/app/outputs/flutter-apk/app-debug.apk | \
  rg 'assets/flutter_assets|assets/project.godot|libgodot_android.so'
```

Expected: 三类资源都存在；所有测试通过。

- [ ] **Step 5：写并运行真实设备宿主烟测**

`tool/smoke_android_host.sh` 接受 `GAMEBOX_ANDROID_SERIAL`，清理 logcat、安装 APK、启动 Flutter、用 UI Automator 点击 `host-smoke.launch`，等待 `GAMEBOX_GODOT_READY`，确认 `:game` 进程退出且 `MainActivity` 再次 resumed，然后重复完整流程一次。

```bash
GAMEBOX_ANDROID_SERIAL=emulator-5554 bash tool/smoke_android_host.sh
```

Expected: 输出 `launch 1: PASS`、`launch 2: PASS`；无 `FATAL EXCEPTION`、ANR 或主进程死亡。

- [ ] **Step 6：提交技术样板**

```bash
git add app/android tool/smoke_android_host.sh
git commit -m "feat(android): embed reusable Godot game activity"
```

**Phase 1 Gate:** 此处暂停并运行 `bash tool/verify_fast.sh`、Android debug build 和两次宿主烟测。任何一项未通过都先修复，不进入服务端实现。

## Phase 2：独立完成可测试的 Go 权威服务端

### Task 5：冻结跨运行时协议样例

**Files:**
- Create: `protocol/README.md`
- Create: `protocol/fixtures/snapshot.json`
- Create: `protocol/fixtures/move_action.json`
- Create: `protocol/fixtures/move_accepted.json`
- Create: `protocol/fixtures/error.json`
- Create: `server/internal/protocol/envelope.go`
- Create: `server/internal/protocol/messages.go`
- Create: `server/internal/protocol/messages_test.go`
- Create: `game_runtime/core/protocol.gd`
- Create: `game_runtime/test/test_protocol.gd`
- Modify: `game_runtime/test/run_tests.gd`

- [ ] **Step 1：写 Go fixture 失败测试**

测试逐个读取 `../../../../protocol/fixtures/*.json`，反序列化再序列化；校验 `protocolVersion == 1`、所有消息均含 `type`，动作消息顶层含 `actionId` 和 `expectedRevision`，服务端消息含 `revision`，两种 revision 字段不会同时存在。

Run: `cd server && go test ./internal/protocol -run TestFixtures -v`。

Expected: protocol 类型和 fixtures 不存在。

- [ ] **Step 2：写四个确定的 JSON fixture 和 Go 类型**

`snapshot.json` payload 固定包含：

```json
{
  "status":"active",
  "board":[
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
  ],
  "boardSize":15,
  "blackUserId":"u1",
  "whiteUserId":"u2",
  "nextColor":"black",
  "winnerUserId":null,
  "result":null
}
```

实际 fixture 的 `board` 必须有 225 个整数。Go 使用 `json.RawMessage` 保存游戏 payload；不要建立跨游戏通用棋盘模型。

- [ ] **Step 3：写 Godot fixture 失败测试并实现解码**

`Protocol.decode(text)` 校验外壳字段和版本，返回 Dictionary；`Protocol.encode_action(type, match_id, revision, action_id, payload)` 固定生成 camelCase 字段。测试读取同一组 fixture，证明 Go 与 Godot 没有两套字段命名。

Run: `bash tool/verify_fast.sh`。

- [ ] **Step 4：提交**

```bash
git add protocol server/internal/protocol game_runtime/core/protocol.gd \
  game_runtime/test/test_protocol.gd game_runtime/test/run_tests.gd
git commit -m "feat(protocol): freeze version one match messages"
```

### Task 6：SQLite WAL、迁移和可注入时钟

**Files:**
- Create: `server/internal/clock/clock.go`
- Create: `server/internal/clock/fake.go`
- Create: `server/internal/store/store.go`
- Create: `server/internal/store/migrate.go`
- Create: `server/internal/store/migrations/001_initial.sql`
- Create: `server/internal/store/migrate_test.go`

- [ ] **Step 1：先写数据库失败测试**

测试临时数据库首次迁移成功、重复迁移不改变 schema、`PRAGMA journal_mode` 为 `wal`、`foreign_keys` 为 `1`、`busy_timeout` 为 `5000`，并验证所有预期表存在。

Run: `cd server && go test ./internal/store -run TestOpenAndMigrate -v`。

Expected: `store.Open` 不存在。

- [ ] **Step 2：实现 SQLite 打开和迁移**

DSN 固定为：

```go
dsn := "file:" + path +
    "?_journal_mode=WAL&_foreign_keys=on&_busy_timeout=5000&_txlock=immediate"
```

打开后 `SetMaxOpenConns(8)`、`SetMaxIdleConns(8)` 并 `PingContext`。嵌入 SQL migration，用 `schema_migrations(version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL)` 保证幂等。

- [ ] **Step 3：建立完整初始 schema**

`001_initial.sql` 必须包含：

```sql
CREATE TABLE users (
  id TEXT PRIMARY KEY,
  nickname TEXT NOT NULL,
  normalized_nickname TEXT NOT NULL UNIQUE,
  enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0,1)),
  last_seen_at INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE invite_codes (
  code_hash TEXT PRIMARY KEY,
  created_at INTEGER NOT NULL,
  consumed_by TEXT REFERENCES users(id),
  consumed_at INTEGER,
  CHECK ((consumed_by IS NULL) = (consumed_at IS NULL))
);

CREATE TABLE refresh_tokens (
  token_hash TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id),
  expires_at INTEGER NOT NULL,
  revoked_at INTEGER,
  created_at INTEGER NOT NULL
);

CREATE TABLE matches (
  id TEXT PRIMARY KEY,
  game_id TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('active','cancelled','finished','abandoned')),
  revision INTEGER NOT NULL DEFAULT 0,
  both_offline_since INTEGER,
  result TEXT,
  winner_user_id TEXT REFERENCES users(id),
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  finished_at INTEGER
);

CREATE TABLE match_players (
  match_id TEXT NOT NULL REFERENCES matches(id),
  user_id TEXT NOT NULL REFERENCES users(id),
  seat INTEGER NOT NULL CHECK (seat IN (0,1)),
  color TEXT NOT NULL CHECK (color IN ('black','white')),
  PRIMARY KEY (match_id, user_id),
  UNIQUE (match_id, seat),
  UNIQUE (match_id, color)
);

CREATE TABLE match_events (
  match_id TEXT NOT NULL REFERENCES matches(id),
  revision INTEGER NOT NULL,
  event_type TEXT NOT NULL,
  action_id TEXT,
  actor_user_id TEXT REFERENCES users(id),
  payload_json TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (match_id, revision),
  UNIQUE (match_id, actor_user_id, action_id)
);

CREATE TABLE active_game_slots (
  game_id TEXT NOT NULL,
  user_id TEXT NOT NULL REFERENCES users(id),
  match_id TEXT NOT NULL REFERENCES matches(id),
  PRIMARY KEY (game_id, user_id),
  UNIQUE (game_id, match_id, user_id)
);

CREATE TABLE launch_tickets (
  token_hash TEXT PRIMARY KEY,
  match_id TEXT NOT NULL REFERENCES matches(id),
  user_id TEXT NOT NULL REFERENCES users(id),
  game_id TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  consumed_at INTEGER,
  created_at INTEGER NOT NULL
);

CREATE TABLE resume_tokens (
  token_hash TEXT PRIMARY KEY,
  match_id TEXT NOT NULL REFERENCES matches(id),
  user_id TEXT NOT NULL REFERENCES users(id),
  expires_at INTEGER NOT NULL,
  last_used_at INTEGER NOT NULL,
  revoked_at INTEGER,
  created_at INTEGER NOT NULL
);
```

为 `match_events(match_id, revision)`、`launch_tickets(expires_at)`、`resume_tokens(expires_at)`、`matches(status, both_offline_since)` 增加索引。

- [ ] **Step 4：实现生产和测试时钟**

```go
type Clock interface { Now() time.Time }
type Real struct{}
func (Real) Now() time.Time { return time.Now().UTC() }
```

`Fake` 由 mutex 保护并提供 `Advance`；生产 HTTP 不得暴露修改时钟的路由。

- [ ] **Step 5：运行和提交**

```bash
cd server && go test ./internal/store ./internal/clock -race && cd ..
git add server/internal/store server/internal/clock
git commit -m "feat(server): add durable sqlite foundation"
```

### Task 7：邀请码注册与昵称规则

**Files:**
- Create: `server/internal/auth/tokens.go`
- Create: `server/internal/auth/service.go`
- Create: `server/internal/auth/service_test.go`
- Create: `server/internal/users/service.go`
- Create: `server/internal/users/service_test.go`

- [ ] **Step 1：先写昵称和邀请码事务失败测试**

覆盖：首尾空格去除；大小写不敏感唯一；2–16 个 Unicode rune；邀请码成功消费一次；昵称冲突时邀请码仍未消费；两个 goroutine 并发消费同一码只成功一个。

```go
func TestNicknameConflictDoesNotConsumeInvite(t *testing.T) {
    // create existing "Alice", create invite, register " alice "
    // assert ErrNicknameTaken and invite consumed_at remains NULL
}
```

Run: `cd server && go test ./internal/auth ./internal/users -run 'Test(Register|Nickname)' -race`。

Expected: services 未定义。

- [ ] **Step 2：实现令牌原语和昵称规范化**

`RandomToken(32)` 使用 `crypto/rand`；`HashToken(pepper, plaintext)` 返回十六进制 SHA-256。`NormalizeNickname` 使用 `strings.TrimSpace`、`strings.ToLower`、`utf8.RuneCountInString`，但保存原大小写的 trim 后显示名。

- [ ] **Step 3：实现原子注册**

在一个 `_txlock=immediate` 事务中依次验证邀请码未消费、插入用户、更新邀请码且带 `consumed_at IS NULL` 条件。任何错误都 rollback；受影响行数不是 1 视为 `invite_invalid`。

- [ ] **Step 4：运行全套测试并提交**

```bash
cd server && go test ./internal/auth ./internal/users -race && cd ..
git add server/internal/auth server/internal/users
git commit -m "feat(server): register users with one-time invites"
```

### Task 8：Access/refresh session 和自动轮换

**Files:**
- Modify: `server/internal/auth/service.go`
- Modify: `server/internal/auth/tokens.go`
- Modify: `server/internal/auth/service_test.go`
- Create: `server/internal/config/config.go`

- [ ] **Step 1：先写 session 失败测试**

覆盖：access JWT 含 `sub`、`iat`、`exp` 且 15 分钟过期；refresh token 30 天过期；数据库无明文；refresh 成功后旧 token 被 revoke、新 token 有效；已禁用用户无法 refresh；任何错误不回显 token。

- [ ] **Step 2：实现配置和 token issuer**

`config.Load()` 强制读取 `GAMEBOX_JWT_SECRET` 与 `GAMEBOX_TOKEN_PEPPER`，长度均至少 32 字节；读取 `GAMEBOX_ADDR`（默认 `127.0.0.1:8080`）和 `GAMEBOX_DB_PATH`（默认 `server/data/gamebox.db`）。测试直接构造配置，不读进程环境。

- [ ] **Step 3：实现 JWT 和 refresh rotation**

JWT 只允许 `HS256`，校验 issuer `gamebox`。refresh 在一个事务内 revoke 旧摘要并插入新摘要；并发 refresh 只有一个成功。

- [ ] **Step 4：运行和提交**

```bash
cd server && go test ./internal/auth ./internal/config -race && cd ..
git add server/internal/auth server/internal/config
git commit -m "feat(server): issue and rotate user sessions"
```

### Task 9：Go 游戏注册表和五子棋纯规则

**Files:**
- Create: `server/internal/games/rules.go`
- Create: `server/internal/games/registry.go`
- Create: `server/internal/games/gomoku/board.go`
- Create: `server/internal/games/gomoku/rules.go`
- Create: `server/internal/games/gomoku/rules_test.go`

- [ ] **Step 1：先写规则表驱动失败测试**

覆盖 15×15 初始棋盘、越界、占用格、非当前玩家、横/竖/两条斜线、恰好五连、六连也获胜、225 格无五连和棋。和棋盘使用确定公式 `black = ((x + 2*y) % 4) < 2`，它产生 113 黑/112 白且四个方向最长同色连续为 2；测试按黑白位置交替填充并把一个黑格留作第 225 步。测试显式验证规则没有禁手分支。

```go
tests := []struct {
    name string
    stones []Stone
    move Point
    wantWinner Color
}{
    {
        name: "horizontal five",
        stones: []Stone{{X: 3, Y: 7, Color: Black}, {X: 4, Y: 7, Color: Black},
            {X: 5, Y: 7, Color: Black}, {X: 6, Y: 7, Color: Black}},
        move: Point{X: 7, Y: 7}, wantWinner: Black,
    },
    {
        name: "descending diagonal",
        stones: []Stone{{X: 3, Y: 3, Color: Black}, {X: 4, Y: 4, Color: Black},
            {X: 5, Y: 5, Color: Black}, {X: 6, Y: 6, Color: Black}},
        move: Point{X: 7, Y: 7}, wantWinner: Black,
    },
    {
        name: "overline wins",
        stones: []Stone{{X: 2, Y: 8, Color: Black}, {X: 3, Y: 8, Color: Black},
            {X: 4, Y: 8, Color: Black}, {X: 5, Y: 8, Color: Black},
            {X: 6, Y: 8, Color: Black}},
        move: Point{X: 7, Y: 8}, wantWinner: Black,
    },
}
```

Run: `cd server && go test ./internal/games/gomoku -v`。

Expected: package 未实现。

- [ ] **Step 2：实现纯规则引擎**

棋盘内部用 `[225]uint8`；坐标索引为 `y*15+x`。落子后只沿 `(1,0)`、`(0,1)`、`(1,1)`、`(1,-1)` 双向计数，`>=5` 即胜。规则函数不访问 SQL、网络或时钟。

- [ ] **Step 3：实现平台窄接口**

```go
type Rules interface {
    GameID() string
    PlayerLimit() int
    Rebuild(events []Event) (Snapshot, error)
    Apply(snapshot Snapshot, actorID string, action Action) (Event, Snapshot, error)
}
```

注册表只注册 `gomoku.NewRules()`；`PlayerLimit` 和“一人一局”仍由 Gomoku 模块提供，不硬编码成平台全局策略。

- [ ] **Step 4：运行和提交**

```bash
cd server && go test ./internal/games/... -race && cd ..
git add server/internal/games
git commit -m "feat(server): implement authoritative gomoku rules"
```

### Task 10：原子创建、随机颜色、单局槽位与零步取消

**Files:**
- Create: `server/internal/matches/models.go`
- Create: `server/internal/matches/service.go`
- Create: `server/internal/matches/service_test.go`

- [ ] **Step 1：先写 match service 失败测试**

覆盖：选择自己失败；任一用户禁用失败；双方空闲时创建一局并恰好写两个 slot；颜色一黑一白；注入的 `io.Reader` 控制随机结果；发起人或对手已有局时完整 rollback；两个 goroutine 争抢同一用户只有一个成功；0 步任一方取消并释放两个 slot；有首步后不能取消。

- [ ] **Step 2：定义服务依赖和随机接口**

```go
type Service struct {
    db *sql.DB
    games *games.Registry
    clock clock.Clock
    random io.Reader
}
```

生产使用 `crypto/rand.Reader`。颜色用单随机 bit 决定，不使用 `math/rand`。

- [ ] **Step 3：实现单事务创建**

顺序固定：查询双方 → 检查启用状态 → 插入 match → 插入 players → 插入两个 `active_game_slots`。依靠 `(game_id,user_id)` 主键解决并发，唯一约束映射为 `opponent_busy` 或 `active_match_exists`，其他 SQL 错误不得伪装成 busy。

- [ ] **Step 4：实现零步取消**

同一事务检查调用方是玩家、`status=active`、不存在任何 `gomoku.move.accepted`，追加 `platform.match.cancelled` 事件并递增 revision，更新终态，再删除两个 slot。取消不设置 winner/result。

- [ ] **Step 5：运行和提交**

```bash
cd server && go test ./internal/matches -run 'Test(Create|Cancel)' -race && cd ..
git add server/internal/matches
git commit -m "feat(server): create and cancel exclusive matches"
```

### Task 11：动作幂等、事件持久化、胜负和认输

**Files:**
- Modify: `server/internal/matches/models.go`
- Modify: `server/internal/matches/service.go`
- Modify: `server/internal/matches/service_test.go`

- [ ] **Step 1：先写权威动作失败测试**

覆盖：黑方先行；错误轮次；占用格；旧 revision；合法落子把 event 和 revision 一起提交；相同用户+actionId+相同 payload 重试返回已提交结果；同 actionId 不同 payload 返回 `action_conflict`；五连在同一事务结束并释放 slots；满盘和棋释放 slots；首步前不能认输；首步后认输使对方获胜。

- [ ] **Step 2：实现事件重放和快照**

`Snapshot(matchID)` 读取 match、players、按 revision 排序的 events，并调用 `gomoku.Rules.Rebuild`。不要在 `matches` 表保存第二份棋盘 JSON。最多 225 步，首版重放成本可控。

- [ ] **Step 3：实现 revision 和 actionId 幂等语义**

单事务顺序：读取 match revision → 先按 `(match_id,actor_user_id,action_id)` 查旧事件 → 若存在则比较规范化 payload → 验证 `expectedRevision` → 规则计算 → 插入事件 → CAS 更新 `matches WHERE revision=?`。只有 commit 成功后才返回可广播事件。

- [ ] **Step 4：实现终局和 slot 释放**

胜、和、认输都在写事件的同一事务更新 `status='finished'`、`result`、`winner_user_id`、`finished_at` 并删除双方 slots。`result` 只允许 `five`、`resignation`、`draw`；和棋 winner 为 NULL。

- [ ] **Step 5：证明写失败不产生假事件**

测试通过关闭数据库连接或触发约束失败，断言 service 不返回广播事件、revision 不变。Hub 在本任务仍不实现。

- [ ] **Step 6：运行和提交**

```bash
cd server && go test ./internal/matches ./internal/games/... -race && cd ..
git add server/internal/matches
git commit -m "feat(server): persist authoritative match actions"
```

### Task 12：连接存在性、45 秒超时和双方离线 24 小时作废

**Files:**
- Create: `server/internal/matches/presence.go`
- Create: `server/internal/matches/presence_test.go`
- Modify: `server/internal/matches/service.go`
- Modify: `server/internal/matches/service_test.go`

- [ ] **Step 1：先写注入时钟的失败测试**

覆盖：单方断线不开始计时；双方最后一条连接都离开时设置 `both_offline_since`；任一方重连立即清空；23:59:59 不作废；24:00:00 作废且无 winner/result、释放 slots；已结束对局不变化；同一用户的旧连接关闭不覆盖新连接。

- [ ] **Step 2：实现进程内连接计数**

`Presence` 的 key 为 `(matchID,userID,connectionID)`，mutex 下维护 `lastSeen`。每条有效消息或 pong 更新连接；worker 每 15 秒删除超过 45 秒的连接，并只在“玩家是否在线”的边界变化时调用持久化 service。

- [ ] **Step 3：实现离线边界事务**

`SetPlayerOnline` 清空 active match 的 `both_offline_since`。`SetPlayerOffline` 只有确认双方连接数都为 0 时用 `COALESCE(both_offline_since, now)` 设置时间。Presence 先计算状态，service 再检查 match 仍 active，避免终局后回写。

- [ ] **Step 4：实现过期扫描和启动恢复**

`AbandonExpired(ctx)` 选择 `status='active' AND both_offline_since <= now-24h`，逐局事务追加 `platform.match.abandoned`、递增 revision、终止并释放 slots。`MarkActiveMatchesOfflineOnBoot(ctx)` 只为 NULL 的 active match 设置当前时间，保留服务重启前已经开始的计时。

- [ ] **Step 5：运行和提交**

```bash
cd server && go test ./internal/matches -run 'Test(Presence|Abandon|Boot)' -race && cd ..
git add server/internal/matches
git commit -m "feat(server): expire fully offline matches"
```

### Task 13：HTTP 身份、大厅、选人和 launch ticket API

**Files:**
- Create: `server/internal/httpapi/errors.go`
- Create: `server/internal/httpapi/router.go`
- Create: `server/internal/httpapi/auth_handlers.go`
- Create: `server/internal/httpapi/game_handlers.go`
- Create: `server/internal/httpapi/event_publisher.go`
- Create: `server/internal/httpapi/router_test.go`
- Modify: `server/internal/auth/service.go`
- Modify: `server/internal/matches/service.go`

- [ ] **Step 1：先写 httptest 失败测试**

覆盖以下接口和状态码：

```text
POST   /v1/auth/register                 201
POST   /v1/auth/refresh                  200
GET    /v1/me                            200
GET    /v1/games                         200
GET    /v1/games/gomoku/status           200
GET    /v1/games/gomoku/opponents        200
POST   /v1/games/gomoku/matches          201
DELETE /v1/matches/{matchId}             204
POST   /v1/matches/{matchId}/launch-ticket 201
GET    /healthz                          200
```

另外测试：JSON body 超 64 KiB 拒绝；未知字段拒绝；未认证 401；busy 409；昵称冲突 409；无效邀请码 422；响应与 request log 不含令牌。

- [ ] **Step 2：实现统一 router/middleware**

使用 Go 1.25 `http.ServeMux` method patterns，不引入额外 router。middleware 生成 request ID、recover panic、限制 body、设置 JSON content type、验证 Bearer JWT，并在成功认证请求时更新 `users.last_seen_at`。Router 接受窄接口 `MatchEventPublisher.Publish(matchID, event)`；HTTP 取消事务提交后发布事件，测试注入 recorder，不能让 handler 直接依赖具体 WebSocket Hub。

- [ ] **Step 3：实现状态和对手响应**

`GET /v1/games/gomoku/status` 返回二选一：

```json
{"state":"idle"}
```

或：

```json
{"state":"active","match":{"id":"11111111-1111-4111-8111-111111111111","opponent":{"id":"22222222-2222-4222-8222-222222222222","nickname":"Alice"},"color":"black","revision":3}}
```

对手列表包含除自己外所有 enabled 用户：`availability` 为 `idle` 或 `busy`，`presence` 为 `online` 或 `offline`。busy 不可选，offline+idle 可选。online 由 `last_seen_at >= now-90s` 决定。

- [ ] **Step 4：实现单次 launch ticket**

只有对局参与者且 match active 才能创建；有效期 60 秒，数据库存摘要。响应仅返回一次明文：

```json
{"matchId":"11111111-1111-4111-8111-111111111111","gameId":"gomoku","launchTicket":"test-launch-ticket","expiresAt":1787119263000}
```

- [ ] **Step 5：运行和提交**

```bash
cd server && go test ./internal/httpapi -race && cd ..
git add server/internal/httpapi server/internal/auth server/internal/matches
git commit -m "feat(server): expose auth and lobby http api"
```

### Task 14：WebSocket 握手、快照、心跳、恢复与广播

**Files:**
- Create: `server/internal/matches/hub.go`
- Modify: `server/internal/matches/presence.go`
- Modify: `server/internal/httpapi/router.go`
- Modify: `server/internal/httpapi/router_test.go`
- Modify: `server/internal/protocol/messages.go`
- Create: `server/internal/testutil/client.go`

- [ ] **Step 1：先写两个真实 WebSocket 客户端的失败测试**

覆盖：首消息必须是 `platform.connect`；launch ticket 只能消费一次；ticket 与 user/match/game 绑定；成功后第一条业务消息为完整 snapshot；返回 resume token；动作 commit 后双方才收到同 revision 事件；旧 revision 收到 `stale_revision` 和最新 snapshot；断连用 resume token 恢复；30 分钟滑动过期；终局 revoke resume tokens。

- [ ] **Step 2：实现连接消息，避免 URL 泄密**

HTTP 只暴露 `GET /v1/ws`，ticket 不放 query string。客户端升级后 5 秒内发送：

```json
{"protocolVersion":1,"type":"platform.connect","payload":{"launchTicket":"test-launch-ticket"}}
```

或 `resumeToken`，两者必须恰好一个。消费 launch ticket 和签发 resume token 在同一事务；resume 每次成功使用把 `last_used_at` 与 `expires_at=now+30m` 滑动更新。

- [ ] **Step 3：实现每局 Hub**

Hub 实现 Task 13 的 `MatchEventPublisher`，只负责连接、顺序发送和 presence，不执行业务规则。读循环把动作交给 `matches.Service`；收到 service 已提交事件后调用同一个 `Publish` 广播，HTTP 零步取消也走该入口。每连接有有界发送队列，慢客户端队列满则关闭该连接，不阻塞另一玩家。

- [ ] **Step 4：实现应用层心跳**

server 每 15 秒发送 `platform.ping`；client 回复 `platform.pong`。任何合法消息更新 lastSeen，45 秒无活动关闭连接。关闭路径必须幂等且触发 Presence 的 connectionID 删除。

- [ ] **Step 5：实现重连顺序**

每次连接先在 Hub 注册，再获取一个一致快照。`platform.connected` payload 固定为 `userId`、`connectionId`、`resumeToken`、`resumeExpiresAt`；随后发送 `platform.snapshot`，之后才允许增量广播进入该连接。Godot 用 `userId` 和 snapshot 的黑白玩家 ID 确定本方颜色。若并发动作发生，使用 revision 检查补发新 snapshot，不能产生缺口。

- [ ] **Step 6：运行和提交**

```bash
cd server && go test ./internal/httpapi ./internal/matches -run 'Test(WebSocket|Hub|Resume)' -race && cd ..
git add server/internal/httpapi server/internal/matches server/internal/protocol server/internal/testutil
git commit -m "feat(server): stream authoritative matches over websocket"
```

### Task 15：全链路服务端集成测试和进程重启恢复

**Files:**
- Create: `server/internal/testutil/server.go`
- Create: `server/internal/httpapi/e2e_test.go`
- Modify: `server/internal/testutil/client.go`

- [ ] **Step 1：写完整 happy-path 失败测试**

在临时 SQLite 上启动真实 `httptest.Server`：生成两个邀请码 → HTTP 注册两人 → A 选择 B → 两边取票并连 WS → 根据实际随机颜色完成五连 → 断言相同结果 → HTTP status 均回到 idle → 可以再创建一局。

- [ ] **Step 2：写中途重启失败测试**

完成三步后关闭第一个 server 和 DB，使用同一 DB 路径创建第二个 service/router，调用 boot recovery；两端使用新 launch ticket 重连，快照必须含三步和相同 revision，再完成对局。

- [ ] **Step 3：写失败路径集成测试**

覆盖：两个发起者并发争同一对手、落子 DB 失败不广播、resume token 过期、任一方重连清除 24 小时计时、服务重启保留原有 `both_offline_since`。

- [ ] **Step 4：运行完整 race 测试并提交**

```bash
cd server && go test ./... -race -count=1 && cd ..
git add server/internal/httpapi server/internal/testutil
git commit -m "test(server): cover durable two-player match flow"
```

### Task 16：可运行服务、邀请码 CLI 和只读 E2E 查询

**Files:**
- Create: `server/cmd/gameboxd/main.go`
- Create: `server/cmd/gameboxctl/main.go`
- Create: `server/cmd/gameboxctl/main_test.go`
- Modify: `README.md`

- [ ] **Step 1：先写 CLI 失败测试**

覆盖 `invite create --count 2 --json` 只输出两个不同明文一次、数据库仅有摘要；count 非 1–1000 拒绝；`match show --id 11111111-1111-4111-8111-111111111111 --json` 只读返回玩家颜色、revision、状态和 225 格棋盘；未知 match 非零退出。

- [ ] **Step 2：实现 `gameboxd` 生命周期**

启动顺序固定：load config → open/migrate DB → mark active matches offline on boot → build services/router → start presence/abandon workers → listen。接收 SIGINT/SIGTERM 后停止接入、给 HTTP 10 秒 graceful shutdown、关闭 workers/DB。日志为 JSON 行，包含 request/connection/match ID 但不含秘密。

- [ ] **Step 3：实现管理 CLI**

```bash
(cd server && go run ./cmd/gameboxctl invite create --count 2 --db /tmp/gamebox.db --json)
gamebox_match_id='11111111-1111-4111-8111-111111111111'
(cd server && go run ./cmd/gameboxctl match show --id "$gamebox_match_id" --db /tmp/gamebox.db --json)
```

`invite create` 复用 `auth.RandomToken/HashToken`；`match show` 复用 snapshot 重放，不复制规则。

- [ ] **Step 4：本机进程烟测**

```bash
export GAMEBOX_JWT_SECRET='local-dev-jwt-secret-at-least-32-bytes'
export GAMEBOX_TOKEN_PEPPER='local-dev-token-pepper-at-least-32-bytes'
tmp_gamebox_server=$(mktemp -d)
export GAMEBOX_DB_PATH="$tmp_gamebox_server/gamebox.db"
(cd server && go build -o "$tmp_gamebox_server/gameboxd" ./cmd/gameboxd)
"$tmp_gamebox_server/gameboxd" &
gamebox_server_pid=$!
curl --fail --silent http://127.0.0.1:8080/healthz
kill -TERM "$gamebox_server_pid"
wait "$gamebox_server_pid"
```

Expected: healthz 为 `{"status":"ok"}`，TERM 后 exit 0。

- [ ] **Step 5：运行和提交**

```bash
cd server && go test ./... -race && go vet ./... && cd ..
git add server/cmd README.md
git commit -m "feat(server): add daemon and invite management cli"
```

**Phase 2 Gate:** `cd server && go test ./... -race -count=1 && go vet ./...` 全绿；真实进程 health/shutdown 通过；中途重启集成测试必须使用同一 SQLite 文件而不是 mock。

## Phase 3：接上 Flutter、Godot 和双模拟器验收

### Task 17：Flutter API、注册和自动登录

**Files:**
- Create: `app/lib/core/api/api_error.dart`
- Create: `app/lib/core/api/api_client.dart`
- Create: `app/lib/core/auth/session.dart`
- Create: `app/lib/core/auth/token_store.dart`
- Create: `app/lib/features/auth/auth_api.dart`
- Create: `app/lib/features/auth/session_controller.dart`
- Create: `app/lib/features/auth/registration_page.dart`
- Create: `app/test/features/auth/session_controller_test.dart`
- Create: `app/test/features/auth/registration_page_test.dart`
- Modify: `app/lib/app.dart`
- Modify: `app/pubspec.yaml`, `app/pubspec.lock`

- [ ] **Step 1：先写 controller 失败测试**

使用内存 `TokenStore` 和 fake `AuthApi` 覆盖：无 refresh token 显示注册；有效 token 自动 refresh 后进入 authenticated；无效 token 被删除并回注册；注册成功保存 refresh token；注册失败不保存；controller dispose 后不发通知。

- [ ] **Step 2：实现 API 基础层**

API 基址只从：

```dart
const apiBaseUrl = String.fromEnvironment(
  'GAMEBOX_API_BASE_URL',
  defaultValue: 'http://10.0.2.2:8080',
);
```

`ApiClient` 设置 10 秒 timeout、编码/解码 JSON、把统一错误外壳转为 `ApiError(code,message)`。错误对象不保存原始 token。`TokenStore` 接口的 Android 实现用 `flutter_secure_storage`，key 固定为 `gamebox.refresh_token.v1`。

- [ ] **Step 3：实现 session 状态机**

状态只允许 `restoring`、`unauthenticated`、`submitting`、`authenticated`。access token 只保存在内存；refresh 成功轮换后立即覆盖安全存储。收到任意 401 时只允许串行执行一次 refresh，其余请求等待同一个 Future；refresh 失败清空 session。

- [ ] **Step 4：先写注册 Widget 失败测试**

验证邀请码/昵称输入、昵称少于 2 rune 的本地提示、提交中禁用按钮、`invite_invalid`/`nickname_taken` 的中文提示、成功进入 Home shell。所有可交互控件添加稳定 Semantics label：`invite-code`、`nickname`、`register`。

- [ ] **Step 5：实现注册页和 App 路由**

使用 Material 3 和标准 `Navigator`，不引入状态管理或路由框架。恢复 session 时显示 splash/progress；未认证只显示注册页；认证后创建 Home shell。App 生命周期恢复时若 access token 已过期，先 refresh。

- [ ] **Step 6：运行和提交**

```bash
cd app && flutter analyze && flutter test && cd ..
git add app/lib app/test app/pubspec.*
git commit -m "feat(flutter): add invite registration and sessions"
```

### Task 18：Flutter 游戏目录、活跃局、对手选择和启动

**Files:**
- Create: `app/lib/features/home/game_catalog.dart`
- Create: `app/lib/features/home/home_api.dart`
- Create: `app/lib/features/home/home_controller.dart`
- Create: `app/lib/features/home/home_page.dart`
- Create: `app/lib/features/home/opponent_page.dart`
- Create: `app/lib/features/gomoku/gomoku_models.dart`
- Create: `app/lib/features/gomoku/gomoku_repository.dart`
- Create: `app/test/features/home/home_controller_test.dart`
- Create: `app/test/features/home/home_page_test.dart`
- Create: `app/test/features/home/opponent_page_test.dart`
- Modify: `app/lib/app.dart`

- [ ] **Step 1：先写目录和 Home 状态失败测试**

验证 `GameCatalog` 只有 `gomoku`；idle 卡片显示“选择对手”；active 卡片显示对手、颜色和“继续对局”；active 时不渲染新建入口；返回 foreground 或 Godot Activity 后立即刷新；前台每 10 秒轮询，dispose 后停止。

- [ ] **Step 2：实现目录和 controller**

```dart
const games = [GameDescriptor(
  id: 'gomoku', title: '五子棋', playerCount: 2,
)];
```

controller 所有异步动作使用一次性 operation token 防止旧响应覆盖新状态。Home API 明确建模 idle/active union，不用动态 Map 穿透 UI。

- [ ] **Step 3：先写对手页失败测试**

验证：排除自己；busy 行显示“游戏中”且禁用；offline+idle 显示“离线 · 可邀请”且可点；点击后按钮 loading；409 `opponent_busy` 返回列表并提示；并发双击只发一个请求。

- [ ] **Step 4：实现创建/继续的统一启动函数**

`openMatch(matchId)` 固定：请求 launch ticket → 构造 `GameLaunchRequest` → `await gameLauncher.launch`。该 Future 只表示 Android 已成功启动 Activity，不假装等待另一个进程结束；Flutter 的 `AppLifecycleState.resumed` 回调负责在 Godot 退出后刷新 Home。创建对局成功先得到 match ID 再调用同一函数。WebSocket URL 由 API base URL 只替换 scheme 并追加 `/v1/ws`。

- [ ] **Step 5：实现取消入口**

active 且 revision 为 0 时 Home 显示“取消未开始对局”；DELETE 成功后刷新为 idle。revision > 0 时不显示取消。取消失败使用服务端错误，不本地猜测步数。

- [ ] **Step 6：稳定 E2E 语义标记**

添加：`game-gomoku`、`choose-opponent`、`opponent-<userId>`、`continue-match`、`cancel-match`。测试断言语义存在；不要按中文文案驱动 E2E。

- [ ] **Step 7：运行和提交**

```bash
cd app && flutter analyze && flutter test && cd ..
git add app/lib app/test
git commit -m "feat(flutter): add gomoku lobby and opponent flow"
```

### Task 19：Godot 权威状态、WebSocket 和有界重连

**Files:**
- Create: `game_runtime/games/gomoku/gomoku_state.gd`
- Create: `game_runtime/core/match_client.gd`
- Create: `game_runtime/test/test_gomoku_state.gd`
- Create: `game_runtime/test/test_match_client.gd`
- Modify: `game_runtime/core/protocol.gd`
- Modify: `game_runtime/test/run_tests.gd`

- [ ] **Step 1：先写纯状态 reducer 失败测试**

覆盖：snapshot 还原 225 格、颜色/轮次/结果；revision 相同或更旧事件忽略；恰好 `current+1` 应用；有 gap 时返回 `needs_snapshot`；已确认 actionId 清除 pending；错误事件不改变棋盘；本地点击不能直接写棋盘。

- [ ] **Step 2：实现 `GomokuState`**

状态只有服务端消息可以修改。对外提供 `can_request_move(x,y,localUserId)`，只做 UI 预检查；`mark_pending(actionId,x,y)` 只保存 pending marker，不放棋子。

- [ ] **Step 3：先写可替换 transport 的连接状态机测试**

用 fake transport 覆盖：launch ticket 首连；收到 connected 保存内存 resume token；断线按 1/2/4/8/15 秒退避；重连用 resume token；第 6 次连续失败停止并提示返回大厅；`resume_expired` 立即结束；gap 请求 snapshot；未确认动作不自动重放。

- [ ] **Step 4：实现 `MatchClient`**

生产 transport 包装 `WebSocketPeer`。状态为 `connecting/connected/reconnecting/failed/closed`；每帧 poll，解析文本消息；收到 ping 立即 pong；resume token 只保存在 `:game` 进程内存。退出 Activity 后 Flutter 重新取 launch ticket，不把 resume token传回或落盘。

- [ ] **Step 5：实现动作发送**

每个动作使用新的 UUID v4：Godot 用 `Crypto.generate_random_bytes(16)`，将 byte 6 写为 `(value & 0x0f) | 0x40`、byte 8 写为 `(value & 0x3f) | 0x80`，再按 `8-4-4-4-12` 十六进制格式化；发送顶层 `expectedRevision=state.revision`。同一 pending action 未确认时禁用新的落子/认输输入。

- [ ] **Step 6：运行和提交**

```bash
bash tool/verify_fast.sh
git add game_runtime
git commit -m "feat(godot): sync authoritative match state"
```

### Task 20：Godot 五子棋棋盘和对局 UI

**Files:**
- Create: `game_runtime/games/gomoku/gomoku_board.gd`
- Modify: `game_runtime/games/gomoku/gomoku_controller.gd`
- Modify: `game_runtime/games/gomoku/gomoku_scene.tscn`
- Create: `game_runtime/test/test_gomoku_board.gd`
- Create: `game_runtime/test/test_gomoku_scene.gd`
- Modify: `game_runtime/test/run_tests.gd`

- [ ] **Step 1：先写棋盘坐标失败测试**

以 1080×1920 设计画布和固定正方形 board rect 为输入，覆盖四角、中心、半格外点击拒绝、不同 viewport stretch 下坐标一致。`pixel_to_cell` 与 `cell_to_pixel` 必须互为近似逆。

- [ ] **Step 2：实现绘制和输入 Control**

`GomokuBoard` 自绘 15 条横纵线、星位、黑白棋子、最后落子和 pending marker。只发 `cell_pressed(x,y)` signal，不持有网络。触控采用 `_gui_input`，一指松开才提交一次。

- [ ] **Step 3：先写场景状态失败测试**

实例化场景并注入 fake MatchClient，验证连接中、轮到我/对方、重连中、错误、胜/负/和、abandoned 文案；首步后显示认输；终局显示“返回大厅”；普通返回按钮不发送认输。

- [ ] **Step 4：实现 controller**

controller 读取 `LaunchConfig`、创建 MatchClient、把 snapshot/events 应用到 state 后刷新 board。非法落子显示服务端 code 对应中文；`stale_revision` 等待随附 snapshot。返回大厅调用 `get_tree().quit()`，依靠 `:game` 进程隔离回到 Flutter。

- [ ] **Step 5：增加无秘密日志标记**

只输出 `GAMEBOX_GODOT_READY game=gomoku match=<id>`、revision 和连接状态；不输出 ticket/resume token。终局输出 `GAMEBOX_MATCH_RESULT match=<id> result=<result>` 供设备烟测读取。

- [ ] **Step 6：运行 Godot、Android 打包测试并提交**

```bash
bash tool/verify_fast.sh
cd app && flutter build apk --debug \
  --dart-define=GAMEBOX_API_BASE_URL=http://10.0.2.2:8080 && cd ..
unzip -l app/build/app/outputs/flutter-apk/app-debug.apk | rg 'gomoku_scene|gomoku_board'
git add game_runtime
git commit -m "feat(godot): render playable gomoku match"
```

### Task 21：双模拟器可重复 E2E

**Files:**
- Create: `tool/ensure_test_avds.sh`
- Create: `tool/e2e_android.sh`
- Create: `app/integration_test/semantics_test.dart`
- Modify: `app/pubspec.yaml`, `app/pubspec.lock`
- Modify: `.gitignore`

- [ ] **Step 1：先写 Flutter 语义契约测试**

增加 SDK `integration_test` dev dependency。测试启动 fake API，逐页断言 Task 17/18 的 Semantics labels 存在且可点击，避免 E2E 脚本依赖坐标定位 Flutter 表单。

Run: `cd app && flutter test integration_test/semantics_test.dart`。

Expected: 任一漏标记时失败。

- [ ] **Step 2：实现专用 AVD 准备脚本**

默认只管理 `Gamebox_A_API_36` 和 `Gamebox_B_API_36`，系统镜像固定 `system-images;android-36;google_apis_playstore_ps16k;arm64-v8a`，设备固定 `pixel_7_pro`。若 AVD 不存在才创建；不删除或覆盖其他 AVD。默认使用空闲端口 5560/5562；端口占用时明确失败，不杀无关 emulator。

允许用户传已有设备：

```bash
GAMEBOX_E2E_SERIAL_A=emulator-5554 \
GAMEBOX_E2E_SERIAL_B=emulator-5556 \
bash tool/e2e_android.sh
```

传 serial 时不创建、不 wipe、不重启设备。

- [ ] **Step 3：实现 E2E 服务和数据准备**

脚本用 `mktemp -d` 建隔离 DB/日志，trap 只终止自己启动的 server/emulator。启动 `gameboxd` 后等待 healthz；调用 `gameboxctl invite create --count 2 --json`，不得把邀请码写入提交的 artifact 或普通日志。

- [ ] **Step 4：实现构建、安装和 Flutter UI 驱动**

构建一次 debug APK，两个设备都 `pm clear me.zqydev.gamebox` 后安装。通过 `uiautomator dump` 找 content-desc，再用 `adb shell input text/tap`：两端注册唯一用户；A 打开对手页并选择 B；B 等轮询看到 active 后点继续。每个等待都有 30 秒 deadline 和失败截图。

- [ ] **Step 5：按实际颜色驱动 Godot**

用只读命令：

```bash
(cd server && go run ./cmd/gameboxctl match show \
  --id "$gamebox_match_id" --db "$gamebox_db_path" --json)
```

确定哪个 serial 是黑方。根据 `wm size` 和 Task 20 固定 board rect 计算 Android tap 坐标。黑方依次下 `(3,3)…(7,3)`，白方填 `(3,5)…(6,5)`；每次点击后轮询 CLI，只有 revision 增加且两端截图棋盘一致才进行下一步。

- [ ] **Step 6：中途强停和恢复**

第三步后只对一端运行 `am force-stop me.zqydev.gamebox`，确认服务端事件未丢；重新启动 Flutter，自动登录，点 `continue-match`，确认 Godot snapshot revision 与 CLI 一致，然后继续。

- [ ] **Step 7：验证终局和槽位释放**

第五颗黑棋后，CLI 必须显示 `finished/five` 和正确 winner；两端 logcat 都有相同 match/result。点击“返回大厅”，等待双方 Home 为 idle，再由 A 选择 B 创建第二局，证明两个 slot 已释放；第二局 0 步取消，证明取消链路可用。

- [ ] **Step 8：保存非敏感证据**

写到 `artifacts/e2e/<UTC timestamp>/`：`summary.json`、两端关键截图、去秘密的 server log、最终 match JSON。`summary.json` 包含 app commit、设备 serial/API、match ID、恢复前后 revision 和所有断言；不得包含任何 token/invite。

- [ ] **Step 9：运行并提交 harness**

```bash
bash tool/e2e_android.sh
git add tool/ensure_test_avds.sh tool/e2e_android.sh \
  app/integration_test app/pubspec.* .gitignore
git commit -m "test(android): add two-emulator playable loop"
```

### Task 22：CI、统一完成门槛和开发文档

**Files:**
- Create: `.github/workflows/ci.yml`
- Modify: `tool/verify_fast.sh`
- Modify: `tool/verify.sh`
- Modify: `README.md`

- [ ] **Step 1：先让统一验证暴露缺口**

`tool/verify.sh` 依次运行 `bootstrap.sh`、`verify_fast.sh`、Kotlin unit tests、Flutter debug APK build、APK Godot 资源断言。执行并确认在 CI 尚未配置前本地功能检查已经完整。

- [ ] **Step 2：实现固定版本 CI**

`ci.yml` 使用 `ubuntu-latest`，权限 `contents: read`，步骤固定为：

```yaml
- uses: actions/checkout@v6
- uses: actions/setup-go@v6
  with:
    go-version-file: server/go.mod
    cache-dependency-path: server/go.sum
- uses: actions/setup-java@v5
  with:
    distribution: temurin
    java-version: '17'
    cache: gradle
- uses: subosito/flutter-action@v2
  with:
    flutter-version: '3.35.1'
    channel: stable
    cache: true
- uses: chickensoft-games/setup-godot@v2
  with:
    version: '4.7.0'
    use-dotnet: false
```

然后运行 `bash tool/verify.sh`。CI 不运行模拟器；双模拟器保留为本机 release gate。

- [ ] **Step 3：完成 README**

文档必须包含：架构边界；依赖版本；`bootstrap/verify/e2e` 三条命令；本机 server env；生成邀请码；启动服务；Android `10.0.2.2` 原因；数据文件位置；不记录秘密要求；本期范围与 F2–F5 继续指令。

- [ ] **Step 4：执行全套本机完成门槛**

```bash
bash tool/verify.sh
bash tool/e2e_android.sh
git diff --check
git status --short
```

Expected: 自动测试、静态分析、Android build、APK 资源检查和双模拟器 E2E 全部 PASS；只有预期文档/CI 变更未提交。

- [ ] **Step 5：提交并检查提交范围**

```bash
git add .github/workflows/ci.yml tool/verify_fast.sh tool/verify.sh README.md
git commit -m "ci: enforce gamebox playable loop checks"
git status --short
git log --oneline --decorate -12
```

Expected: working tree clean；不 push，除非用户明确要求。

## 最终验收清单

- [ ] 未登录无法进入大厅；两个一次性邀请码只能分别成功注册一次。
- [ ] 昵称 trim 后 2–16 rune，忽略大小写全局唯一；冲突不消费邀请码。
- [ ] Home 在 idle/active 间正确切换；busy 对手不可选，offline+idle 可选。
- [ ] 并发创建时一个用户在 Gomoku 中最多有一个 active slot。
- [ ] 15×15 freestyle、随机黑白、黑先、五连或长连胜、满盘和、首步后认输全部由 Go 判定。
- [ ] 每个 accepted action 先持久化再广播；actionId 幂等；revision gap 触发 snapshot。
- [ ] App/Godot 退出不是认输；单方离线不计时；双方连续离线 24 小时才 abandoned。
- [ ] 服务重启后恢复棋步和 revision；任一方重连清空双方离线时间。
- [ ] Flutter → `:game` GodotActivity → Flutter 可重复两次，无主进程死亡。
- [ ] 双模拟器真实完成注册、选人、随机颜色对局、强停恢复、五连、槽位释放和新局取消。
- [ ] artifacts 和日志无邀请码、access/refresh/launch/resume token。
- [ ] `bash tool/verify.sh` 与 CI 通过；`bash tool/e2e_android.sh` 本机通过。

## 实施时的官方参考

- Godot Android Library：<https://docs.godotengine.org/en/stable/tutorials/platform/android/android_library.html>
- Godot Android 导出/JDK：<https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_android.html>
- Godot 4.7 AAR：<https://central.sonatype.com/artifact/org.godotengine/godot/4.7.0.stable>
- Flutter 从 MethodChannel 启动原生 Activity：<https://docs.flutter.dev/platform-integration/android/compose-activity>
- coder/websocket：<https://pkg.go.dev/github.com/coder/websocket>
- modernc SQLite：<https://pkg.go.dev/modernc.org/sqlite>
