# Project Agent Instructions

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
