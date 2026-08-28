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

`bash tool/worktree.sh e2e` 在共享 Android 租约下运行完整双 AVD 验收。只在下列边界本身
受影响，或正在做发布候选验收时使用：

- Flutter–Godot bridge、launch ticket 或 Activity 生命周期；
- 真实网络、协议、多玩家同步或跨设备权威状态；
- sealed choice、authoritative revision、断线重连或服务恢复；
- 跨运行时的 resign、Back、return-to-lobby 契约。

仅 Godot 排版、文案、主题或场景状态绑定变更不运行整套双设备 E2E；用聚焦 Godot 测试、
直接 Godot 运行时 UI 检查，并在宿主边界受影响时加薄 Android smoke。

## E2E runner evolution

当修改 `tool/e2e_android.sh` 时，先运行 `bash tool/e2e_android.sh --self-test`。当前 runner 仍是单体
完整旅程；后续拆分应保留一个顶层结果，并增加：

- `--scenario` 或等价的聚焦过滤；
- 预检、构建、设备准备、安装和业务 scenario 的独立阶段诊断；
- 同一运行内的安全构建/安装复用和每个 scenario 的确定性重置；
- 稳定 selector/node ID、条件等待，以及 Godot 无语义树时由运行时提供的实际目标矩形。

只有共享 driver 协议、全局生命周期或整段关键旅程不变式变更时，才需要用完整双设备旅程
验证 runner 修改。其余情况在支持聚焦 scenario 后，应以 self-test 加最小受影响 scenario 为默认。
