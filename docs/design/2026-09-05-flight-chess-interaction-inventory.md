# 飞行棋 MVP 完整交互点清单

> 历史审计快照：下文“现有实现”和迁移缺口记录本日 HTML→Godot 迁移前的状态。后续 Godot 布局、图标计数、选择确认、叠机选择、移动/撞机/抵达动效及异常状态的实现与复核，以 [HTML / Godot 对照验收](2026-09-05-flight-chess-html-godot-acceptance.md) 为准。大厅、昵称传递、生命周期、服务端守卫等跨边界条目不因本次纯 Godot 验收而关闭。

> 日期：2026-09-05
>
> 范围：从 Flutter 大厅进入两人飞行棋，到 Godot 对局、网络恢复和终局返回的全旅程
>
> 用途：产品、UX、客户端、服务端和测试共同评审；不是新规则提案，也不代表文档中的建议已被批准。

## 1. 证据分类与阅读方法

本文严格区分以下四类内容：

| 标记 | 含义 | 本文的处理方式 |
|---|---|---|
| **R · 权威规则** | 已写入产品 profile、封闭协议或服务端权威规则的行为 | 客户端只展示和提交意图，不自行改写结果 |
| **I · 现有实现** | 当前 Flutter、Android host、Godot、Go 服务或测试可直接证明的事实 | 记录现状，不默认其就是最终 UX |
| **MUST · 共享 UX 必须项** | Gamebox Material 3 UX 标准的交互底线 | 任何重设计都必须保留，除非修订共享标准 |
| **REC · 建议反馈** | 为了让现有规则可理解、可操作、可恢复而建议的表现 | 是评审输入，不是规则 |
| **OPEN · 未定义/歧义** | 现有权威来源未说明，或实现之间存在语义张力 | 必须由产品/工程确认，不在 UX 中猜测补齐 |

优先级使用 `P0`（阻断规则理解、操作安全或一致性）、`P1`（显著影响对局理解与恢复）、`P2`（品质和愉悦度）。

### 权威性边界

- 产品与视觉边界以 [Flight Chess profile](profiles/flight-chess.md) 为准：两人、红/黄阵营、横屏、手动选棋、轻量叠机。
- 传输、`revision`、`actionId`、快照与事件连续性以 [protocol/README.md](../../protocol/README.md) 为准。
- 掉次、合法棋子、路径解算、捕获与胜利以 [server flightchess rules](../../server/internal/games/flightchess/rules.go) 为权威实现。
- 匹配生命周期、幂等、过期修订、认输、取消与遗弃以 [match service](../../server/internal/matches/service.go) 为准。
- 共享 UX 底线来自 [ux-standard.md](../../.agents/skills/gamebox-material-3-ux/references/ux-standard.md) 和 [godot-games.md](../../.agents/skills/gamebox-material-3-ux/references/godot-games.md)。
- 预览态、fixture 和测试是证据，不是额外规则来源。

## 2. 权威规则摘要

| 主题 | R · 已确定规则 | 交互含义 |
|---|---|---|
| 人数与阵营 | 双人对局，每方 4 架飞机。平台 `black` 映射棋盘红方，`white` 映射棋盘黄方。 | UI 必须以用户可理解的“红方/黄方”显示，不暴露 `black/white`。 |
| 先手 | 平台 `black`/棋盘红方先手；发起者的颜色是建局时分配的，不保证先手。 | 大厅和对局都要清晰标准“我的阵营”与“谁先手”。 |
| 棋盘 | 52 格顺时针主航线，四色基础起点依次相隔 13 格；双人使用对角的红/黄方，它们的起点相隔 26 格。每色有 6 格终点航线。 | 路径表现必须匹配服务端进度语义，不能用 Ludo 十字棋盘推测。 |
| 回合阶段 | `awaiting_roll` 只能掷骰；有合法飞机后进入 `awaiting_move`，只能选 1 架。 | 掷骰与选棋是两个服务端确认步骤，均不能乐观落子。 |
| 掷骰 | 骰子由服务端生成 1–6，请求 payload 为空对象。 | 按下后进入 pending；只有 `roll.accepted` 才能展示最终点数。 |
| 起飞 | 只有掷出 6，机库飞机才是合法选项；选中后从机库到起飞点。 | 即使只有 1 架可移，profile 仍要求手动选棋，不自动代选。 |
| 普通移动 | 起飞点的飞机按骰子点数进入主航线；主航线和终点航线飞机按点数前进。 | 可选集合必须来自权威 `movablePieceIndices`，不由视觉层独立判定。 |
| 跳跃/飞跃 | 在自己路程上落到进度 18 自动长捷径到 30；其他满足 `progress % 4 == 2` 且小于 50 的落点自动跳 4 格；跳到 18 时继续长捷径，记为 `jump_shortcut`。 | `none/jump/shortcut/jump_shortcut` 都是服务端结果，不提供“是否跳”的额外选择。 |
| 叠机 | 同色飞机可在同一位置叠放，不形成拦路。 | 需要数量徽标和可触达的组目标；移动组内哪架见 OPEN-01。 |
| 捕获 | 只有最终落点在主航线时检查捕获；落在对手位置会一次捕获该格全部对手飞机并送回机库。 | 捕获发生在跳跃/捷径解算后的最终落点；现有规则没有额外的安全格保护。 |
| 到达 | 确认设计：必须恰好停在终点；超点先到终点，再原路退回多余步数。 | 经过终点不计抵达；第 4 架精确到达立即胜利。HTML、服务端与 Godot 判定已同步；Godot 已接入确认后的反弹动画。 |
| 无合法棋子 | 非 6 且当前没有任何合法飞机时，掷骰事件直接切换回合，不进入选棋阶段。 | 这不是错误；应短暂告知点数和“无法移动，已换手”。 |
| 掷出 6 | 完成移动后保持本方回合；再次掷出 6 仍按同一规则处理。 | UI 只需提示可再掷一次，不显示连续 6 计数或风险。 |
| 结束 | 4 架飞机全部到达时结果为 `goal`；已开始对局可认输，对手获胜，结果为 `resignation`。 | 结果页只能在权威终局快照/事件后出现。 |
| 平台终止 | 零步对局可取消；双方离线满 24 小时可被标记 `abandoned`，无胜者。 | 取消与认输必须有不同后果文案；`cancelled/abandoned` 不得显示虚假胜负。 |
| 版本与幂等 | 每个 action 携带 `expectedRevision` 和 `actionId`。相同 actor/actionId/语义重试返回原提交；相同 actionId 换语义为 `action_conflict`；过期修订为 `stale_revision`。 | 客户端需阻止连点；过期时先重新同步，不重复播放已确认效果。 |

## 3. 全旅程与状态机

```text
Flutter 登录态
  → 大厅飞行棋卡片 loading / error / idle / active
  → [idle] 选对手 → 列表 loading / error / empty / ready → create pending
  → [active] 继续对局
  → 申领 launch ticket → Android GameActivity → Godot connecting
  → connected + initial snapshot
  → active.awaiting_roll
      → roll_pending
      → accepted(no movable) → 对手 awaiting_roll
      → accepted(movable) → active.awaiting_move
          → move_pending
          → accepted(roll == 6) → 本方 awaiting_roll
          → accepted(roll != 6) → 对手 awaiting_roll
          → accepted(fourth finished) → finished.goal
  → resign_pending → finished.resignation
  → cancelled / abandoned
  → result → 返回 Flutter 大厅并刷新

任何 Godot 非终局状态
  → disconnected / reconnecting（保留最后确认棋盘，锁定权威操作）
  → resnapshot
  → 恢复到最新权威状态，或 failed → 返回大厅
```

状态机有三条正交轴，设计时不能混成一个“状态文案”：

1. **平台生命周期**：`active / finished / cancelled / abandoned`。
2. **玩法阶段**：`awaiting_roll / awaiting_move`，加上本地 `roll_pending / move_pending / resign_pending`。
3. **连接与同步**：`connecting / connected / reconnecting / failed / closed`，以及 `awaiting_snapshot`。

## 4. 交互点清单

以下每一项都列出 actor/触发、前置、用户操作、立即反馈、pending/锁定、服务端结果和恢复。“建议反馈”不会改写权威规则。

### 4.1 Flutter 大厅、对手与启动

| ID | Actor / 触发 | 前置 | 用户操作 | 立即反馈 | Pending / 锁定 | 接受结果 | 拒绝/恢复 | 依据与建议 |
|---|---|---|---|---|---|---|---|---|
| LOB-01 会话恢复 | App 启动/回到前台 | 本地可能有凭证 | 无，或按登录/重试 | 显式会话 loading | 身份未确认前不展示可执行的对局操作 | 进入大厅，启动飞行棋状态查询 | 安全错误、重试/重新登录 | I + MUST；不显示 token/URL/内部码。 |
| LOB-02 卡片载入 | HomeController 启动或前台刷新 | 已登录 | 等待；失败后点重试 | 卡片 loading，不用空闲态假充 | 仅阻塞该卡片的建局/续局 | 显示 idle 或 active | 卡片内错误+重试，不影响其他游戏 | I + MUST。现有控制器前台每 10 秒轮询，后台暂停、恢复时立即刷新。 |
| LOB-03 空闲卡片 | 对局状态返回 idle | 无活跃飞行棋对局 | “选择对手”或“战绩” | 按压反馈、进入相应页 | 导航过程防连点 | 显示对手列表/飞行棋战绩 | 导航失败保持当前卡片 | I；战绩是全旅程入口，但不影响局内规则。 |
| LOB-04 对手列表 | 页面进入/重试 | 已登录且无活跃局 | 等待、返回、重试 | loading → 列表/空态/错误 | load 请求去重 | 列表排除自己，显示昵称、在线/离线、可用/忙碌 | 保留页面并给重试 | I + MUST；离线但空闲的对手现有实现仍可选。 |
| LOB-05 选对手建局 | 本地玩家 | 对手可用，自己无活跃局 | 点选对手行 | 该行显示“正在创建对局”+进度 | 创建期间锁定全列表的重复建局 | 创建并分配阵营，继续申领 ticket/启动 | `active_match_exists`、`opponent_busy`等用安全文案告知；刷新 active match 以恢复“已建成但启动失败” | I + MUST。 |
| LOB-06 活跃局卡片 | 状态返回 active | 当前用户是对局成员 | “继续对局”或“战绩” | 继续按钮 pending | 申领 ticket/启动期间锁定重复操作 | 进入 Godot 对局 | ticket/启动失败留在卡片并允许重试 | I。现有卡片显示对手、本方阵营与修订。`REC P1`：不要把每次 roll/move 都增长的 `revision` 称为“当前步数”。 |
| LOB-07 取消未开始局 | 任一玩家 | 大厅所见 match revision = 0 | 点“取消未开始对局”，二次确认或保留 | 对话框指明“双方返回空闲” | 确认后按钮 pending，防重复 | 终止为 `cancelled`，释放双方 slot，刷新 idle | `match_not_cancellable` 时刷新最新对局并保留可继续入口 | R + I + MUST。服务端 Flight Chess 取消守卫存在 OPEN-06，不把大厅的 revision=0 条件当作服务端已完整证明。 |
| LOB-08 战绩 | 本地玩家 | 已登录 | 进入、返回、错误重试 | 飞行棋专属 loading/空/统计态 | 请求期间防重入 | 展示可用历史 | 局部错误与重试 | I；不得把 `cancelled/abandoned` 算作虚假胜负。 |
| ENT-01 Android 启动门 | Flutter/host | 有合法 gameId、matchId、ticket、wsUrl | 用户无额外操作 | Flutter 续局保持 pending | host 阻止重复 GameActivity | 无活跃游戏进程时启动新实例；有活跃进程时现有逻辑将其带到前台 | Flutter 收到安全启动失败 | I；“要打开的 match 与已活跃进程不同”见 OPEN-09。 |
| ENT-02 初始连接 | MatchClient 启动 | 启动参数校验通过 | 等待或 Back 返回 | 显式“连接对局/正在同步棋盘” | 未收到初始快照前锁定 roll/move/resign | connected + contiguous snapshot 后呈现权威棋盘 | ticket 无效、对局不存在或同步失败时提供返回大厅 | I + MUST。 |
| ENT-03 启动参数/客户端构建失败 | Godot | config 无效或 MatchClient 不可用 | 点返回 | “无法进入对局，请返回大厅” | 全部对局操作锁定 | 无 | 回大厅后重新查询 active match，可再续局 | I + MUST。 |

### 4.2 身份、回合与局内全局操作

| ID | Actor / 触发 | 前置 | 用户操作 | 立即反馈 | Pending / 锁定 | 权威结果 | 拒绝/恢复 | 依据与建议 |
|---|---|---|---|---|---|---|---|---|
| ID-01 本地/对手身份 | 初始快照 | 双方 userId 已绑定阵营 | 无 | 左侧玩家卡显示“你 · 红/黄”、对手阵营和飞机统计 | 无 | `black→红` 且先手，`white→黄` 且后手 | 身份无法一致解析则强制同步/返回 | R + I。`REC P1`：将 Flutter 已有的对手昵称安全传到游戏层；当前 Godot 对手卡主文案实际是在线状态。 |
| ID-02 飞机摘要 | 每次快照/事件 | 有已确认棋子状态 | 无 | 双方卡显示“已抵达/在途/待机”数 | pending 时仍显示最后确认计数 | 服务端事件后更新 | 同步失败不伪造新数字 | I + MUST。 |
| TURN-01 轮到自己掷骰 | 快照/事件 | active + connected + synced + local `nextColor` + `awaiting_roll` + no pending | 点掷骰 | 按压反馈，立即切换到 roll pending，不提前显示点数 | 锁定掷骰、飞机和认输的重复提交 | 见 ROLL-01–05 | 恢复到可操作状态或进入重同步 | R + I + MUST。 |
| TURN-02 轮到自己选棋 | `roll.accepted` | active + connected + synced + local turn + `awaiting_move` + movable nonempty | 点任一合法飞机 | 可移飞机高亮，按下态明确 | 点中并提交后锁定所有飞机和掷骰 | 见 SEL/MOVE | 拒绝后重新展示当前权威合法集合 | R + MUST。 |
| TURN-03 对手回合 | 快照/事件 | active + `nextColor != local` | 只能 Back/认输（若可用） | 明确“对手掷骰/选棋中”，保留棋盘可读 | roll 和飞机不可交互 | 对手权威事件到达后更新 | 离线仅是 presence，不自行判负 | R + I。 |
| TURN-04 对手在线状态 | presence 事件 | 双方已连入该 match | 无 | 对手卡在“在线/离线/未知”间更新 | presence 不改变游戏 revision 或锁定规则 | 只是连接提示 | presence 波动不清空棋盘、不显示胜负 | I + MUST。 |
| NAV-01 可见 Back | 本地玩家 | 任意局内状态 | 点左上返回 | 按压反馈后退出 GameActivity | 防重复退出，释放客户端连接 | 对局不变，大厅可续局 | 返回大厅后刷新 | I + MUST；Back 绝不等于认输、取消或放弃对局。 |
| NAV-02 Android Back / `ui_cancel` | 系统/键盘 | 认输对话框开启或普通局内态 | 系统 Back/Esc | 先关闭认输对话；否则等价 NAV-01 | 无二次触发 | 对局不变 | 同 NAV-01 | I + MUST。 |

### 4.3 掷骰交互

| ID | Actor / 触发 | 前置 | 用户操作 | 立即反馈 | Pending / 锁定 | 服务端接受 | 拒绝/恢复 | 依据与建议 |
|---|---|---|---|---|---|---|---|---|
| ROLL-01 提交掷骰 | 本地当前玩家 | TURN-01 全部成立 | 按下并释放“掷骰子” | pressed → 文案“确认中…”；骰子保持最后权威值/待机态 | pending 携带 actionId + expectedRevision，所有权威操作锁定 | `roll.accepted` 回传 value 和 movable，revision +1 | 本地发送失败立即恢复；服务拒绝清 pending、安全告知；stale 请求快照 | R + I + MUST。`REC P0`：将“请求已发出”与“服务端已产生点数”视觉区分。 |
| ROLL-02 有合法飞机 | `roll.accepted` | movable nonempty | 不需再确认骰子 | 显示确认点数和可移飞机，进入选棋提示 | roll pending 清空，move 尚未 pending；roll 按钮锁定 | `phase=awaiting_move`，`dice=value` | 若事件不连续/无效，不展示局部结果，转快照同步 | R + I + MUST。 |
| ROLL-03 非 6 无合法飞机 | `roll.accepted` | value != 6，movable empty | 无 | `REC P0`：先短暂显示“掷出 N，没有飞机可移，已换手” | 不开启选棋，本方所有操作锁定 | `phase=awaiting_roll`、dice 回 0、nextColor 切换 | 快照同步保底 | R。I：当前 controller 只看最终 state，不消费 accepted-roll payload，因而通常直接显示对手回合。 |
| ROLL-04 掷出 6 | `roll.accepted` | value=6，movable nonempty | 按规则选棋 | 显示 6 和合法棋子 | 完成移动前不能再掷 | 移动接受后保持本方 `awaiting_roll` | 移动拒绝不消耗该次点数 | R；连续掷出 6 不累计惩罚。 |
| ROLL-05 非当前玩家/错阶段点击 | 用户或自动化过期点击 | roll disabled，或状态在点击后已变 | 点掷骰 | disabled 无提交；若已发出则 pending | 不生成第二个本地 action | 服务可返回 `not_your_turn/invalid_move/stale_revision` | 清 pending、恢复最新可操作态；stale 先同步 | R + I + MUST。 |

### 4.4 选棋、移动、跳跃、叠机与捕获

| ID | Actor / 触发 | 前置 | 用户操作 | 立即反馈 | Pending / 锁定 | 服务端接受 | 拒绝/恢复 | 依据与建议 |
|---|---|---|---|---|---|---|---|---|
| SEL-01 合法飞机可见 | `roll.accepted` | TURN-02 | 查看棋盘 | 仅 `movablePieceIndices` 对应的本方飞机有可选视觉 | 尚未点击时不是 pending | 无 | 同步变化后重算展示 | R + I；不自动代选唯一合法飞机。 |
| SEL-02 宽容触控 | 本地玩家 touch down | 有可选飞机 | 在飞机及其宽容区域内按下 | 目标缩放/按压反馈 | 按下不提交 | 无；只在有效 release 时发送 | 移出目标、取消或在远处释放则清按压态且不提交 | I + MUST；profile 要求 48dp 级别宽容目标，棋盘密集区可使用连续热区+吸附最近合法棋子。 |
| SEL-03 无效点击 | 本地玩家 | 对手飞机、不合法本方飞机、空白或远处 | 点击 | 不选中、不移动 | 不发送 action | 无 | 保留当前合法集合；可选的轻量视觉提示不得误伤触 | I + MUST。 |
| SEL-04 叠放组选择 | 本地玩家 | 同位有 2–4 架同色飞机，其中至少一架合法 | 点击叠机组 | 显示叠层和数量徽标，整组为一个命中区 | release 后只能发送一个 pieceIndex | 服务端移动该索引的 1 架飞机 | 拒绝则整组恢复可选 | R + I；当前 board 在等距叠机中选取索引最小的合法飞机。该用户语义未被 profile 定义，见 OPEN-01。 |
| MOVE-01 提交移动 | 本地当前玩家 | 点数已确认，飞机在 movable 中 | 在同一合法目标上 release | pressed → selected → move pending；不先移动棋子 | pending 记录 pieceIndex/actionId/revision，锁定 roll/move/resign 重复提交 | `move.accepted` 返回 from/to/roll/effect/captured，revision +1 | 发送失败或权威拒绝后恢复选择能力；stale 先同步 | R + MUST。I：当前提交后 `_selected_index` 在同步 UI 时清空，没有飞机级 pending 标记。`REC P0`：保留该架的 pending 轮廓。 |
| MOVE-02 普通前进 | `move.accepted(effect=none)` | 移动合法 | 无 | `REC P0`：按事件中 from→to 显示可追踪移动，然后更新阵营摘要 | 表现期间不允许提前操作下一权威步 | 棋子落在 to；roll=6 保留回合，否则换手 | 事件不连续时跳过动画、按快照收敛 | R。I：当前直接刷新到最终位置。 |
| MOVE-03 起飞 | `move.accepted` | from=hangar，roll=6 | 无 | `REC P0`：机库飞机到起飞点的明确轨迹+“起飞成功，可再掷一次” | 表现完成前锁定 | to=launch，保持本方 awaiting_roll | 同 MOVE-01 | R。 |
| MOVE-04 从起飞点入主航线 | `move.accepted` | from=launch | 无 | `REC P1`：按 roll 走到自己主航线进度，不要仅动到第一格 | 同 MOVE-02 | to 由进度解算 | 同 MOVE-02 | R；这是容易被视觉原型误表达的规则边界。 |
| MOVE-05 跳 4 格 | `move.accepted(effect=jump)` | 最初落点满足跳跃规则 | 无额外选择 | `REC P0`：先表现按点数落位，再沿自动跳跃到最终格，用短文案/音效标记“跳跃” | 整个权威效果串为一次锁定 | to 是跳后最终位置 | 恢复快照不强行补播历史动画 | R。I：事件有 effect，controller 未使用。 |
| MOVE-06 长捷径 | `move.accepted(effect=shortcut)` | 初始落在自己 progress 18 | 无额外选择 | `REC P0`：显示落点、快捷航线和 progress 30 最终位置 | 同 MOVE-05 | to 是捷径后位置 | 同 MOVE-05 | R。 |
| MOVE-07 跳跃+长捷径 | `move.accepted(effect=jump_shortcut)` | 普通跳跃到 progress 18 | 无额外选择 | `REC P0`：保持“普通前进 → 跳跃 → 长捷径”的可读顺序 | 同 MOVE-05 | to 是 progress 30 | 同 MOVE-05 | R；服务端规则测试覆盖该组合。 |
| MOVE-08 形成叠机 | `move.accepted` | to 已有同色飞机 | 无 | 移动完成后合并为叠层+数量徽标 | 移动 pending 期不预先改变数量 | 同色全部保留在该位置，不阻挡通过 | 事件拒绝保持原组合 | R + I。 |
| MOVE-09 捕获一架/叠机 | `move.accepted` | 最终 to.zone=main 且有对手飞机 | 无 | `REC P0`：本方落位后突出 captured 数，按 `capturedPieceIndices` 显示对手逐架回机库 | 捕获为同一 accepted move 的不可分割部分 | 该格所有对手飞机回 hangar | 无事件则不预先捕获；快照恢复直接收敛最终位置 | R。I：controller 未使用 captured payload。 |
| MOVE-10 进入终点航线 | `move.accepted` | 主航线进度越过 50 且未超过精确到达 | 无 | `REC P1`：主航线转入本方 6 格航线，已到达棋子与在途棋子明显区分 | 同 MOVE-02 | to.zone=home | 同 MOVE-02 | R。 |
| MOVE-11 超出终点 | 选机 → 确认移动 | home 飞机需要的点数小于本次 roll | 可选该飞机，预览往返路径和最终落点 | 逐格走到终点，再原路退回剩余步数 | 同 MOVE-02 | 仍在 home；经过终点不退场、不计抵达、不触发胜利；6 点仍再掷 | 同 MOVE-02 | HTML、服务端与 Godot 已实现超点可选和反弹结算；Godot 确认后逐格往返，动画中锁定输入，重连取消动画。路线预览仍仅 HTML 已实现。 |
| MOVE-12 精确到达 | `move.accepted` | home index + roll = 6 | 无 | `REC P0`：飞机进入 finished 区，更新“已抵达”计数 | 效果完成前锁定 | to.zone=finished；非第 4 架时按骰子是否为 6 决定续掷/换手 | 同 MOVE-02 | R。 |
| MOVE-13 第四架到达 | `move.accepted` | 移动后本方 4 架 finished | 无 | 完成抵达表现后进入结果；不被额外掷骰提示打断 | 游戏操作全部锁定 | status=finished, result=goal, winner=本地 actor | 若终局事件与快照冲突，强制同步/返回 | R + MUST。 |
| MOVE-14 非法/过期选棋 | 用户或自动化 | 棋子不在 movable、非本方回合、阶段已变或 revision 过期 | 点飞机 | 本地可拦截则无提交；已提交则显示 pending | 不产生并行本地 action | `not_your_turn/invalid_move/stale_revision` | 安全文案，清 pending，保留已确认棋盘；stale 同步后恢复新的合法选择 | R + I + MUST。 |

### 4.5 认输、结果、取消与返回

| ID | Actor / 触发 | 前置 | 用户操作 | 立即反馈 | Pending / 锁定 | 服务端接受 | 拒绝/恢复 | 依据与建议 |
|---|---|---|---|---|---|---|---|---|
| RES-01 打开认输确认 | 本地玩家 | active、已有至少一次对局 revision、connected/synced、no pending、本人为成员 | 点“认输” | 打开模态对话：认输后本局立即结束；“继续对局/确认认输” | 对话期间棋盘不提交操作 | 无，直到确认 | 取消/Back 只关闭对话，不改变对局 | I + MUST；后果必须按名称清晰，不用泛化“确定吗”。 |
| RES-02 确认认输 | 本地玩家 | RES-01 对话开启，条件仍有效 | 点“确认认输” | 关闭对话，显示等待服务器确认 | resign pending 锁定重复认输与其他权威操作 | `flight_chess.resigned`，对手为 winner，result=resignation | 清 pending，安全错误，恢复对局和可用操作；stale 同步 | R + I + MUST。 |
| RES-03 目标胜利结果 | 权威终局 | finished + goal | 点“返回大厅”或 Back | 本地胜方显示“全员抵达”，负方显示“这局差一点” | 所有局内规则操作锁定 | 结果不再变 | 返大厅刷新 slot/历史 | R + I。`REC P1`：结果摘要应是玩家可理解的数据，不是 revision/“已确认操作数”。 |
| RES-04 认输结果 | 权威终局 | finished + resignation | 返回大厅 | 清晰显示“你已认输”或“对手已认输”与胜负 | 同 RES-03 | 对手 winner | 同 RES-03 | R + I。 |
| RES-05 对局被取消 | `platform.match.cancelled` | active 零步局在另一端被取消 | 返回大厅 | 中性“对局已取消”，不显示胜负 | 全部规则操作锁定 | status=cancelled | 返大厅后两方空闲 | R + I + MUST。 |
| RES-06 对局被遗弃 | 平台清理 | 双方离线达到服务端阈值 | 重连后查看，或返回大厅 | 中性“对局已结束”或“长时间无活动，已关闭” | 全部锁定 | status=abandoned，无 winner/result | 释放 slot，返回大厅 | R；24 小时是平台实现事实，不表示 UI 要倒计时。 |
| RES-07 结果返回 | 本地玩家 | 任一 terminal 态 | 结果按钮/系统 Back | 退出 Godot，返回 Flutter | 防重复退出 | 无新游戏 action | 大厅 resumeForeground 立即刷新 | I + MUST。 |

### 4.6 后台、断线、重连、错误与重复动作

| ID | Actor / 触发 | 前置 | 用户操作 | 立即反馈 | Pending / 锁定 | 权威结果 | 拒绝/恢复 | 依据与建议 |
|---|---|---|---|---|---|---|---|---|
| NET-01 短暂断线 | transport | 已有至少一份权威快照 | 等待或 Back | 保留最后确认棋盘，显示“重新连接/棋盘会保留” | roll/move/resign 全部暂停，本地选中清空 | 无，直到重连+快照 | 当前 MatchClient 按 1/2/4/8/15 秒退避，最多 6 次；成功后安静恢复 | I + MUST。 |
| NET-02 重连快照 | MatchClient | reconnect handshake 成功 | 无 | 显示“正在同步棋盘”，仍保留旧棋盘 | 快照接受前继续锁定 | 以最新 snapshot 替换本地状态、清 pending | 快照不合法时不继续操作，强制返回 | I + MUST。 |
| NET-03 App 后台/回前台 | Android 生命周期 | 局内或 Flutter 大厅 | 切走/返回 App | `MUST`：恢复时在任何新操作前重新读取权威状态 | 后台不提交新操作；恢复同步期锁定 | 最终以 snapshot/大厅 active match 为准 | 重同步失败提供返回/重试路径 | MUST。I：Flutter 明确 pause/resume polling；Godot 依赖 transport 断线重连，未见独立的 App-resume 交互状态，见 OPEN-05。 |
| NET-04 revision gap | 收到跳号事件 | event.revision > local+1 | 无 | 进入同步状态，不应展示该事件的局部动画 | 锁定权威操作 | 发送 snapshot request，只有连续快照才恢复 | 重同步失败则返回大厅 | R + I + MUST；MatchClient 测试覆盖“缺口只请求一次快照”。 |
| NET-05 重复/旧事件 | 服务器/网络重放 | event.revision <= local revision | 无 | 不重复播放移动、捕获或结果动效 | 不新增 pending | 忽略重复事件 | 如果本地仍 pending，由匹配 actionId 的事件/错误或快照收敛 | R + I。 |
| NET-06 stale revision | 服务端拒绝 action | expectedRevision 过期 | 无额外操作 | “棋盘已更新，正在同步” | 清匹配 pending，快照完成前锁定 | 服务器随 stale 返回快照 | 快照后按新阶段恢复 roll 或选棋；不自动重播原动作 | R + I + MUST。 |
| NET-07 完全相同 action 重试 | 网络/客户端 | 同 actor + actionId + 完全相同语义 | 现有 UI 无手动“重发原动作” | 不应显示第二次移动 | 服务端保证幂等；现有 MatchClient 断线时不重播 pending action | 返回原已提交事件+当前快照 | 如请求未落库，重连快照显示旧状态后由用户再次操作 | R + I；不把服务端能力误写为当前客户端会自动重试。 |
| NET-08 actionId 冲突 | 服务端 | 相同 actionId 搭配不同语义 | 无 | “操作冲突，请重试” | 清匹配 pending | `action_conflict`，不改变棋盘 | 在当前权威状态下生成新 actionId 后由用户再操作 | R + I。 |
| NET-09 一般规则拒绝 | 服务端 | not-your-turn / invalid-move / invalid-request | 无 | 安全 snackbar：“还没轮到你/这架飞机现在不能移动/操作无效” | 清匹配 pending | 棋盘不变 | 恢复最新合法操作；若客户端已疑似过期则先同步 | R + I + MUST。 |
| NET-10 随机源/内部失败 | 服务端 | roll 时随机源失败或内部错误 | 无 | “服务暂时不可用，请稍后重试” | 清 pending，不保留假骰子 | 不提交事件，revision 不变 | 恢复掷骰能力，由用户重试 | R + I + MUST；服务测试证明失败无变异。 |
| NET-11 重连失败/凭证失效 | MatchClient | 重连次数用尽，或 `ticket_invalid/resume_expired/match_not_found` | 点连接幅的返回 | 保留最后棋盘作为不可操作背景，显示安全原因和返回下一步 | 全部操作锁定 | 无 | 回大厅重新验证会话和 active match | I + MUST。共享标准要求有“重试或返回”下一步；当前失败态仅提供返回，但已满足最低恢复出口。 |
| NET-12 收到无效快照/事件 | FlightChessState | schema、matchId、actor、from/to/effect/capture 不一致 | 只能返回 | “同步失败，请返回大厅” | 强制锁定，不套用部分事件 | 客户端拒绝本地更改 | 回大厅，重新进入时重取快照 | I + MUST。 |

### 4.7 触控、可达性与自动化契约

| ID | 契约 | 当前事实 | 重设计必须保留/完善 |
|---|---|---|---|
| TOUCH-01 公共控件 | 共享 UX | Back、认输、掷骰、对话框操作使用标准 Control | 按钮触控区至少 48×48dp，有 enabled/pressed/pending/disabled 区分，并遵循安全区。 |
| TOUCH-02 棋子 | profile + board 实现 | 连续命中半径与最近合法飞机吸附；按下缩放，同目标 release 才提交 | 保留“宽容但不误选”；远处点击、移出、取消都不提交。 |
| TOUCH-03 叠机 | profile + board 实现 | 同位飞机以叠层+数量徽标显示，命中一个组目标 | 保留数量可读性和稳定命中；组内选哪架不得随动画/层级改变而漂移。 |
| TOUCH-04 横屏与安全区 | profile + controller | 1920×1080 逻辑画布，最小 960×540，感应横屏，左侧/棋盘/右侧三栏在安全区内布局 | 必须在 960×540 和 2400×1080、深/浅色、左/右 safe inset 下可读可点；窄横屏不得让文案覆盖棋盘。 |
| AUTO-01 准备标记 | E2E 日志 | `GAMEBOX_GODOT_READY game=flight_chess match=...` 与棋盘 state marker | 节点重命名/布局重构不得破坏标记语义。 |
| AUTO-02 响应式目标 | controller + E2E | `automation_targets()` 输出规范化 `roll/red0/yellow0/resign/confirm` 坐标 | 保留名称、范围和对应可见控件；禁止固定像素坐标。 |
| AUTO-03 Pending/结果标记 | controller + E2E | 状态、revision、pending 和 result 通过日志可观测 | 保留机器可解析的稳定标记，不从翻译后的可见文案反解状态。 |
| AUTO-04 预览态 | preview script | `ready/rolled/pressed/selected/stacked/full-game`；full-game 另截取 launch/opponent-in-flight/jump/shortcut/first-finished/result | 对局外 UX 重设计需新增 loading/pending/reconnecting/failed/resign/result 等状态，但不得把 preview 当生产联机验收。 |
| AUTO-05 无障碍边界 | shared Godot guidance | Godot 自定义画布的无障碍是明确非目标 | 不虚假宣称 TalkBack/读屏通过；仍要保持对比度、颜色非唯一线索、尺寸与按压反馈。 |

## 5. 跨状态 UX 必须项

以下要求适用于所有上述交互，不应只在“理想联网”态成立：

1. **服务器权威**：掷骰、移动、捕获、胜负和认输在 accepted event/snapshot 前都不得展示为最终结果。
2. **完整状态链**：可交互动作均需 `enabled → pressed → pending → accepted/rejected`；不能只有 disabled 与结果两态。
3. **Pending 防重**：本地只允许一个未决权威动作；提交期间必须有可见状态，并锁定所有重复/冲突入口。
4. **拒绝可恢复**：拒绝后清 pending、保留最后确认棋盘，告知人能理解的原因和下一步；有效输入/选择不应无原因丢失。
5. **连接与同步不伪装空态**：首次连接显示明确 loading；重连保留最后棋盘且锁定操作；恢复 App 后先 resync 再可操作。
6. **非破坏 Back**：可见 Back、Android Back 和 Esc 都不认输、不取消、不改写对局；若危险对话开启，Back 只关闭对话。
7. **稳定文案语义**：只显示“红/黄、你/对手、点数、可移飞机、恢复方式”；不暴露 `black/white`、revision、actionId、token、URL 或内部错误码。
8. **结果权威且不混淆**：`goal/resignation/cancelled/abandoned` 需映射不同结果文案；中性终止不显示胜负。
9. **触控连续且不误选**：公共目标至少 48dp；棋盘使用宽容连续命中区，但远处点击不吸附，释放前可取消。
10. **不破坏自动化契约**：重设计可改布局，但要保留对局 ready/state/pending/result 标记和规范化目标名称。

## 6. 未定义或存在歧义

这些项不应被 UX 原型暗中“定规则”。

| ID | 问题 | 已知事实 | 需要的决策/工程动作 | 优先级 |
|---|---|---|---|---|
| OPEN-01 | 点击叠机组时哪架飞机移动？ | 服务端 action 必须是单个 `pieceIndex`；当前 board 对等距叠机选索引最小的合法飞机。profile 只说“叠放组为一个可点目标”，未定义组内选择。 | 确认“稳定自动选一架”还是“打开组内选择”。 | P0 |
| OPEN-02 | 权威移动的动画路径与速度 | accepted move 仅给 from/to/roll/effect/captured，客户端可依规则重建路径；快照恢复没有历史效果序列。 | 定义现场事件的表现顺序、最长锁定时间与“快照直接收敛、不补播”原则。 | P0 |
| OPEN-03 | 无合法棋子的提示节奏 | 服务在一个 roll event 中同时确定点数和换手；快照中 dice 已回 0。 | 定义一个可读但不拖慢对手操作的短暂提示，并保证重连不重复播放。 | P0 |
| OPEN-05 | Godot 进入后台又回前台的明确 resync 边界 | 共享 UX 要求恢复后先 resync；当前 Godot 主要依赖 WebSocket 状态和重连，未见独立 resume 状态。 | 定义 host/Godot lifecycle 信号和验收；若连接表面仍 connected，也要证明回前台前的状态不会过期可操作。 | P0 |
| OPEN-06 | Flight Chess “已有玩法事件后不可取消”的服务端守卫 | Flutter 只在 match revision=0 显示取消。match service 查询“已接受玩法事件”的列表包含其他游戏，但当前没有 Flight Chess roll/move 类型；相关通用测试也只使用 Gomoku。 | 补充服务端 Flight Chess 守卫与回归测试，确保不能绕过 Flutter UI 在已掷骰后取消。 | P0 |
| OPEN-07 | 512 事件上限时的用户结果 | match service 对 Flight Chess 设 512 事件上限；到达 511 个事件后 roll/move 被拒绝，仍预留一个认输终局事件。玩法/profile 未定义超限和局、强制结束或续局规则。 | 定义服务端产品策略，不能让活跃对局只剩“认输或退出”而无法继续玩。 | P0 |
| OPEN-08 | 骰子、移动、捕获的音效/触感 | profile 和共享标准没有定义；当前 dice 是静态数值控件。 | 决定是否使用音效/触感，如使用则需可关闭、不与权威结果脱节。 | P2 |
| OPEN-09 | Android host 已有活跃 GameActivity 时的目标对局校验 | 现有 launch gate 看到活跃游戏进程就 `RESUME_ACTIVE`，并未在 gate 层按新请求的 matchId/gameId 区分。 | 确认当用户从另一张 active 卡片点入时的预期：带回已打开游戏，还是显示明确冲突。 | P1 |
| OPEN-10 | 结果数据 | 当前结果面板可用数据主要是 winner/result/revision，“已确认操作数”并非玩法统计。 | 若要显示捕获数、历时等，需先定义权威数据来源；不从当前页面短期内存猜测。 | P1 |
| OPEN-11 | 协议兼容 fixture 缺口 | `protocol/fixtures` 现有兼容 fixture 都不是 Flight Chess，尽管 README 已定义 Flight Chess action/event。 | 补充 roll/move/resign/snapshot/error 的 Flight Chess 兼容 fixture，以锁定跨端语义。 | P1 |

## 7. 当前 UI/UX 缺口与优先级

### P0：下一轮互动实现前应闭环

1. **accepted event 被降级成“直接换快照”**：Godot controller 未使用 roll 的 `value/movable` 和 move 的 `from/to/effect/captured`，造成无棋可移、跳跃、捷径、捕获、精确到达都只显示棋盘瞬间跳变。超点反弹现已单独消费确认事件播放动画，其余动效仍待迁移。
2. **move pending 没有目标级反馈**：点飞机后本地 selected 很快被清掉，只剩通用“等待服务器确认”；用户不能明确看到哪架正在 pending。
3. **无合法棋子缺少因果链**：服务端在单个 accepted roll 中完成换手，当前 UI 不显示本次点数和原因。
4. **叠机组内选择语义未批准**：当前选索引最小者是实现策略，不是明文产品规则。
5. **生命周期需明确证明**：Godot 回前台后的 resync 契约尚不明确；服务端 Flight Chess 取消守卫也需补齐。

### P1：让玩家一眼知道“谁、为什么、下一步”

1. Godot 对手卡缺少昵称，将在线状态当成了主标识；Flutter 已经有对手昵称，但启动/协议边界没有传入。
2. 对局中没有显示当前连续 6 计数与第三次风险；如增加，必须仅在权威接受后更新。
2. Flutter 活跃局卡片把 revision 称为“当前步数”，但一个完整回合可包含 roll 和 move 两个 revision，语义误导。
3. 结果面板的“已确认操作数”不是有意义的战局摘要；未有权威统计前应优先精简，不自行推测。
4. 预览和聚焦测试没有覆盖 initial loading、roll/move/resign pending、拒绝恢复、reconnecting/failed、无法移动和平台中性终止。
5. 协议兼容 fixture 缺少 Flight Chess。

### P2：在规则可读之后再打磨

1. 骰子、起飞、跳跃、捷径、捕获、到达的节奏、音效和触感。
2. 第四架到达与胜利的庆祝性转场。
3. 不打断对局的规则提示入口，例如精确到达和捷径。

## 8. 交互项到现有代码/测试的追踪表

| 交互 ID | 主要代码/文档证据 | 现有测试/驱动证据 | 当前覆盖结论 |
|---|---|---|---|
| LOB-01–03 | [app.dart](../../app/lib/app.dart), [home_controller.dart](../../app/lib/features/home/home_controller.dart), [home_page.dart](../../app/lib/features/home/home_page.dart) | [app_home_test.dart](../../app/test/app_home_test.dart), [home_controller_test.dart](../../app/test/features/home/home_controller_test.dart), [home_page_test.dart](../../app/test/features/home/home_page_test.dart) | loading/error/idle/active 和前后台轮询有组件证据。 |
| LOB-04–05 | [opponent_page.dart](../../app/lib/features/home/opponent_page.dart), [home_api.dart](../../app/lib/features/home/home_api.dart) | [opponent_page_test.dart](../../app/test/features/home/opponent_page_test.dart), [home_api_test.dart](../../app/test/features/home/home_api_test.dart) | 列表态、可用/忙碌、建局 pending 有证据；真机建局入局见 E2E。 |
| LOB-06–08 | [home_page.dart](../../app/lib/features/home/home_page.dart), [history models](../../app/lib/features/history/match_history_models.dart), [history page](../../app/lib/features/history/match_history_page.dart) | [home_page_test.dart](../../app/test/features/home/home_page_test.dart), [match_history_models_test.dart](../../app/test/features/history/match_history_models_test.dart), [match_history_page_test.dart](../../app/test/features/history/match_history_page_test.dart) | 续局、revision=0 取消入口、战绩状态有组件证据。 |
| ENT-01 | [GameLaunchGate.kt](../../app/android/app/src/main/kotlin/me/zqydev/gamebox/GameLaunchGate.kt), [MainActivity.kt](../../app/android/app/src/main/kotlin/me/zqydev/gamebox/MainActivity.kt), [GameActivity.kt](../../app/android/app/src/main/kotlin/me/zqydev/gamebox/GameActivity.kt) | [GameLaunchGateTest.kt](../../app/android/app/src/test/kotlin/me/zqydev/gamebox/GameLaunchGateTest.kt), [gomoku_repository_test.dart](../../app/test/features/gomoku/gomoku_repository_test.dart) | 单游戏进程启动门有测试；不同目标 match 的 resume 语义未专项验收。 |
| ENT-02–03, NET-01–12 | [match_client.gd](../../game_runtime/core/match_client.gd), [flight_chess_controller.gd](../../game_runtime/games/flight_chess/flight_chess_controller.gd), [flight_chess_state.gd](../../game_runtime/games/flight_chess/flight_chess_state.gd), [hub.go](../../server/internal/matches/hub.go) | [test_match_client.gd](../../game_runtime/test/test_match_client.gd), [test_flight_chess_state.gd](../../game_runtime/test/test_flight_chess_state.gd), [flight-chess two-device scenario](../../tool/e2e/harness.sh) | 无乐观落子、pending、gap 快照、重连恢复与安全错误有证据；后台独立 resync 和全错误 UI 状态矩阵不完整。 |
| ID-01–02, TURN-01–04, NAV-01–02 | [flight_chess_controller.gd](../../game_runtime/games/flight_chess/flight_chess_controller.gd), [flight_chess_scene.tscn](../../game_runtime/games/flight_chess/flight_chess_scene.tscn) | [test_flight_chess_scene.gd](../../game_runtime/test/test_flight_chess_scene.gd), [flight-chess two-device scenario](../../tool/e2e/harness.sh) | 阵营映射、轮次锁定、非破坏 Back、presence 有证据；对手昵称没有 Godot 边界。 |
| ROLL-01–05 | [protocol actions](../../protocol/README.md), [server rules](../../server/internal/games/flightchess/rules.go), [flight_chess_state.gd](../../game_runtime/games/flight_chess/flight_chess_state.gd), [controller](../../game_runtime/games/flight_chess/flight_chess_controller.gd) | [rules_test.go](../../server/internal/games/flightchess/rules_test.go), [matches flight_chess_test.go](../../server/internal/matches/flight_chess_test.go), [test_match_client.gd](../../game_runtime/test/test_match_client.gd), [two-device scenario](../../tool/e2e/harness.sh) | 服务端覆盖起飞、无可移和连续掷出 6 无惩罚；两设备覆盖 pending 与真实随机掷骰。Godot 表现层未覆盖无可移反馈。 |
| SEL-01–04, TOUCH-02–03 | [flight_chess_board.gd](../../game_runtime/games/flight_chess/flight_chess_board.gd), [profile](profiles/flight-chess.md) | [test_flight_chess_board.gd](../../game_runtime/test/test_flight_chess_board.gd), [test_flight_chess_scene.gd](../../game_runtime/test/test_flight_chess_scene.gd) | 最近合法目标、按下/释放、远处不选、叠层徽标有测试；叠机组内产品语义尚未定义。 |
| MOVE-01–04 | [server rules](../../server/internal/games/flightchess/rules.go), [flight_chess_state.gd](../../game_runtime/games/flight_chess/flight_chess_state.gd), [controller](../../game_runtime/games/flight_chess/flight_chess_controller.gd) | [rules_test.go](../../server/internal/games/flightchess/rules_test.go), [test_flight_chess_state.gd](../../game_runtime/test/test_flight_chess_state.gd), [test_flight_chess_scene.gd](../../game_runtime/test/test_flight_chess_scene.gd), [two-device scenario](../../tool/e2e/harness.sh) | 单飞机权威 pending 和起飞续掷已跨层覆盖；飞机级 pending 视觉缺失。 |
| MOVE-05–09 | [server rules](../../server/internal/games/flightchess/rules.go), [flight_chess_state.gd](../../game_runtime/games/flight_chess/flight_chess_state.gd), [flight_chess_board.gd](../../game_runtime/games/flight_chess/flight_chess_board.gd) | [rules_test.go](../../server/internal/games/flightchess/rules_test.go), [test_flight_chess_state.gd](../../game_runtime/test/test_flight_chess_state.gd), [full-game driver](../../game_runtime/test/support/flight_chess_full_game_driver.gd), [preview driver](../../tool/flight_chess_preview.gd) | 跳跃/捷径/叠机/捕获的规则与最终状态有证据；动画序列和局内反馈未实现。 |
| MOVE-10–13 | [server rules](../../server/internal/games/flightchess/rules.go), [flight_chess_state.gd](../../game_runtime/games/flight_chess/flight_chess_state.gd) | [rules_test.go](../../server/internal/games/flightchess/rules_test.go), [full-game driver](../../game_runtime/test/support/flight_chess_full_game_driver.gd), [test_flight_chess_scene.gd](../../game_runtime/test/test_flight_chess_scene.gd), [preview driver](../../tool/flight_chess_preview.gd) | 规则测试覆盖双方全部归家位置与骰点、超点可选、精确到达与胜利；场景测试覆盖反弹锁定、6 点续掷、重复事件和快照恢复。 |
| MOVE-14, NET-06–10 | [service.go](../../server/internal/matches/service.go), [hub.go](../../server/internal/matches/hub.go), [flight_chess_state.gd](../../game_runtime/games/flight_chess/flight_chess_state.gd) | [matches flight_chess_test.go](../../server/internal/matches/flight_chess_test.go), [service_test.go](../../server/internal/matches/service_test.go), [test_match_client.gd](../../game_runtime/test/test_match_client.gd) | not-your-turn、stale、幂等重试、action conflict、随机失败无变异有服务/客户证据；完整拒绝 UI 截图矩阵缺失。 |
| RES-01–04 | [protocol resignation](../../protocol/README.md), [service.go](../../server/internal/matches/service.go), [controller](../../game_runtime/games/flight_chess/flight_chess_controller.gd), [scene](../../game_runtime/games/flight_chess/flight_chess_scene.tscn) | [matches flight_chess_test.go](../../server/internal/matches/flight_chess_test.go), [two-device scenario](../../tool/e2e/harness.sh) | 确认、权威认输、双端结果和 slot 释放有 E2E；认输拒绝/断线 pending 未有专项视觉验收。 |
| RES-05–07 | [service.go](../../server/internal/matches/service.go), [controller](../../game_runtime/games/flight_chess/flight_chess_controller.gd), [home_controller.dart](../../app/lib/features/home/home_controller.dart) | [service_test.go](../../server/internal/matches/service_test.go), [test_flight_chess_state.gd](../../game_runtime/test/test_flight_chess_state.gd), [two-device scenario](../../tool/e2e/harness.sh) | 通用平台 terminal 合成和返大厅有证据；Flight Chess 取消守卫和中性结果视觉需补齐。 |
| TOUCH-01/04, AUTO-01–04 | [profile](profiles/flight-chess.md), [controller](../../game_runtime/games/flight_chess/flight_chess_controller.gd), [preview script](../../tool/flight_chess_preview.sh), [preview driver](../../tool/flight_chess_preview.gd) | [test_flight_chess_scene.gd](../../game_runtime/test/test_flight_chess_scene.gd), [test_main.gd](../../game_runtime/test/test_main.gd), [two-device scenario](../../tool/e2e/harness.sh) | 横屏、safe area、规范化目标、ready/state/pending/result 标记有证据；多个关键异常状态无 preview。 |
| 协议整体 | [protocol README](../../protocol/README.md), [compat fixtures](../../protocol/fixtures/compat/) | [server match tests](../../server/internal/matches/flight_chess_test.go), [test_match_client.gd](../../game_runtime/test/test_match_client.gd) | README 和跨层测试已覆盖 Flight Chess，但检入的 protocol fixture 未覆盖 Flight Chess。 |

## 9. 后续实现的建议验收矩阵

本次只产出交互清单，没有修改 UI，因此不以静态 HTML、fixture 或代码审查代替生产运行时验收。实施时按 [testing strategy](../testing-strategy.md) 选最低可证明边界：

| 改动边界 | 最低自动证据 | 必要运行时/视觉证据 |
|---|---|---|
| 纯 Godot HUD/交互表现 | 聚焦 Godot state/board/scene 测试 | 实际 production scene；960×540 和 2400×1080；深/浅色；safe inset；截图检查所改状态 |
| Flutter 大厅/对手/战绩 | 对应 widget/controller/API 测试 | 实际 Flutter Android 页面，检查窄屏与深/浅色 |
| Android host 启动/生命周期 | Kotlin 单测 + host smoke | 实际 Android 前后台、Back、重启/续局 |
| 协议、权威规则、pending/重连边界 | Go 规则/匹配测试 + Godot MatchClient/state 测试 + protocol fixture | 只在确实跨设备边界变更时跑两设备 `flight-chess-network` E2E，并截取实际受影响态 |

建议在现有 preview 上补齐以下可评审态：

- `connecting` / `initial-sync`
- `roll-pending` / `move-pending` / `resign-pending`
- `no-movable`
- `jump` / `shortcut` / `jump-shortcut` / `capture-stack` / `exact-finish`
- `reconnecting` / `stale-sync` / `rejected` / `failed`
- `resign-confirmation` / `goal-result` / `resignation-result` / `cancelled` / `abandoned`

## 10. 清单自查结论

- 已覆盖：进入/加载、双方身份/轮次、掷骰、6 点起飞与加掷、无合法棋子、手动选棋、普通移动、跳跃、长捷径、叠机、捕获/回机库、终点航线/精确到达、目标胜利/认输/取消/遗弃、Back、后台/重连/错误、重复/过期动作、触控与自动化契约。
- 已对每类交互给出 actor/触发、前置、用户操作、立即反馈、pending/锁定、权威接受/拒绝、结果与恢复。
- 已单列 10 个不可靠 UX 猜测的未定义/歧义，其中叠机组内选择、后台 resync、Flight Chess 取消守卫和 512 事件上限是 P0。
- 已将交互 ID 追踪到现有代码、单测、Godot 全局 driver、preview 和两设备 E2E。
- 当前 MVP **规则状态机和权威性有较完整测试证据，但互动表现仍未闭环**；尤其是 accepted event 的因果反馈、目标级 pending和无法移动。
