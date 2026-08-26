# Gamebox Material 3 UX 规范设计

- 日期：2026-08-22
- 状态：等待最终 Android E2E 证据
- 适用范围：Gamebox Flutter App、Android 宿主边界、所有 Godot 游戏
- 设计基线：稳定 Material 3，选择性采用可跨 Flutter/Godot 可靠复现的 Material 3 Expressive 能力

## 1. 目标

Gamebox 需要一套可执行、可验证、可长期演进的交互规范。它既要让 Flutter App 与所有 Godot 游戏表现为同一个产品，又不能把每个游戏限制成同一种视觉模板。

本设计采用以下核心原则：

1. 统一交互语言，保留游戏个性。
2. 以平台无关的语义令牌作为唯一设计数据源。
3. Flutter 与 Godot 各自使用原生组件和主题能力，不共享渲染代码。
4. 公共可见壳层按需使用，不强制覆盖所有游戏。
5. 错误恢复、返回语义和目标运行时视觉证据属于不可豁免的 Core Contract。

## 2. 已确认的产品决策

| 决策 | 结论 |
| --- | --- |
| App 与游戏的统一程度 | 统一设计令牌、交互语义和反馈；游戏保留场景美术、玩法 HUD、音效和主题扩展 |
| 品牌主题 | 固定 Gamebox 品牌主题，不跟随 Android 壁纸动态取色 |
| 品牌方向 | “协作青绿”，建议 seed 为 `#006B60` |
| 明暗模式 | 使用同一 seed 生成并锁定版本的明暗 Material 3 配色 |
| Material 3 Expressive | 以稳定 Material 3 为底座，只选择 Flutter 与 Godot 都能可靠复现的排版、形状和轻量动效 |
| 设备范围 | Android 手机；暂不承诺平板、折叠屏、ChromeOS 或桌面布局 |
| 屏幕方向 | 每个游戏声明一个最合适的默认方向；不要求同时支持竖屏和横屏 |
| 公共游戏壳层 | 非强制；五子棋等轻量游戏可选用轻量浮动壳层 |
| 规范落地 | 先交付仓库内自包含的 Gamebox UX skill，再由该 skill 驱动现有 Flutter App 与 Godot 五子棋改造；共享令牌、原生组件库、自动检查和实际运行时截图共同构成改造完成标准 |

### 2.1 两项顺序交付

本设计进入实现后拆成两项独立验收、顺序执行的工作：

1. **提供 Gamebox Material 3 UX skill**：把 Gamebox 的规范内容、Flutter/Godot 应用方式、审计流程和验收清单封装为仓库内可发现、可版本化、可验证的 skill。
2. **使用该 skill 改造现有产品**：先审计当前 Flutter App 与 Godot 五子棋，再完成令牌、公共组件、页面和游戏交互改造，并取得实际 Android 运行时与截图证据。

第二项工作必须在第一项 skill 通过结构校验和真实任务场景验证后开始。skill 既是后续改造的执行约束，也是未来新增页面、组件和游戏时的默认评审入口；本轮不要求把所有未来游戏都提前改造成同一种 UI。

## 3. 规范等级与适用边界

规范使用三个等级：

- **MUST**：所有 App 页面和游戏必须满足。偏离时不能发布为完成状态。
- **SHOULD**：默认采用。偏离需要在游戏接入文档中记录理由和替代措施。
- **MAY**：由页面、游戏类型或视觉方向按需采用。

### 3.1 所有游戏的 MUST

- 使用共享语义令牌表达公共颜色、文字层级、间距、形状、状态和动效。
- 声明唯一默认屏幕方向，并在该方向完成目标运行时验证。
- 正确处理 Android 安全区域、返回键、后台恢复和游戏 Activity 退出。
- 返回不得隐式认输、取消对局或丢弃进度。
- 使用统一的加载、待确认、重连、错误、危险操作确认和结算语义。
- 满足本文的运行时交互与视觉证据要求。

### 3.2 游戏可自由决定的内容

- 场景、棋盘、角色、背景、粒子、插画和音效。
- 玩法专属 HUD、计分方式、棋子或角色动画。
- 通过受控扩展令牌使用的游戏强调色。
- 是否采用 Gamebox 提供的可见壳层和公共组件。

## 4. 设计系统架构

设计系统分为 skill 规范层、令牌契约层和原生组件层。

```text
gamebox/
├── .agents/skills/gamebox-material-3-ux/
│   ├── SKILL.md
│   ├── agents/
│   │   └── openai.yaml
│   └── references/
│       ├── ux-standard.md
│       ├── flutter-app.md
│       ├── godot-games.md
│       └── acceptance.md
├── design_system/
│   ├── schema/
│   │   └── tokens.schema.json
│   ├── tokens/
│   │   └── gamebox.tokens.json
│   └── README.md
├── docs/design/
│   ├── game-onboarding.md
│   └── profiles/
│       ├── core-contract.md
│       ├── lightweight-board.md
│       └── immersive.md
├── app/lib/design_system/
│   ├── generated/
│   │   └── gamebox_tokens.g.dart
│   ├── gamebox_theme.dart
│   └── components/
├── game_runtime/design_system/
│   ├── generated/
│   │   └── gamebox_tokens.gd
│   ├── gamebox_theme.gd
│   └── components/
└── tool/
    ├── generate_design_tokens.dart
    └── verify_design_system.sh
```

路径表达职责边界，实施计划可以在不改变边界的前提下微调具体文件名。

skill 内的 `references/ux-standard.md` 是交互规范文字的权威来源；`gamebox.tokens.json` 是可生成数值的权威来源；本文保留设计依据、范围与架构决策，不再平行复制一份可执行规范。`SKILL.md` 只负责触发条件、工作流和按需加载相应参考文件，避免把全部规则堆入入口文件。

已交付入口：[`gamebox-material-3-ux`](../../../.agents/skills/gamebox-material-3-ux/SKILL.md)。行为验证记录见 [`gamebox-material-3-ux-skill-evaluation.md`](../../design/gamebox-material-3-ux-skill-evaluation.md)。

该 skill 必须自包含 Gamebox 已确认的决策，不直接依赖开发者机器上的通用 `material-3` skill。通用 skill 和官方 Material 文档可用于编写与更新它，但不能成为执行时的隐式前置条件。

### 4.1 单一数据流

```text
gamebox.tokens.json
        │
        ├── schema 校验
        │
        ├── 生成 Dart 常量 ──> GameboxTheme ──> ThemeData / ThemeExtension
        │
        └── 生成 GDScript 常量 ──> GameboxTheme ──> Theme / StyleBox
```

- `gamebox.tokens.json` 是唯一可手工修改的令牌数据源。
- 生成器使用仓库已有 Dart 工具链，不引入运行时网络请求或第三方服务。
- 生成文件提交到 Git，保证 Flutter、Godot 和干净检出得到相同结果。
- 验证脚本重新生成到临时位置并比较差异；存在漂移时失败。
- schema 缺失、角色不完整、非法值或生成失败都必须在构建期失败，不允许运行时静默回退到另一套主题。

### 4.2 原生映射

Flutter 使用 `ThemeData`、`ColorScheme`、`TextTheme`、组件主题和必要的 `ThemeExtension`。Godot 使用 `Theme`、`StyleBox`、字体与 GDScript 语义常量。两端共享令牌名称、意义和数值，不共享 Widget、Scene 或绘制实现。

## 5. 设计令牌

令牌分四层：

1. `ref`：seed、色调值、基础字体和原始尺寸。
2. `sys`：Material 3 语义角色，例如 `primary`、`on_surface`、`title_large`、`corner_medium`。
3. `comp`：公共组件映射，例如主要按钮容器色、对话框圆角、状态 Chip 排版。
4. `game`：受控的游戏扩展角色，例如 `game_accent`、`playfield_surface`、`piece_pending`。

业务代码不得直接读取 `ref` 层或散落硬编码颜色、字号、圆角和动效时长。页面和游戏优先读取 `sys`，公共组件读取 `comp`，游戏视觉读取 `game`。

### 5.1 颜色

- 品牌 seed 建议为 `#006B60`，命名为 `Gamebox Teal`。
- light 与 dark scheme 由同一 Material 3 tonal palette 生成后固化进 token 文件。
- `primary` 用于最高强调操作、选中和焦点。
- `secondary` 用于次级操作和弱强调容器。
- `tertiary` 是游戏扩展强调色的默认入口。
- `surface` 与 `surface-container-*` 表达背景和容器层级。
- `error` 只用于错误或危险语义，不得作为普通装饰色。
- 前景必须使用容器对应的 `on-*` 角色；不得任意交叉配对。
- 游戏扩展色不能覆盖 `error`、公共文字、焦点、禁用和系统状态角色。
- 公共控件和文字层必须支持 light 与 dark scheme；棋盘、角色和场景美术可以保持固定艺术配色，但在两种 scheme 下都必须满足可读性和状态辨识要求。

### 5.2 排版

使用 Material 3 的 Display、Headline、Title、Body、Label 五类三级语义。首版不引入独立品牌字体，使用 Android 系统 Roboto 与中文系统字体回退。Flutter 与 Godot 对齐字号、字重、行高和用途，不以逐像素相同的字形渲染作为目标。

组件使用规则包括：

- Top App Bar 标题：`title_large`
- 卡片标题：`title_medium`
- 正文：`body_large` 或 `body_medium`
- 按钮与 Chip：`label_large`
- 次要说明和 Snackbar：`body_medium`
- Dialog 标题：`headline_small`

### 5.3 间距与形状

- 4dp 为基础网格，主要布局使用 8dp 节奏。
- 手机页面边距默认 16dp，内容分组默认 24dp。
- 普通公共控件最小触控区域为 48×48dp。
- 按钮、图标按钮和状态 Chip 使用 full shape。
- 输入框使用 8dp，卡片使用 12dp，浮动容器使用 16–20dp，对话框使用 28dp。
- 例外尺寸必须进入组件令牌，不得在多个页面重复魔法数字。

### 5.4 层级与动效

- 优先使用 `surface-container-*` 的色调差表达层级。
- 阴影只用于浮在复杂内容上的控件或需要额外边界保护的场景。
- 页面进入约 400ms，退出约 200ms，普通状态变化约 200–300ms。
- 弹性、形变或强调动画只用于按钮按压、选中、棋子落下等局部反馈。
- 网络等待、对手行动等不确定时长状态不能用一次性动画冒充进度。

## 6. 统一交互状态机

所有 App 操作和游戏动作遵循：

```text
enabled → pressed → pending → success
                         └──→ failure → enabled
```

- 按下后立即显示状态层、轻量缩放或触觉反馈。
- pending 时禁止重复提交，并同时显示进度或明确状态文字；不能只把控件变灰。
- 普通且可撤销的动作可以乐观更新。
- 服务器权威动作只能显示“待确认态”，不能提前成为最终状态。
- 失败后恢复可操作状态，保留仍然有效的用户输入，并提供下一步。

以五子棋为例，落子请求先显示 `piece_pending`；服务端接受后才映射为正式棋子。服务端拒绝、revision 过期或重连同步时，待确认棋子必须移除或按权威快照重建。

## 7. 反馈层级

| 层级 | 用途 | 示例 |
| --- | --- | --- |
| 组件内反馈 | 局部、即时、与当前操作强相关 | 按压、选中、字段校验、按钮 pending |
| Snackbar | 短暂、非阻断、可恢复 | 刷新失败、操作未完成、可撤销结果 |
| 页面内状态 | 影响当前内容区域 | 空数据、加载失败、断线恢复、无可选对手 |
| Dialog | 需要明确决定或危险确认 | 认输、取消对局、丢弃输入 |
| 全屏阻断 | 产品无法继续使用 | 登录恢复失败、凭据安全清理 |

不得用 Dialog 呈现普通成功消息，也不得用短暂 Snackbar 承载用户必须处理的错误。

## 8. 网络与恢复

- 首次连接显示明确加载状态。
- 重连时保留最后确认画面，暂停权威操作，显示“正在恢复连接”。
- 恢复成功后安静回到可操作状态，不弹成功 Dialog。
- 无法恢复时提供重试或返回大厅，且不把未确认本地状态伪装成已确认状态。
- 内部错误码、令牌、URL、revision 细节和连接实现不得暴露给用户。
- App 或游戏从后台恢复时先同步权威状态，再开放新操作。

## 9. 返回与危险操作

- Android 系统返回与可见返回按钮必须表达同一导航结果。
- 返回永远不隐式认输、取消对局或丢弃进度。
- 认输、取消、退出并丢弃进度必须是独立命名的操作。
- 进行中的联网对局返回大厅后应允许继续进入。
- 危险操作使用明确对象和结果的文案，例如“认输并结束本局”，不得只写“确定”。
- 是否需要确认由后果决定，而不是由按钮颜色决定。

## 10. Flutter App 模式

App 负责进入、发现、配置和恢复游戏，不承载游戏本身的玩法界面。

```text
身份恢复 / 注册 → 游戏目录 → 游戏准备 → 启动游戏 → 返回目录
```

### 10.1 导航

- 当前只有“游戏目录”一个一级目的地，不提前加入 Navigation Bar。
- 页面默认使用小型 Material 3 Top App Bar。
- 次级页面提供返回按钮，并与 Android 系统返回保持一致。
- 将来出现 3–5 个稳定一级目的地后，手机端才引入 Navigation Bar。
- 进入 Godot 前显示明确启动状态；启动失败留在原页面并允许重试。
- 返回 App 后刷新对局状态，不强制跳转或弹出普通成功提示。

### 10.2 页面模式

- **注册页**：Outlined Text Field 带浮动标签；字段错误归属到字段，通用服务错误放在表单区域；失败后保留输入。
- **游戏目录**：使用 Feed/Card 模式，展示名称、人数、对局状态和唯一主要操作。
- **游戏准备页**：使用 List Item；在线、离线和忙碌使用明确状态文案，可补充辅助视觉。
- **活跃对局卡**：主要操作为“继续对局”；取消未开始对局是低强调危险操作。
- **平台操作**：更新、设置等不得与开始或继续游戏争夺主操作层级。

每个页面最多有一个最高强调 Filled Button。次级操作使用 Filled Tonal 或 Outlined，低频和取消操作使用 Text Button。加载、空状态和错误状态占据稳定布局区域，避免内容出现后大幅跳动。

## 11. 游戏 Core Contract 与 UX Profile

### 11.1 Core Contract

所有游戏无论是否采用公共壳层，都必须满足第 3.1 节规则。公共语义属于平台契约，可见布局属于游戏选择。

### 11.2 Lightweight Board Profile

适合五子棋等轻量、回合制、固定棋盘游戏，可采用轻量浮动壳层：

- 浮动返回入口使用至少 48dp 触控区域。
- 连接状态只在连接、重连或失败时突出显示。
- 回合、玩家身份和待确认动作由游戏 HUD 展示。
- 棋盘占据主要视觉区域，次级操作放在棋盘外。
- 认输和取消使用公共确认 Dialog。

该 Profile 是 MAY，不是所有游戏的默认模板。

### 11.3 Immersive Profile

适合动作、角色扮演或已有完整 HUD 的游戏：

- 默认不显示 Gamebox 可见壳层。
- Android 返回键打开游戏自己的暂停或退出界面。
- 平台级故障可以临时覆盖显示，但不能长期占据画面。
- 游戏视觉组件可以完全定制，但公共状态、恢复、返回与运行时证据要求不变。

### 11.4 首批共享 Godot 组件

首版只提供真实跨游戏的组件：

- 返回控制
- 连接与重连状态
- 通用 Snackbar
- 危险操作确认
- 加载遮罩
- 结算与返回大厅面板

棋盘格、角色状态、计分方式和其他玩法组件保留在游戏模块中。只有出现第二个真实使用方时，才把游戏专属组件提升为共享组件。

### 11.5 密集玩法目标例外

棋盘交点等玩法必要目标可能无法达到 48dp。该例外只适用于玩法区域，不适用于返回、确认、菜单等公共控件，并必须同时满足：

- 整块玩法区域连续命中，没有不可点击缝隙。
- 输入吸附到最近合法目标，并解决相邻目标歧义。
- 按下、待确认、接受和拒绝均有清晰反馈。

## 12. 范围排除与自动化契约

本轮及后续 Gamebox Material 3 UX 不包含无障碍合规、TalkBack、读屏语义/role/live region、`AccessibilityServer` 探测、焦点顺序、放大字体验收、WCAG 对比度阈值或 reduced-motion 门禁，不以这些能力决定完成状态。

现有 Flutter `Semantics.identifier`、`Key`、UI Automator selector 和 Android host-smoke selector 仅作为自动化兼容契约保留，不产生新的读屏实施义务。普通 UX 仍要求公共控件避开状态栏、导航手势区、刘海和圆角裁切区域，正常字号下文案可重排/滚动且不截断主要操作。

## 13. 游戏接入声明

每个新游戏必须在接入文档或注册描述中声明：

- `gameId` 与显示名称
- 默认屏幕方向
- 采用的 UX Profile，或说明只采用 Core Contract
- 使用的游戏主题扩展色及其语义
- 支持的输入方式
- 关键 UI 状态和截图清单
- 对 SHOULD 的任何偏离及替代措施

暂不把这些声明全部设计成运行时 DSL。只有实现或自动验证确实需要的字段才进入代码注册表，其他内容先保留在接入文档中。

## 14. 验证策略

### 14.1 Skill 验证

- 在编写 skill 前，用真实的 Gamebox UI 审计、Flutter 改造、Godot 游戏接入和完成验收任务记录无 skill 基线，确认它实际遗漏或误判的规则。
- 入口 metadata、目录结构、引用路径和渐进加载通过 skill 结构校验。
- skill 必须在与基线相同的任务和至少一组新任务上完成正向验证，能按平台加载正确参考、识别 MUST/SHOULD/MAY、阻止未取得运行时证据的完成声明。
- skill 内容发生修改时重新执行相关场景；只凭阅读文案不能视为验证通过。

### 14.2 令牌验证

- JSON schema 和必需角色完整性。
- 颜色容器与 `on-*` 配对。
- 数值类型、单位和受控枚举。
- Dart/GDScript 生成结果与 token 源无漂移。
- 业务 UI 中新增硬编码公共颜色、字号、圆角和动效的定向检查。

### 14.3 组件验证

Flutter Widget Test 与 Godot 场景测试覆盖：

- 默认、按下、禁用和 pending
- 加载、错误、空状态和成功
- light 与 dark scheme
- 正常字号与长文案重排
- 文案增长和安全区域

### 14.4 流程验证

关键流程至少包括：

- 注册与身份恢复
- 游戏目录与对手选择
- 游戏启动失败和重试
- 待确认落子与服务端接受／拒绝
- 断线、重连和权威快照恢复
- 认输／取消确认
- 结算与返回大厅

联机游戏必须继续使用实际双设备流程验证跨端状态。确定性伪服务可以证明 UI 状态布线，但不能替代真实联机边界。

### 14.5 实际运行时视觉证据

任何影响用户界面的改动，都必须运行实际构建后的 Android App 或 Godot 游戏并截图。Mock、Visual Companion、静态渲染、Golden Test 和源码检查都不能替代目标运行时截图。

- 截图覆盖相关状态和实际视口。
- 一个截图不能证明全部变化时提供多张。
- 截图不得包含邀请码、访问令牌、用户私有信息或其他敏感数据。
- 截图无法完成时必须报告精确阻塞，并明确视觉验证尚未完成。

### 14.6 手机验收矩阵

- App 页面覆盖典型窄屏和典型大屏手机。
- 每个游戏只验证其声明的默认方向。
- 关键页面覆盖明暗主题、正常字号和长文案。
- 游戏至少覆盖默认、pending、重连、错误与结算状态中受本次修改影响的部分。

## 15. 迁移顺序

### 阶段 1：交付并验证 Skill

建立 `.agents/skills/gamebox-material-3-ux/`，把本设计中可执行的规范拆入入口工作流与按需参考文件。先记录无 skill 基线，再进行结构校验和真实任务场景验证；以单独、可审查的提交完成第一项交付。该阶段不修改用户界面。

### 阶段 2：使用 Skill 审计现状

以已验证的 skill 审计 Flutter App 和 Godot 五子棋，输出按 MUST、SHOULD、MAY 分类的差距、受影响流程与截图清单。审计结果决定后续改造范围，不把尚未存在的游戏纳入本轮实现。

### 阶段 3：基础令牌

建立 token schema、协作青绿明暗主题、生成器、Flutter/Godot 适配器和漂移检查。该阶段不借机重写无关业务逻辑。

### 阶段 4：Flutter App

建立 App 公共组件，依次迁移注册、游戏目录、对手选择和更新反馈。每迁移一个流程就完成组件测试、实际 Android 运行和截图。

### 阶段 5：Godot 与五子棋

建立 Core Contract 组件和 Lightweight Board Profile，以五子棋作为首个接入样例。保留玩法逻辑、网络协议和服务端权威边界，只调整呈现、交互反馈与布局。

### 阶段 6：验收门禁

将令牌同步、组件测试和设计系统检查接入现有验证脚本。实际运行时截图保留为可审查证据，不把截图文件本身当作唯一自动断言。

## 16. 版本治理

- 设计系统使用独立语义版本号，并在 token 元数据和接入文档中记录。
- 首个可执行的 Gamebox 设计系统版本从 `1.0.0` 开始。
- 修改 token 名称、公共交互语义或组件接口属于破坏性变更，需要迁移说明。
- 调整数值但不破坏接口至少提升次版本，并重新生成两端映射。
- 单个游戏的场景美术调整不提升设计系统主版本。
- 偏离 MUST 不能只写代码注释，必须在接入文档中记录原因、影响和替代措施。

## 17. 明确不做

首版不包含：

- 跟随 Android 壁纸的动态颜色
- 平板、折叠屏、ChromeOS 或桌面布局
- 强制所有游戏使用同一个可见壳层
- 跨 Flutter/Godot 共享渲染代码
- 直接复制或在运行时依赖开发者机器上的通用 Material 3 skill
- 把全部游戏声明提前做成复杂运行时 DSL
- 为尚未出现第二个使用方的玩法组件建立通用抽象
- 全面追逐只在部分平台可用的 Material 3 Expressive API
- 无障碍合规、辅助技术支持或无障碍验收门禁

## 18. 完成标准

### 18.1 Skill 交付完成

只有同时满足以下条件，第一项交付才算完成：

1. 仓库内存在可发现、可版本化、自包含的 Gamebox Material 3 UX skill。
2. skill 包含权威规范、Flutter/Godot 平台指导、审计流程和验收清单，且不与其他项目文档维护两份相互竞争的规范正文。
3. skill 通过结构校验、无 skill 基线对比和真实任务正向验证。
4. skill 以独立、可审查的任务范围提交；该提交不混入 UI 改造。

### 18.2 现有改造完成

只有同时满足以下条件，第二项交付才算完成：

1. 令牌源、schema、两端生成结果和文档一致。
2. Flutter 与 Godot 使用语义令牌，没有新增无理由的公共硬编码样式。
3. 受影响组件和流程测试通过。
4. 实际 Android App 或游戏完成目标运行时验证。
5. 相关 UI 状态有无敏感信息的截图证据。
6. 当前仓库统一验证门禁通过。
7. 最终审查再次使用已交付的 skill，且审计中受本轮约束的 MUST 均已满足；未采用的 SHOULD 有记录理由和替代措施。

## 19. 规范依据

- [Material Design 3](https://m3.material.io/)
- [Material 3 interaction states](https://m3.material.io/foundations/interaction/states/overview)
- [Material Design for Flutter](https://docs.flutter.dev/ui/design/material)
- [Flutter Material 3 migration](https://docs.flutter.dev/release/breaking-changes/material-3-migration)
- [Flutter Material 3 ColorScheme roles](https://docs.flutter.dev/release/breaking-changes/new-color-scheme-roles)

外部 Material 文档用于定义设计语义；本文件记录 Gamebox 的范围、Profile、验证和治理决策。第一项交付完成后，执行任务以 skill 中的权威规范与令牌源为准。
