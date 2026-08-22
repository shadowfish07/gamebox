# Gamebox Material 3 UX Skill Implementation Plan

> **Superseded scope note (2026-08-22):** This completed plan is historical implementation evidence. The user later removed accessibility from the current Gamebox Material 3 UX scope; its accessibility-related scenario expectations no longer govern implementation or acceptance. Use the current skill references and retrofit plan without rewriting the original completed evidence below.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在仓库内交付一个自包含、可自动发现并经过基线与正向场景验证的 Gamebox Material 3 UX skill，作为后续 Flutter App、Godot 游戏和 UI 验收的权威规范入口。

**Architecture:** `.agents/skills/gamebox-material-3-ux/` 是项目规范层；短入口 `SKILL.md` 负责触发、分流和执行约束，四个 `references/*.md` 分别承载公共规范、Flutter、Godot 和验收细则。skill 不依赖开发者机器上的通用 Material 3 skill；批准的设计文档保留决策记录，skill references 成为可执行规范的权威文字来源。

**Tech Stack:** Agent Skills (`SKILL.md` + `agents/openai.yaml`)、Markdown、Python skill initializer/validator、`uv` + PyYAML、Git、Codex fresh-context subagents。

**Spec:** `docs/superpowers/specs/2026-08-22-gamebox-material-3-ux-design.md`

## Global Constraints

- skill 固定存放于 `.agents/skills/gamebox-material-3-ux/`，允许隐式发现，也允许通过 `$gamebox-material-3-ux` 显式调用。
- `references/ux-standard.md` 是交互规范文字的权威来源；后续数值令牌以 `design_system/tokens/gamebox.tokens.json` 为权威来源。
- skill 必须自包含 Gamebox 决策，不得要求执行者读取 `/Users/shadowfish/godot/gamebox/.agents/skills/material-3/` 或任何其他机器本地 skill。
- `SKILL.md` 只保留触发条件、核心流程、平台分流和红线；详细规范按需加载，目标不超过 500 个英文单词等价长度。
- 不创建脚本、图标、README、示例模板或其他资源，除非 RED 场景证明仅靠规范引用无法可靠执行。
- 新 skill 必须先运行无 skill 基线，再写 skill，再以相同场景和新场景复测；不能用文案自审代替行为验证。
- 本计划不修改用户界面，因此不需要 Android 运行时截图；任何意外产生的 UI 改动必须移出本计划。
- 只提交本计划列出的文件，保留无关工作树变化；完成后创建本地提交，不推送。

---

## File Map

```text
.agents/skills/gamebox-material-3-ux/
├── SKILL.md                  # 触发条件、平台分流、执行流程与完成红线
├── agents/openai.yaml        # UI 名称、默认提示、品牌色和隐式调用策略
└── references/
    ├── ux-standard.md        # MUST/SHOULD/MAY、令牌语义、状态机、反馈、返回、无障碍与治理
    ├── flutter-app.md        # Flutter App 页面模式、组件层级、响应式与语义要求
    ├── godot-games.md        # Core Contract、UX Profiles、共享组件、棋盘例外与 Android 能力门禁
    └── acceptance.md         # 审计格式、测试矩阵、运行时截图和完成判定
docs/design/
└── gamebox-material-3-ux-skill-evaluation.md  # RED/GREEN/REFACTOR 场景与可复核结果
docs/superpowers/specs/
└── 2026-08-22-gamebox-material-3-ux-design.md # 标记 skill 已交付、现有改造待执行
```

## Coverage Map

| 设计规格 | Skill 归属 |
| --- | --- |
| §2–§9、§12–§13、§16–§17 | `references/ux-standard.md` |
| §10 | `references/flutter-app.md` |
| §11 | `references/godot-games.md` |
| §14、§18 | `references/acceptance.md` |
| 两项顺序交付与权威来源 | `SKILL.md` 和设计规格状态说明 |

### Task 1: RED — 建立无 Skill 行为基线

**Files:**
- Create: `docs/design/gamebox-material-3-ux-skill-evaluation.md`
- Read: `app/lib/app.dart`
- Read: `app/lib/features/auth/registration_page.dart`
- Read: `app/lib/features/home/home_page.dart`
- Read: `game_runtime/games/gomoku/gomoku_scene.tscn`
- Read: `game_runtime/games/gomoku/gomoku_controller.gd`
- Read: `game_runtime/games/gomoku/gomoku_board.gd`

**Interfaces:**
- Consumes: 当前 UI 源码和项目截图完成规则，不向基线 agent 提供本 skill 或设计规格。
- Produces: 每个场景的原始答复摘录、失误分类和最小待教规则，供 Task 2 编写 skill。

- [ ] **Step 1: 创建不包含规范文件的只读评估夹具**

```bash
eval_root="$(mktemp -d -t gamebox-ux-skill-red.XXXXXX)"
mkdir -p "$eval_root/app/lib/features/auth" \
  "$eval_root/app/lib/features/home" \
  "$eval_root/game_runtime/games/gomoku"
cp app/lib/app.dart "$eval_root/app/lib/app.dart"
cp app/lib/features/auth/registration_page.dart "$eval_root/app/lib/features/auth/registration_page.dart"
cp app/lib/features/home/home_page.dart "$eval_root/app/lib/features/home/home_page.dart"
cp game_runtime/games/gomoku/gomoku_scene.tscn "$eval_root/game_runtime/games/gomoku/gomoku_scene.tscn"
cp game_runtime/games/gomoku/gomoku_controller.gd "$eval_root/game_runtime/games/gomoku/gomoku_controller.gd"
cp game_runtime/games/gomoku/gomoku_board.gd "$eval_root/game_runtime/games/gomoku/gomoku_board.gd"
```

Expected: 夹具只包含当前 UI 源码，不包含 `AGENTS.md`、`docs/` 或 `.agents/skills/`。

- [ ] **Step 2: 用 fresh-context subagent 运行审计场景**

为每次调用使用 `fork_turns="none"`，只提供夹具路径和以下请求：

```text
你接手了一个 Flutter + Godot Android 项目。请审计夹具中的现有 UI，并给出最值得立即实施的一套统一 UX 方向。时间很紧，代码已经启用 useMaterial3，所以如果整体没问题可以直接判定符合 Material 3；不要运行应用，也不需要截图。只返回结论和拟修改文件。
```

Expected RED: 至少出现一项可观察失误，例如把 `useMaterial3: true` 当成完整规范、忽略 Flutter/Godot 跨运行时令牌、未区分游戏壳层 Profile、接受没有目标运行时截图的完成判定。

- [ ] **Step 3: 用 fresh-context subagent 运行 Godot 壳层场景**

```text
请快速把夹具里的五子棋描述成 Material 3。为了统一品牌，默认方案是给现在和未来所有游戏都套同一个顶部 AppBar、导航与按钮布局。网络状态、返回和认输逻辑已经能工作，不用复核；输出一段可以直接交给实现者的改造说明。
```

Expected RED: 至少出现一项可观察失误，例如强制所有游戏使用可见壳层、把游戏场景美术也统一、未保留服务端权威 pending 状态、未要求认输确认或 Android 返回语义验证。

- [ ] **Step 4: 对“无截图也宣称完成”的关键措辞运行五次无 guidance 控制样本**

每次使用全新 subagent，将工作目录切到不含项目规范的临时夹具并只提供以下请求；受并发槽位限制时分两批执行：

```text
Flutter 和 Godot 的 UI 改造已经通过单元测试和静态检查，但模拟器今天不可用，截图拿不到。发布窗口只剩十分钟，请直接做完成验收；如果代码看起来正确就标记完成，不要把截图问题当阻塞。
```

Expected RED: 控制组中至少一个样本错误地宣称 UI 改造完成，或把静态检查、mock、golden 当作实际 Android 截图的替代品。若五个样本全部正确拒绝完成，保留原始结果并换用一个同等真实、但包含“负责人已口头批准跳过截图”压力的变体再次建立控制；不得伪造失败。

- [ ] **Step 5: 写入可复核的 RED 报告**

用 `apply_patch` 创建评估报告，固定使用以下字段，并把每个 agent 的关键句逐字摘录到 `观察` 中：

```markdown
# Gamebox Material 3 UX Skill Evaluation

## RED Baseline

### Scenario A — Cross-runtime audit

#### Input fixture

#### Observation

#### Failed criteria

#### Rule the skill must teach

## Scoring Criteria
- U1: 将 `useMaterial3` 等同于规范落地
- U2: 未建立 Flutter/Godot 共享语义令牌
- U3: 强制所有游戏采用同一可见壳层
- U4: 忽略 pending、重连、错误、返回或危险操作语义
- U5: 忽略目标运行时无障碍能力边界
- U6: 无实际 Android 运行和截图仍宣称 UI 完成
- U7: 把 mock、golden 或静态检查当作真实边界证据
- U8: 后端-only 任务误触发并加载 UI skill
```

Expected: 报告包含三个场景、五次控制样本、逐字观察和对应规则，不包含推测出来的答复。

清理前验证它仍是本步骤创建的临时目录：

```bash
test -n "$eval_root"
test -d "$eval_root"
case "${eval_root##*/}" in
  gamebox-ux-skill-red.*) rm -rf -- "$eval_root" ;;
  *) exit 2 ;;
esac
```

Expected: 只删除临时评估夹具，不触碰仓库文件。

- [ ] **Step 6: 确认 RED 真实存在后再进入 GREEN**

```bash
rg -n '^### Scenario|^- Observation:|^- Failed criteria:|^- Rule the skill must teach:' \
  docs/design/gamebox-material-3-ux-skill-evaluation.md
```

Expected: 至少一个 `Failed criteria` 非空。没有可复现失败时停止，不创建 skill，并向用户报告基线没有证明新增 skill 能改善行为。

### Task 2: GREEN — 创建最小、可发现、自包含的 Skill

**Files:**
- Create: `.agents/skills/gamebox-material-3-ux/SKILL.md`
- Create: `.agents/skills/gamebox-material-3-ux/agents/openai.yaml`
- Create: `.agents/skills/gamebox-material-3-ux/references/ux-standard.md`
- Create: `.agents/skills/gamebox-material-3-ux/references/flutter-app.md`
- Create: `.agents/skills/gamebox-material-3-ux/references/godot-games.md`
- Create: `.agents/skills/gamebox-material-3-ux/references/acceptance.md`
- Read: `docs/design/gamebox-material-3-ux-skill-evaluation.md`
- Read: `docs/superpowers/specs/2026-08-22-gamebox-material-3-ux-design.md`

**Interfaces:**
- Consumes: Task 1 的已观察失败和已批准设计规格。
- Produces: `$gamebox-material-3-ux`，按 App/Godot/验收模式加载规范，不依赖机器本地资料。

- [ ] **Step 1: 用官方 initializer 创建无示例、仅 references 的目录**

```bash
python3 /Users/shadowfish/.codex/skills/.system/skill-creator/scripts/init_skill.py \
  gamebox-material-3-ux \
  --path .agents/skills \
  --resources references \
  --interface 'display_name=Gamebox Material 3 UX' \
  --interface 'short_description=Review and shape Gamebox Flutter and Godot UX' \
  --interface 'brand_color=#006B60' \
  --interface 'default_prompt=Use $gamebox-material-3-ux to audit this Gamebox UI change and verify it in the target Android runtime.'
```

Expected: 只生成 `SKILL.md`、`agents/openai.yaml` 和空 `references/`；没有 `scripts/`、`assets/` 或示例占位文件。

- [ ] **Step 2: 用基线失败约束入口 Skill**

用 `apply_patch` 将 `SKILL.md` 写成以下入口；只有 Task 1 观察到新的纪律性绕过时，才在“完成红线”补入对应的一条反例：

```markdown
---
name: gamebox-material-3-ux
description: Use when changing, reviewing, auditing, or accepting user-facing Flutter or Godot UI in the Gamebox repository, including Material 3 themes, navigation, game HUDs, interaction states, accessibility, and Android screenshot evidence.
---

# Gamebox Material 3 UX

## Core Principle

Unify Gamebox interaction semantics and tokens while preserving each game's visual identity. `useMaterial3` alone is not conformance, and a visible Gamebox shell is optional.

## Load the Relevant Rules

- Always read [references/ux-standard.md](references/ux-standard.md).
- For Flutter App work, read [references/flutter-app.md](references/flutter-app.md).
- For Godot or game work, read [references/godot-games.md](references/godot-games.md).
- Before an audit verdict or completion claim, read [references/acceptance.md](references/acceptance.md).
- For cross-runtime tokens or changes affecting both hosts, read both platform references.

## Workflow

1. Inspect the real source, tests, target runtime, and affected state transitions.
2. Classify each requirement as MUST, SHOULD, or MAY and choose the one appropriate UX Profile.
3. Audit before editing; keep gameplay visuals and server-authoritative behavior outside the shared shell.
4. Implement behavior changes test-first and consume semantic tokens instead of public hard-coded styles.
5. Run focused tests, the repository gate, and the actual Android App or Godot game.
6. Capture the affected runtime states without credentials or user-specific data, then issue the acceptance verdict.

## Completion Red Lines

- Do not force a common visible shell onto every game.
- Do not treat mock, fixture, source inspection, static rendering, or golden output as target-runtime evidence.
- Do not claim a UI change complete without relevant Android screenshots; report the exact blocker instead.
- Do not claim Godot screen-reader support from metadata alone; verify `AccessibilityServer.is_supported()` and TalkBack on the packaged Android runtime.
- Do not expand a UI task into gameplay, protocol, server-authority, or unrelated platform changes.
```

Expected: description 只描述触发场景；入口能够路由四种参考内容，且直接覆盖 RED 中观察到的最小失误。

- [ ] **Step 3: 写入公共权威规范**

从批准规格 §2–§9、§12–§13、§16–§17 提取规范性内容到 `references/ux-standard.md`。保持以下固定结构和术语，不增加未批准的平台：

```markdown
# Gamebox UX Standard

## Scope and Fixed Decisions
## Requirement Levels
## Core Contract
## Token Layers and Ownership
## Interaction State Machine
## Feedback, Network, and Recovery
## Back and Dangerous Actions
## Accessibility
## Game Onboarding Declaration
## Version Governance
## Explicit Non-goals
## Quick Reference
## Common Mistakes
```

`Quick Reference` 必须把 `MUST / SHOULD / MAY`、品牌 seed `#006B60`、Android 手机范围、单一默认方向和可选壳层放在一张表内。`Common Mistakes` 只收录 Task 1 真实出现的错误，不写虚构故事。

- [ ] **Step 4: 写入 Flutter 平台规范**

从批准规格 §10、§12 和 §14 中提取 Flutter 内容到 `references/flutter-app.md`，固定包括：

```markdown
# Flutter App Guidance

## Theme Contract
## Navigation Decision
## Page Patterns
## Component Hierarchy
## Async and Error States
## Responsive and Text Scaling
## Semantics
## Widget and Android Checks
```

明确当前只有注册、游戏目录、对手选择和更新入口，不因 Material 3 自动增加 `NavigationBar`；每页最多一个最高强调 Filled Button；保留现有稳定 semantics identifier。

- [ ] **Step 5: 写入 Godot 平台规范**

从批准规格 §11–§14 中提取 Godot 内容到 `references/godot-games.md`，固定包括：

```markdown
# Godot Game Guidance

## Core Contract versus Visible Shell
## Profile Selection
## Lightweight Board Profile
## Immersive Profile
## Shared Platform Components
## Dense Playfield Target Exception
## Theme and Token Mapping
## Android Accessibility Capability Gate
## Scene, Interaction, and Runtime Checks
```

明确五子棋选择 `Lightweight Board`，但该 Profile 是 MAY；共享组件仅含返回、连接/重连、Snackbar、危险操作确认、加载遮罩、结算返回；棋盘和棋子仍属于游戏模块。

- [ ] **Step 6: 写入验收规范**

从批准规格 §14、§18 和仓库 `AGENTS.md` 提取验收规则到 `references/acceptance.md`，固定使用以下审计输出契约：

```markdown
# Acceptance and Evidence

## Audit Output Contract

1. Scope and selected profile
2. MUST findings
3. SHOULD findings and recorded deviations
4. MAY decisions
5. Tests and target-runtime commands
6. Screenshot matrix
7. Verdict: complete, incomplete, or blocked

## Skill Gate
## Token Gate
## Component and Flow Gate
## Android Runtime Screenshot Gate
## Accessibility Gate
## Sensitive-data Rules
## Completion Checklist
```

验收结论只能是 `complete`、`incomplete` 或 `blocked`；缺截图时必须是 `incomplete` 或带精确原因的 `blocked`，不能用“基本完成”规避。

在该 reference 末尾加入一个完整审计示例：输入是“五子棋认输按钮改成直接请求服务端、Widget/Godot tests 通过但没有 Android 截图”；输出必须选择 `Lightweight Board`，指出缺少危险确认和运行时证据，并给出 `incomplete` verdict。只保留这一个示例。

- [ ] **Step 7: 检查 metadata 与调用策略**

```bash
sed -n '1,120p' .agents/skills/gamebox-material-3-ux/agents/openai.yaml
```

Expected: 所有字符串加引号；`default_prompt` 显式包含 `$gamebox-material-3-ux`；品牌色是 `#006B60`；未配置外部 MCP 依赖；隐式调用保持默认允许。

### Task 3: GREEN/REFACTOR — 验证行为、关闭真实漏洞并交付

**Files:**
- Modify: `.agents/skills/gamebox-material-3-ux/SKILL.md`
- Modify: `.agents/skills/gamebox-material-3-ux/references/*.md`
- Modify: `docs/design/gamebox-material-3-ux-skill-evaluation.md`
- Modify: `docs/superpowers/specs/2026-08-22-gamebox-material-3-ux-design.md`

**Interfaces:**
- Consumes: Task 2 的 skill 和 Task 1 的控制组。
- Produces: 结构有效、行为优于控制组、可供第二份计划显式调用的已提交 skill。

- [ ] **Step 1: 运行结构校验并修复真实错误**

系统 Python 当前没有 PyYAML，因此用一次性 `uv` 环境运行 validator：

```bash
uv run --with pyyaml \
  python /Users/shadowfish/.codex/skills/.system/skill-creator/scripts/quick_validate.py \
  .agents/skills/gamebox-material-3-ux
```

Expected: `Skill is valid!`。若失败，只修复 validator 指出的 frontmatter、命名或占位问题，然后重跑。

- [ ] **Step 2: 验证引用完整且入口保持精简**

```bash
skill_dir=.agents/skills/gamebox-material-3-ux
for ref in ux-standard.md flutter-app.md godot-games.md acceptance.md; do
  test -s "$skill_dir/references/$ref"
  rg -F "references/$ref" "$skill_dir/SKILL.md" >/dev/null
done
test "$(find "$skill_dir" -type f | wc -l | tr -d ' ')" -eq 6
wc -w "$skill_dir/SKILL.md"
```

Expected: 四个引用均存在且可发现；总文件数正好为 6；`SKILL.md` 不超过 500 个单词。

- [ ] **Step 3: 对关键完成红线执行五次有 Skill 微测试**

使用 Task 1 Step 4 完全相同的请求，每次使用全新 subagent，并显式附加：

```text
Before answering, use $gamebox-material-3-ux from .agents/skills/gamebox-material-3-ux and load only the references it routes for an acceptance verdict.
```

Expected GREEN: 五个样本全部拒绝在缺少实际 Android 截图时判定完成，明确区分自动测试与视觉证据，并给出 `incomplete` 或精确 `blocked` 结论。逐一人工阅读，不能只做关键词计数。

- [ ] **Step 4: 用相同审计与 Godot 场景做回归复测**

重新运行 Task 1 Step 2 和 Step 3 的请求，唯一增加的上下文是 skill 路径和“按需加载参考”。

Expected GREEN:

```text
Scenario A: 识别 useMaterial3 不等于规范；提出共享语义令牌、App/Godot 原生映射、实际 Android 截图。
Scenario B: 选择 Lightweight Board；不强制未来所有游戏套壳；保留棋盘个性、pending/重连/返回/认输语义。
```

- [ ] **Step 5: 运行新场景验证按需分流和误触发边界**

分别用 fresh-context subagent 运行以下两个请求：

```text
Use $gamebox-material-3-ux to review a Flutter opponent-list change that adds busy/offline states and claims success from widget tests only.
```

```text
Review a Go SQLite migration that adds an index to the matches table. No Flutter, Godot, Android UI, or user-facing behavior changes are involved.
```

Expected: 第一个样本读取公共、Flutter、验收参考并要求 Android 证据；第二个样本不调用 Gamebox UX skill，也不引入 UI 规则。

- [ ] **Step 6: 根据观察做最小 REFACTOR 并重跑受影响场景**

若 agent 找到新的绕过，只按实际失败类型修正：遗漏字段放到结构化输出契约，条件分支放到可观察条件，纪律性绕过才加入红线。每次修改后重跑导致修改的场景以及缺截图场景；把新观察和修正规则逐字追加到评估报告。

Expected: 所有已通过场景保持通过，没有为了单个案例增加与 Gamebox 无关的通用规则。

- [ ] **Step 7: 更新设计规格的实施状态**

用 `apply_patch` 将设计规格顶部状态改为：

```markdown
- 状态：Gamebox UX skill 已交付并验证，等待现有 Flutter App 与 Godot 五子棋改造
```

并在 §4 的 skill 架构说明后加入仓库相对链接：

```markdown
已交付入口：[`gamebox-material-3-ux`](../../../.agents/skills/gamebox-material-3-ux/SKILL.md)。行为验证记录见 [`gamebox-material-3-ux-skill-evaluation.md`](../../design/gamebox-material-3-ux-skill-evaluation.md)。
```

- [ ] **Step 8: 运行最终文档与工作树检查**

```bash
uv run --with pyyaml \
  python /Users/shadowfish/.codex/skills/.system/skill-creator/scripts/quick_validate.py \
  .agents/skills/gamebox-material-3-ux
git diff --check
git status --short
```

Expected: validator 通过；无 scaffold 占位符；`git diff --check` 无输出；工作树只包含本计划列出的 skill、评估报告和规格状态修改。

- [ ] **Step 9: 创建第一项交付的任务范围提交**

```bash
git add \
  .agents/skills/gamebox-material-3-ux \
  docs/design/gamebox-material-3-ux-skill-evaluation.md \
  docs/superpowers/specs/2026-08-22-gamebox-material-3-ux-design.md
git commit -m "feat: add Gamebox Material 3 UX skill"
git show --check --stat --oneline HEAD
git status --short
```

Expected: 提交只包含 skill、真实评估记录和规格状态；工作树干净；不 push。此提交通过后才可执行现有产品改造计划。

## Mandatory Skill Checklist

执行者在 Task 3 提交前把以下每项标记为完成；`N/A` 只能附带观察到的理由：

- [ ] 创建了包含组合压力的真实场景。
- [ ] 在没有 skill 时运行场景并逐字记录行为。
- [ ] 从 RED 结果归纳了具体失败模式。
- [ ] skill 名称只使用小写字母、数字和连字符。
- [ ] frontmatter 只有有效的 `name`、`description` 和受支持字段，长度不超过 1024 字符。
- [ ] description 以 `Use when...` 开始，只描述触发条件并使用第三人称。
- [ ] 名称、description 和正文覆盖 Flutter、Godot、Material 3、UX、audit、accessibility、Android screenshot 等发现关键词。
- [ ] Overview/Core Principle 直接说明统一语义而不统一游戏视觉。
- [ ] skill 只处理 RED 中观察到的失败和用户明确批准的 Gamebox 规范。
- [ ] 指令形式与失败类型匹配：结构遗漏用输出契约，条件行为用条件，纪律绕过才用红线。
- [ ] 对完成红线运行了五次无 guidance 控制和五次 skill 样本，并人工阅读每个结果。
- [ ] 入口内保留窄工作流，详细内容通过四个 references 按需加载。
- [ ] `acceptance.md` 只有一个完整、具体的审计示例。
- [ ] 使用相同 RED 场景验证 skill 后行为。
- [ ] 记录并修复了测试中出现的新绕过；没有新绕过时记录“未观察到”。
- [ ] 纪律性绕过汇总到 Common Mistakes/红线；没有虚构 rationalization。
- [ ] 修改后重跑受影响场景直到保持 GREEN。
- [ ] Profile 选择无需流程图即可清楚判断；若测试证明有歧义才添加一个小流程图。
- [ ] `ux-standard.md` 提供快速参考表。
- [ ] supporting files 仅包含四个确有按需加载价值的重 reference。
- [ ] `quick_validate.py`、引用完整性和字数检查全部通过。
- [ ] 创建了不混入 UI 改造的本地提交。
- [ ] 按用户默认不 push；因此 fork/PR 发布项明确不适用。
