# Chinese Checkers UX Profile

```yaml
gameId: chinese_checkers
displayName: 跳棋
defaultOrientation: portrait
uxProfile: lightweight-board
designSystemVersion: 2.3.0
inputMethods: [touch, android-back]
gameThemeRoles: [board, grid, blackPiece, whitePiece, whitePieceOutline, pressedMove, pendingMove]
```

跳棋选用 Gamebox Material 3 的 **Lightweight Board** 配置。Godot 负责 121 孔六角星棋盘与对局交互，Flutter 只负责大厅中的对局创建、继续与取消入口。对局、走法、轮次与结果均以服务端权威状态为准。

## Direct Endpoint Interaction

1. 点选自己的棋子后，一次显示它当前可到达的所有最终空位。
2. 点击高亮终点立即提交完整路径；常规走棋不增加确认弹层。
3. 提交后棋盘立即锁定，但不乐观修改权威棋盘。界面以起点淡化、路径线和终点幽灵棋子表示“等待服务端确认”。
4. 被拒绝时恢复最后一份权威棋盘和可交互状态，并使用安全 Snackbar 文案，不暴露原始协议错误。

棋盘只在棋孔附近响应点击，棋盘边缘和孔位间的大块空白不会吸附到远处棋孔。本地玩家的起始营始终显示在屏幕底部：黑方视角旋转 180°，白方保持标准方向。

## Rules Represented in the UI

- 标准 121 孔六角星棋盘，双方各 10 枚棋子。
- 每回合可走相邻空位，或跨过相邻棋子连续跳跃，多次跳跃允许转向。
- 可经过两侧中立营，但不能在中立营内停下；棋子进入自己的目标营后不能再以营外位置为终点。
- 率先将 10 枚棋子全部移入对面目标营的玩家获胜。

## Connection, Navigation, and Results

- 首次连接、同步和重连使用顶部紧凑状态条；已确认的棋盘始终保留可见，直到新快照到达前禁止走棋与认输。
- 顶部玩家条固定使用“对手 — 回合状态 — 我”的顺序，玩家身份前显示黑白棋子标记。玩家条本身不增加外围色块或描边；只有当前行动方显示带轻描边的玩家卡底色、配对前景色和“正在行动”文案：本地行动使用 `primaryContainer` / `onPrimaryContainer`，对手行动使用 `tertiaryContainer` / `onTertiaryContainer`，非行动方以第二行显示“在线”或本地先后手。回合切换不使用持续动画，也不把对手回合画成错误或危险状态。
- 本地提交后的“确认中”继续突出本地玩家，但必须以独立文案区别于可操作回合；终局双方都恢复中性样式。重连期间隐藏玩家条，不沿用过期的回合强调或在线状态。
- 可见返回键与 Android Back 都只返回大厅，不认输、不取消对局。
- 认输仅位于右上角溢出菜单“认输并结束对局”，必须经过共享危险确认对话框。
- 胜利、失败、认输、取消和作废均使用共享结果面板，可查看最终棋盘并明确返回大厅。

## Acceptance States

上线前至少检查：初始连接，黑/白本地视角，本地行动方强调，对手行动方强调，提交确认中的本地强调，选中与多终点高亮，转向连跳，服务端接受/拒绝，重连保留棋盘，对手在线状态，认输确认，目标营获胜与返回大厅。回合强调必须在浅色、深色和窄屏手机视口中检查。截图验收必须来自实际构建的目标运行时；静态 HTML 方案只记录交互决策，不是上线验收证据。
