# 黑白棋（reversi）

## 范围与规则

使用 Flutter 原生对局页，默认竖屏，采用 Lightweight Board 的交互语义和设计系统 1.0.0。
遵循项目 AGENTS.md 的新棋类选型规则；Skill 中旧的“Flutter 不渲染游戏”描述不适用于本次新增游戏。

- 双人、8×8，中央 D4/E5 白子、E4/D5 黑子，随机分配黑白、黑方先手。
- 空格落子必须至少翻转一子；沿八方向夹住的连续对方棋子全部翻转，不连锁翻转。
- 无合法落点自动跳过，有合法落点不可跳过。双方无处可下即结束；按实际子数计分，空格不计分，相同为平局。
- 首版不设计时或悔棋。认输独立确认；未落子可从大厅确认取消。
- Go 负责落点、翻转、跳过、结果、随机分配、revision、幂等、重放和历史；客户端不执行权威规则。

## 交互与视觉

棋盘占主要区域；显示双方颜色、当前子数、当前回合和合法落点。
公共 UI 消费 ColorScheme、TextTheme 和 GameboxTokens；棋盘使用 primaryContainer / onPrimaryContainer，
棋子使用现有 blackPiece / whitePiece 游戏色。末手圆点使用 tertiary，仅标记末手，不表示错误。
触控空格落子；提交时显示进度，确认前不翻转、不计分、不能再次操作。
规则在主动打开的弹窗中展示。可见 Back 和 Android Back 均返回原页面，不隐式认输。
返回后可通过大厅继续；前后台切换和断线先恢复权威快照再解锁操作。
断线保留棋盘，自动退避重试，失败后提供手动重试与返回。

SHOULD 偏离：无。棋盘密集格子使用已有 playfield target 例外；公共操作保持主题目标尺寸。
MAY：使用 Material AppBar 和帮助弹窗；无需引入 Godot 场景或新增资源。

## 需求追踪复核

| 需求 / 状态 | 实现位置 | 自动化证据 | 复核 |
| --- | --- | --- | --- |
| 开局、八方向、不连锁、非法动作 | games/reversi/rules.go | rules_test.go | 通过 |
| 跳过、提前结束、平局、计分 | games/reversi/rules.go | 完整对局与重放测试 | 通过 |
| 随机分配、幂等、持久化、战绩 | matches/service.go、history.go | matches/reversi_test.go | 通过 |
| 双方同步、重连、终局释放 | matches/hub.go、protocol/messages.go | httpapi/reversi_test.go | 通过 |
| 待确认、拒绝、过期状态、后台恢复 | reversi_controller.dart | reversi_test.dart | 通过 |
| 主界面、规则、认输确认、结果、Back | reversi_page.dart | 明暗主题 Widget 测试 | 通过 |
| 大厅创建、继续、取消、战绩入口 | app.dart、home_page.dart | home_page_test.dart / home_api_test.dart；双 Android 创建、继续、战绩流程 | 通过 |
| Android 竖屏与生命周期 | reversi_launcher.dart、reversi_page.dart | 双 Android 竖屏、后台恢复、两种 Back、320dp 密度切换 | 通过 |

独立代码复核：已重新对照批准的规则与当前生产实现；无悔棋、主动跳过、客户端计分裁决、Back 隐式认输或 Godot 黑白棋入口。
实际 UI 检查：已在两个 API 36 Android 模拟器安装生产 Profile APK，连接工作树本地 Go 服务。
已捕获并检查大厅/选择对手、黑白方开局、落子翻转、等待、后台恢复、返回续局、自动跳过、规则、认输取消/确认、自然终局、战绩和返回；覆盖明暗模式、约 411dp 与 320dp 窄屏。
另以短暂暂停本地服务捕获待确认界面：保留原棋盘和子数、显示进度，恢复服务后落子正常确认。
完整 60 手对局多次触发自动跳过，最终黑 19 / 白 45，双方胜负与历史一致；第二局实际认输同步通过。
运行时发现并修复路由重建重新创建控制器的问题；回归测试验证重建保留控制器，修正版 APK 的密度切换和认输流程通过。
验收边界为本地服务加双模拟器；没有宣称生产部署、两台物理手机或公网弱网验收。平局及未满盘结束由规则与完整对局自动化覆盖。
MUST 检查无未解决问题；SHOULD 无新增偏离；MAY 无额外能力要求。
截图由实现者临时捕获并检查，不加入固定测试脚本。
