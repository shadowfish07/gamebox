# Gamebox

<!-- markdownlint-disable MD013 -->

> [English](README.md) · **简体中文**

一个使用 Flutter、Godot 和 Go 构建的服务器权威 Android 游戏合集。

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![CI](https://github.com/shadowfish07/gamebox/actions/workflows/ci.yml/badge.svg)](https://github.com/shadowfish07/gamebox/actions/workflows/ci.yml)
[![Android](https://img.shields.io/badge/platform-Android-3DDC84?logo=android&logoColor=white)](https://github.com/shadowfish07/gamebox/releases)
[![Flutter 3.47.1](https://img.shields.io/badge/Flutter-3.47.1-02569B?logo=flutter&logoColor=white)](https://docs.flutter.dev/)
[![Godot 4.7](https://img.shields.io/badge/Godot-4.7-478CBF?logo=godot-engine&logoColor=white)](https://godotengine.org/)
[![Go 1.25](https://img.shields.io/badge/Go-1.25-00ADD8?logo=go&logoColor=white)](https://go.dev/)

Gamebox 由 Flutter 应用外壳、嵌入式 Godot 游戏和基于 SQLite 的 Go 服务组成。匹配规则与结果由服务器裁定；客户端只渲染权威状态，并可在断线或进程重启后恢复。

## 功能

- **两款联机游戏**：五子棋与石头剪刀布，各自拥有独立的 Godot 界面
- **服务器权威对局**：落子、出拳、修订号、结果和游戏占用槽均由 Go 服务验证
- **邀请制账号**：一次性注册码、自动登录和可轮换的访问会话
- **可恢复对局**：支持重连、快照恢复、强制停止恢复、认输、取消和返回大厅
- **对局记录**：分页查看五子棋结果、胜负和局统计与胜率
- **Material 3 体验**：Flutter/Godot 共享设计令牌，支持浅色、深色主题和响应式竖屏布局
- **安全的 Android 更新**：签名 APK 校验、校验和验证，以及使用预发环境的独立调试包
- **分层验证**：Flutter、Godot、Go、Android 宿主和确定性双设备测试

## 架构

```text
Flutter 应用外壳
  注册 · 游戏目录 · 对手 · 历史记录 · 更新
            │
            ├─ Android 桥接 ─ 嵌入式 Godot 运行时
            │                   渲染 · 输入 · 重连
            │
            └─ HTTP / WebSocket ─ Go 服务 ─ SQLite
                                  认证 · 规则 · 事件 · 结果
```

| 路径 | 职责 |
| --- | --- |
| [`app/`](app/) | Flutter 入口、Android 宿主、账号和游戏目录 UI、对局启动、历史记录与更新 |
| [`game_runtime/`](game_runtime/) | 嵌入式 Godot 运行时、游戏场景、交互、重连和权威状态渲染 |
| [`server/`](server/) | Go HTTP/WebSocket 服务、认证、游戏规则、事件持久化和 SQLite 存储 |
| [`protocol/`](protocol/) | 版本化网络协议和兼容性 fixture |
| [`design_system/`](design_system/) | 共享设计令牌源文件与 Flutter/Godot 生成产物 |
| [`tool/`](tool/) | 环境检查、验证、worktree、Android smoke、E2E 和发布工具 |

Flutter 和 Godot 不判定操作或结果是否有效。Kotlin 仅负责将 Flutter 宿主桥接到全屏 `GodotActivity`，并传递游戏 ID、一次性启动票据和非敏感配置。Go 服务会在广播前先持久化已接受的事件。

## 环境要求

- Flutter 3.47.1（附带 Dart 3.13）
- Go 1.25
- Godot 4.7（非标准安装位置可通过 `GODOT_BIN` 指定）
- JDK 17 或更高版本
- Android SDK platform 36，并已接受许可协议
- Bash 和 zsh

完整的本地 E2E 还会用到 `adb`、Android Emulator、curl、Git、jq、lsof、OpenSSL、ripgrep、Ruby、sed、`shasum` 和 unzip。受管模拟器需要 `system-images;android-36;google_apis_playstore_ps16k;arm64-v8a`。

可在不安装软件、不接受许可协议的情况下检查工具链：

```bash
# 构建和源码测试环境
bash tool/bootstrap.sh --build-only

# 完整双模拟器 E2E 环境
bash tool/bootstrap.sh
```

## 快速开始

### 1. 启动服务

服务端需要两个彼此独立、至少 32 字节的 JWT 和 token pepper 密钥。本地开发时请使用独立的 SQLite 目录：

```bash
gamebox_data_dir="$(mktemp -d)"
export GAMEBOX_DB_PATH="$gamebox_data_dir/gamebox.db"
export GAMEBOX_JWT_SECRET="$(openssl rand -base64 32)"
export GAMEBOX_TOKEN_PEPPER="$(openssl rand -base64 32)"
export GAMEBOX_ADDR="127.0.0.1:8080"
(cd server && go run ./cmd/gameboxd)
```

在另一个终端验证服务：

```bash
curl --fail http://127.0.0.1:8080/healthz
```

响应内容应严格为 `{"status":"ok"}`。默认监听地址为 `127.0.0.1:8080`；从仓库根目录启动 daemon 时，默认数据库路径为 `server/data/gamebox.db`。

### 2. 创建注册邀请码

使用与运行中服务相同的 `GAMEBOX_TOKEN_PEPPER` 值：

```bash
(cd server && go run ./cmd/gameboxctl invite create \
  --count 2 --db "$GAMEBOX_DB_PATH" --json)
```

每个明文邀请码只显示一次。批量创建是原子操作，`--count` 必须介于 1 和 1000 之间。

### 3. 构建或运行 Android 应用

Android 模拟器会将 `10.0.2.2` 映射到宿主机回环地址，因此调试构建默认使用 `http://10.0.2.2:8080`：

```bash
cd app
flutter pub get
flutter run
```

需要时可覆盖服务地址：

```bash
flutter run \
  --dart-define=GAMEBOX_API_BASE_URL=http://10.0.2.2:8080
```

也可从 [GitHub Releases](https://github.com/shadowfish07/gamebox/releases) 下载打包版本。稳定版使用 `https://gamebox.zqydev.me`；滚动调试版使用隔离的 `https://staging-gamebox.zqydev.me` 服务，并可与稳定版同时安装。

## 开发

并行使用 linked worktree 时，请通过仓库生命周期脚本隔离端口、数据库和共享 Android 设备：

```bash
bash tool/worktree.sh setup
bash tool/worktree.sh status
bash tool/worktree.sh up       # 前台启动独立数据库和稳定端口的服务
bash tool/worktree.sh down
bash tool/worktree.sh e2e      # 获取 Android 共享租约并运行双设备 gate
```

初始化会保留本地状态，且不会复制已部署的密钥。身份认证和游戏数据共用一个 SQLite 文件，因此仓库会拒绝将 worktree 数据库反向写回主检出。具体生命周期 hook、状态路径、端口分配和恢复方法见 [Worktree 开发](docs/worktree-development.md)。

### 检查对局

`gameboxctl` 可在不修改源数据库的前提下重放权威对局：

```bash
(cd server && go run ./cmd/gameboxctl match show \
  --id 11111111-1111-4111-8111-111111111111 \
  --db "$GAMEBOX_DB_PATH" --json)
```

管理命令的退出码：`0` 表示成功，`1` 表示运行失败，`2` 表示语法无效。

## 测试

请选择能证明受影响边界的最低验证层级。仓库的标准 gate 为：

```bash
# Go、Flutter 和 Godot 测试；Flutter 分析；smoke parser fixture
bash tool/verify_fast.sh

# CI 等价 gate，包含 Kotlin 测试和 debug APK 断言
bash tool/verify.sh
```

成功输出默认保持简洁。调试时如需流式输出已通过的子进程日志：

```bash
GAMEBOX_TEST_OUTPUT=verbose bash tool/verify.sh
```

本地双设备验收只用于网络、协议、多人状态、生命周期或发布候选边界：

```bash
bash tool/e2e_android.sh --self-test
bash tool/e2e_android.sh
```

该脚本只操作已获取租约的设备，会恢复显示和主题设置、校验 APK 来源，并将脱敏诊断信息写入 `artifacts/e2e/`。它验证逻辑和生命周期，不替代视觉设计验收。各层所需证据见 [测试策略](docs/testing-strategy.md)。

## 发布

稳定版 Android 应用由 [发布工作流](.github/workflows/release.yml) 根据语义化版本 tag 构建。工作流会验证源码，生成已签名的 APK 和 AAB，检查 APK 签名，执行 Android 宿主 smoke，生成校验和并发布产物。

```bash
# 不修改 Git 状态，校验下一版本
bash tool/release.sh patch --dry-run

# 递增版本、提交、推送并触发发布
bash tool/release.sh patch  # 也可使用 minor / major
```

发布构建需要以下 GitHub Actions secrets：

- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_STORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

[调试工作流](.github/workflows/debug.yml) 会将分支构建发布到滚动的 `debug-latest` 预发布。稳定版和调试版使用不同的应用 ID，可同时安装。

## 部署

目前支持的后端部署目标为 macOS。安装器会将二进制文件放入 `~/.local/libexec/gamebox`，将密钥存入登录 Keychain，将数据保存在 `~/Library/Application Support/Gamebox/server`，并为服务、健康检查、Cloudflare Tunnel 和每日验证备份安装 launch agent。

```bash
zsh deploy/macos/install.sh
curl --fail http://127.0.0.1:18080/healthz
```

`deploy/macos/install-staging.sh` 可安装独立的预发服务。它使用独立的二进制文件、端口、数据库、密钥和 launch agent，但共享生产环境的 tunnel 配置。

## 安全

请勿提交或分享明文邀请码、JWT 或 pepper 值、access/refresh token、启动/恢复票据、SQLite 数据库或私有运行时输入。服务日志只使用请求、连接和对局 ID 进行识别，不记录明文凭据。

如果发现安全问题，请私下向仓库所有者报告，不要创建公开 issue。

## 贡献

欢迎提交 issue 和 pull request。提交改动前：

1. 保持改动聚焦，并在最低相关层级添加测试。
2. 运行 `bash tool/verify.sh`。
3. 用户可见 UI 改动需运行实际目标界面，并检查相关主题和视口下的受影响状态。
4. 不要包含生成的运行时状态、凭据、E2E 产物或含用户特定数据的截图。

## 项目状态

Gamebox 正在积极开发，目前仅面向 Android。尚未实现 AI 对手、本地多人、匹配、好友、聊天、观战、推送通知、iOS 和桌面客户端。

## 许可证

Gamebox 使用 [MIT License](LICENSE) 开源。
