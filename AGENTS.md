# Project Agent Instructions

## Game client technology selection

- 新增棋类、牌类和回合制轻量小游戏，默认优先考虑直接使用 Flutter Widget、
  CustomPainter 和动画系统，以复用应用 UI、主题和客户端工具链。规则复杂度本身
  不构成引入游戏引擎的理由；权威规则、随机结果和胜负裁定继续由 Go 服务端负责。
- 当游戏明确需要复杂实时场景、物理、粒子、镜头、关卡编辑或 3D 等能力时，优先
  评估 Godot。结合实际表现目标和内容制作流程选型，不仅按游戏名称决定引擎。
- 现有 Godot 游戏可以继续维护和完善，不因上述默认方向自动启动迁移或整体重写。
  当前四款游戏中，石头剪刀布、五子棋和跳棋从零实现时更偏向 Flutter；飞行棋
  根据动画与场景表现目标选择。已有实现与迁移成本必须纳入判断。
- 若任务明确要求评估迁移，优先以五子棋实现一款完整 Flutter 对照版本，覆盖
  真实联机、权威状态、动画、断线重连、后台恢复和返回大厅，并依照
  [测试策略](docs/testing-strategy.md)及 UI 验收规则验证后，再决定是否扩大迁移。
  本规则记录选型方向，不视为已授权实施试点或迁移。
- 迁移范围必须包含 Godot 当前承担的对局连接、快照、操作状态和恢复行为，不能
  只替换棋盘画面。保持服务端权威与协议契约；协议调整需按实际任务单独评估。
- 比较方案时同时考虑 UI 一致性、开发调试、生命周期、测试构建、后续游戏类型
  和已有资产。保留任一 Godot 游戏期间，引擎、桥接与构建链仍需维护；不能把
  单款迁移描述为已经获得完全移除 Godot 后的维护或包体收益。
- 流畅度、启动耗时、内存、包体和耗电结论必须区分架构预期与实测结果。量化比较
  使用相同目标设备、可比构建配置和等价游戏状态，不凭框架名称断言性能优劣。

## UI change acceptance

- Any change that affects the user-facing UI is not complete until the implementing agent has run the updated interface in the relevant target runtime, captured the affected states, and inspected the screenshots for UX problems.
- Screenshots are transient inspection inputs, not required task artifacts or deliverables. They need not be committed, retained, uploaded, attached, or included in a pull request or final response unless the user explicitly requests publication.
- A pull request, commit, or final response having no attached screenshots is never a review finding by itself. Review the reported UX inspection result and other runtime evidence instead.
- Use the actual built application for visual inspection. A mock, fixture, source inspection, or static rendering does not replace screenshots from the target runtime.
- Keep credentials and other sensitive or user-specific data out of screenshots and retained artifacts.
- If the implementing agent cannot capture and inspect the affected UI, report the exact blocker and state that UX inspection remains incomplete.

## Test selection

- Follow [docs/testing-strategy.md](docs/testing-strategy.md) when selecting Flutter, Godot, Android host, or two-device evidence.
- Use the lowest layer that proves the affected boundary. The existence of the full two-AVD runner does not make it the default gate for every change.
- Fixed test, smoke, and E2E scripts do not capture screenshots for UI acceptance. Screenshot capture and inspection belong to the implementing agent's UI development workflow.
- Gamebox-specific commands, device leases, markers, state matrices, and protocol invariants remain in this repository rather than shared rules.

## 图片生成

- 本仓库生图优先使用 Poe 的 GPT Image 2，前提是 Poe 有可用额度且模型可用。
- 生图前先检查可用额度；额度不足或服务不可用时，再考虑其他生图方式。
- 此偏好仅适用于本仓库，不作为全局或其他仓库的默认规则。
- 使用 Codex 内置生图时，在提示词中优先要求生成 512 × 512 原稿；输出后检查实际尺寸，
  若未按要求返回，等比例缩小为 512 × 512，不将提示词要求当作工具尺寸保证。
- Poe Key 仅通过本地、已被 Git 忽略的 `.env` 中的 `POE_API_KEY` 读取，不写入源码、提示词或日志。
- 生成或替换收藏原画前，读取项目 Skill [gamebox-collection-content](.agents/skills/gamebox-collection-content/SKILL.md)，
  按内容标准的“四档原画要求”规划构图、故事细节、道具与光影，并逐张及整批验收。
- 收藏卡原画逐张生成，Poe 默认使用 1024 × 1024 正方形原稿，主体四周保留安全边距；
  程序使用的资源默认等比例缩小为 512 × 512 WebP，原稿另行保留。
- 显示时保持原始宽高比，禁止非等比拉伸；需要图集时由程序将等尺寸图片拼接，
  不让生图模型一次绘制多张卡片的网格。

## 收藏卡片内容

新增收藏系列、生成卡片或改写故事前，读取并遵守
项目 Skill [gamebox-collection-content](.agents/skills/gamebox-collection-content/SKILL.md)。按稀有度增加具体经历、
人物动机和故事完整度，并核对原画、跨卡关系与稳定编号；不要只靠加长文案体现稀有度。

<!-- ai-rules:routing:start -->
## Shared rule routing

共享规则根目录为 `.ai/rules/`。不要扫描或全量读取该目录。

开始任务前，根据当前任务涉及的文件和目标读取下表中匹配的入口。若同时匹配多行，
读取所有对应入口；随后只按各入口 `index.md` 的指引继续按需读取。

| 范围或触发条件 | 首先读取 |
|---|---|
| 任何仓库自有源码、测试、构建、smoke 或 acceptance runner 改动 | `.ai/rules/verification/index.md` |
| `app/**`、`pubspec.yaml`、Flutter 界面或 Dart 测试 | `.ai/rules/flutter/index.md` |
| `app/android/**`、Gradle、APK、Android 模拟器或设备验收 | `.ai/rules/android/index.md` |
| `game_runtime/**`、Godot 场景、资源、GDScript 或 addon | `.ai/rules/godot/index.md` |
| `server/**`、`go.mod`、Go 源码或测试 | `.ai/rules/go/index.md` |
| `app/**`、`game_runtime/**`或 `design_system/**` 中的用户可见 UI、交互或导航 | `.ai/rules/ui-acceptance/index.md` |
| Git、提交、PR、worktree、`orca.yaml`、`tool/worktree.sh` 或 `docs/worktree-development.md` | `.ai/rules/git/index.md` |

如果 `.ai/rules` 不存在或路由目标不可读，先说明共享规则未加载，再继续遵守本文件中
提交到项目的约定。项目规则以及更靠近工作文件的 `AGENTS.md` 优先于共享规则；其他
冲突不要自行猜测，应向用户报告。
<!-- ai-rules:routing:end -->
