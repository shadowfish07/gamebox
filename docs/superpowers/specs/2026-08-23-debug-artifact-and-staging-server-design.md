# Debug 包滚动发布 + Staging 服务端设计

Date: 2026-08-23
Status: Validated

## Goal

为 Gamebox 建立一条 debug 包的分发链路：

1. 每次 push 到 `main` 自动构建一个**独立包名**的 debug APK，发布到固定的滚动
   pre-release，测试者通过恒定链接拿到最新版。
2. 单独部署一个 **staging 服务端**，与正式服同机并存、数据与密钥完全隔离，
   debug 包指向它，避免 debug 流量污染正式服数据。
3. debug 包名与正式版互不冲突，可在同一台设备上并存安装。

## Decisions

| 问题 | 决策 |
|---|---|
| Debug 包发布方式 | 每次 push 到 `main` 自动构建 → 滚动 pre-release（固定 tag `debug-latest`，APK/校验文件按完整 SHA 使用不可变资产名；上传成功后再移动 tag 和更新说明） |
| 包名后缀范围 | 仅 CI 发布的包加 `.debug`（通过 `GAMEBOX_DEBUG_ARTIFACT` 环境变量控制），本地 `flutter run`、`verify.sh`、smoke/E2E 脚本零影响 |
| Staging 部署机制 | `deploy/macos/install-staging.sh` 手动脚本，在 Mac 上运行；需要更新服务端代码时 `git pull` 后重跑 |
| Staging 域名 | `staging-gamebox.zqydev.me`（DNS 记录已由 cloudflared 创建） |
| Staging 网络 | 复用正式服的 Cloudflare Tunnel，在 tunnel ingress 中加一条 hostname |

## Architecture

### Part 1: Debug APK 构建与发布（GitHub Actions）

新增 `.github/workflows/debug.yml`：

- 触发：push 到 `main`（`paths` 过滤到 `app/**`、`game_runtime/**`、`tool/**`、
  `deploy/**`）+ `workflow_dispatch`（`api_base_url` 输入可覆盖，默认
  `https://staging-gamebox.zqydev.me`）。
- `concurrency: cancel-in-progress: true`，只保留最新一次构建。
- 工具链对齐现有 CI/release：Java 17、Flutter 3.47.1、Godot 4.7.0、接受 Android
  licenses。
- 构建前执行 `godot --headless --path game_runtime --import` 导入 Godot 资产
  （生成 `.godot/imported/`，APK 需要打包）。
- `GAMEBOX_DEBUG_ARTIFACT=true` 下执行 `flutter build apk --debug`：
  - `--build-name="<pubspec版本>-dev.<sha7>"`、`--build-number=${GITHUB_RUN_NUMBER}`
  - `--dart-define="GAMEBOX_API_BASE_URL=<staging 或输入值>"`
- 校验：`aapt dump badging` 断言 `package name` 为 `me.zqydev.gamebox.debug`。
- 发布：`gh release create debug-latest`（首次）→ 先上传完整 SHA 命名的 APK/校验文件，
  再移动 tag 并 `gh release edit` 更新说明（标注 SHA、版本和当前资产名）；旧资产保留，
  不使用 destructive `--clobber`。
  pre-release，不参与 `releases/latest`。

### Part 2: 包名独立（最小风险方案）

`app/android/app/build.gradle.kts`：

- 读取环境变量 `GAMEBOX_DEBUG_ARTIFACT`（`true` 时生效）。
- `defaultConfig` 增加 `manifestPlaceholders["appLabel"] = "gamebox"`。
- `buildTypes.debug` 在 `GAMEBOX_DEBUG_ARTIFACT=true` 时：
  - `applicationIdSuffix = ".debug"` → 应用 ID 变为 `me.zqydev.gamebox.debug`
  - `manifestPlaceholders["appLabel"] = "gamebox debug"`（桌面图标名可区分）
  - 使用 `key.properties` 中的稳定 signing config；CI 复用 release workflow 的
    `ANDROID_*` signing secrets，避免 rolling build 因临时 debug 证书无法覆盖安装。
- `AndroidManifest.xml` 的 `android:label="gamebox"` 改为
  `android:label="${appLabel}"`。

不设环境变量时所有行为与现在完全一致：本地、CI 验证、E2E/smoke 脚本里的硬编码
`me.zqydev.gamebox` 包名全部不受影响。若本地显式设置该环境变量，则需提供同样的
`app/android/key.properties`，否则 Gradle 会 fail closed。

### Part 3: Staging 服务端（macOS 手动部署）

新增 `deploy/macos/install-staging.sh`，与正式服同机并存：

| 维度 | 正式服 | Staging |
|---|---|---|
| 监听 | `127.0.0.1:18080` | `127.0.0.1:18081` |
| 数据 | `~/Library/Application Support/Gamebox/server/` | `~/Library/Application Support/Gamebox/server-staging/` |
| 日志 | `~/Library/Logs/Gamebox/` | `~/Library/Logs/Gamebox/staging/` |
| Keychain 密钥 | `me.zqydev.gamebox.jwt-secret` / `.token-pepper` | `me.zqydev.gamebox.staging.jwt-secret` / `.token-pepper` |
| launchd 标签 | `me.zqydev.gamebox.server` | `me.zqydev.gamebox.staging.server` |
| 公网地址 | `https://gamebox.zqydev.me` | `https://staging-gamebox.zqydev.me` |

- `run-server.sh` 参数化：新增 `GAMEBOX_JWT_SERVICE` / `GAMEBOX_TOKEN_PEPPER_SERVICE`
  环境变量（缺省指向正式服密钥服务名，向后兼容）；staging 的 launchd plist 传入
  staging 的密钥服务名。
- `health-check.sh` / `backup.sh` 本来就是环境变量参数化，直接复用；staging 的
  plist 传不同的 `GAMEBOX_LOCAL_HEALTH_URL` / `GAMEBOX_PUBLIC_HEALTH_URL` /
  `GAMEBOX_DATA_DIR` / `GAMEBOX_DB_PATH` / `GAMEBOX_BACKUP_DIR`。
- `cloudflared-config.yml` 增加一条 ingress：
  `staging-gamebox.zqydev.me → http://127.0.0.1:18081`。两个安装脚本都从该模板
  生成合并配置；`install-staging.sh` 重新生成配置并 kick 现有 tunnel agent
  （改配置对正式服无影响，staging hostname 未配置前只是 404）。
- Staging 独立随机密钥：`openssl rand -base64 48` 生成存入 Keychain。

### DNS（已完成）

> **域名必须是单级子域**：Cloudflare 免费 Universal SSL 通配符只覆盖
> `*.zqydev.me` 一层。最初选的 `staging.gamebox.zqydev.me` 是两级子域，边缘
> 无证书导致公网 TLS 握手失败，因此改为单级 `staging-gamebox.zqydev.me`。
> 若需要两级子域必须付费 Advanced Certificate，勿改回。

- `cloudflared tunnel route dns 498bfaa8-584d-4111-a4fa-13e7deec223c
  staging-gamebox.zqydev.me` 已创建 CNAME（proxied），DoH 已解析到 Cloudflare
  代理 IP。

## Files changed

- `.github/workflows/debug.yml`（新增）
- `app/android/app/build.gradle.kts`（修改）
- `app/android/app/src/main/AndroidManifest.xml`（修改）
- `deploy/macos/install-staging.sh`（新增）
- `deploy/macos/run-server.sh`（参数化）
- `deploy/macos/cloudflared-config.yml`（加 staging ingress）
- `README.md`（API origin 与部署章节）

## One-time manual step

Cloudflare Dashboard → Zero Trust → Tunnels → gamebox tunnel → Public Hostname，
添加 `staging-gamebox.zqydev.me`（DNS 记录已由 `cloudflared tunnel route dns`
创建，若 Dashboard 未自动关联，可在 Public Hostname 处补一次以完善隧道管理视图；
路由最终由本地 `cloudflared-config.yml` ingress 控制）。

## Verification

- `zsh -n deploy/macos/install-staging.sh deploy/macos/run-server.sh`（语法）
- `bash tool/verify.sh`（CI 等价全量门禁，确认改动不破坏现有构建）
- 本地 `GAMEBOX_DEBUG_ARTIFACT=true flutter build apk --debug` 后用 `aapt dump
  badging` 断言包名为 `me.zqydev.gamebox.debug`
- workflow YAML 结构检查
