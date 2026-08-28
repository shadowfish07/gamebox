# Gamebox layered testing strategy

Gamebox 使用 Flutter 宿主、Godot 游戏、Go 服务和 Android 打包。验证时选择能证明受影响
边界的最低层级；截图是实现 Agent 的 UI 开发自查，不是固定测试脚本的阶段。

## Deterministic repository gates

- 开发内环先运行受影响模块的聚焦测试。
- `bash tool/verify_fast.sh` 是快速确定性 gate。
- `bash tool/verify.sh` 是代码任务交付前的顶层确定性 gate；它不代表已运行实际
  Android 设备或双设备业务 E2E。
- 只改文档、规则或 Skill 时，运行相应的链接、格式、元数据或 Skill validator；
  不为此启动全量设备 E2E。

## UI and runtime evidence

| Changed boundary | Default evidence | Escalation |
| --- | --- | --- |
| Flutter Widget 状态和交互 | Widget tests；Agent 在实际 Flutter 目标界面检查临时截图 | 导航、IME、权限、平台通道或 Android 系统 UI 变更时使用实际 Android 设备 |
| Godot 游戏自有状态和布局 | reducer/controller/scene tests；Agent 运行生产场景或确定性 preview 并检查临时截图 | 导出、宿主渲染面、方向、Back、Activity 生命周期或 bridge 变更时运行 `bash tool/smoke_android_host.sh` |
| 单一 Android 宿主或打包边界 | 聚焦构建、安装、启动和 host smoke | 只有网络、协议、共享权威状态或多玩家行为变更时升级为双设备 E2E |
| Go 服务或协议内部逻辑 | 聚焦 Go 测试和顶层确定性 gate | 封存选择、权威 revision、重连或真实跨端行为变更时运行相关 E2E |

固定 test、smoke 和 E2E runner 不因 UI 验收要求而截图。UI 改动由实现 Agent 另行捕获受影响
状态的无敏感信息截图并检查；截图默认不保留、不提交、不发布。

## Two-device E2E

`bash tool/worktree.sh e2e --scenario <name>` 在共享 Android 租约下运行聚焦双 AVD 场景；
不传 `--scenario` 才运行发布级完整验收。只在下列边界本身受影响，或正在做发布候选
验收时使用：

- Flutter–Godot bridge、launch ticket 或 Activity 生命周期；
- 真实网络、协议、多玩家同步或跨设备权威状态；
- sealed choice、authoritative revision、断线重连或服务恢复；
- 跨运行时的 resign、Back、return-to-lobby 契约。

仅 Godot 排版、文案、主题或场景状态绑定变更不运行整套双设备 E2E；用聚焦 Godot 测试、
直接 Godot 运行时 UI 检查，并在宿主边界受影响时加薄 Android smoke。

## E2E runner

`tool/e2e_android.sh` 是稳定的兼容入口；参数解析和顶层调度在 `tool/e2e/run.sh`，设备、
服务和构建生命周期由 harness 统一持有，场景名称由 registry 管理。可用场景：

- `flutter-host`：打包后的 Flutter 注册和宿主更新交互；
- `gomoku-network`：Flutter–Godot bridge、权威 revision、生命周期和恢复；
- `rps-network`：封存选择、重连、权威完成和 slot 释放；
- `full`：顺序运行全部场景，仅作为发布级或全局协议/lifecycle gate。

修改 runner 时先运行 `bash tool/e2e_android.sh --self-test`。使用 `--plan` 只检查选择结果，
使用 `--verbose` 流式显示成功子阶段输出。默认成功只输出一个顶层 verdict；失败保留原始
退出码并显示失败阶段的输出。场景复用同一轮安全构建、安装和设备准备，固定 runner 不截图。

只有共享 driver 协议、全局生命周期或整段关键旅程不变式变更时，才需要用完整双设备旅程
验证 runner 修改。其余情况在支持聚焦 scenario 后，应以 self-test 加最小受影响 scenario 为默认。
