# Flight Chess UX Profile

```yaml
gameId: flight_chess
displayName: 飞行棋
defaultOrientation: landscape
uxProfile: lightweight-board
designSystemVersion: 2.4.0
inputMethods: [touch, android-back]
gameThemeRoles: [paperBoard, routeInk, yellowPlane, greenPlane, redPlane, bluePlane]
```

飞行棋选用 Gamebox Material 3 的 **Lightweight Board** 配置，并以手机横屏为唯一默认方向。场景在 Android 请求 `SCREEN_SENSOR_LANDSCAPE`，允许用户左右横握但不进入竖屏。该场景独立使用 `1920×1080` 横屏虚拟像素基准、`canvas_items` 缩放与 `expand` 宽高比策略，不受项目其他竖屏游戏的 `1080×1920` 基准影响。正方形棋盘始终是主视觉区；双方信息与骰子操作占用棋盘两侧的横向空间，不为了填满屏幕而拉伸或重排棋路。

## Board and interaction baseline

- 经典四角机库：黄色左上、绿色右上、红色右下、蓝色左下。双人对局使用对角的黄方与红方：服务端的 `black` 座位映射为红方并先手，`white` 座位映射为黄方。
- 主路径是 52 格闭环，四方主路径起点相隔 13 格；每色拥有 6 格独立归家航道。
- 公共格按蓝、黄、绿、红循环；每色归家入口与长距离飞跃触发点都落在本色格，避免把起飞区误当作同色公共格。
- 四条长距离飞跃保持黄向下、绿向左、红向上、蓝向右的经典方向。
- 玩家先请求服务端掷骰子，再手动选择一架可移动的飞机。仅掷出 6 可从机库起飞，并获得一次额外掷骰；连续第三个 6 会把前两个 6 移动过的飞机送回机库并交出回合。
- 同色飞机允许叠放，不阻挡其他飞机；对手落在叠放位置时一次击落全部。

## Production boundary and acceptance states

飞行棋已注册进 Flutter 大厅、Go 匹配/历史服务、WebSocket 协议与 Godot 生产场景。骰子由服务端生成；掷骰、移动、吃子、胜负与认输只在收到连续 revision 的权威事件后呈现。断线重连、revision 缺口和进程重启都以服务端快照恢复，本地 pending 输入不冒充已确认棋局。返回键仅离开场景；认输必须通过独立按钮与确认对话框。

生产验收覆盖大厅创建/续局、双端启动、服务器离线时的 pending 边界、权威掷骰与移动、额外回合、强停后恢复、非破坏性返回、认输与结果。UI 运行时检查 `ready`、`rolled`、`pressed`、`selected`、`stacked`、`offline/pending`、`resign-confirmation` 和 `result` 状态，至少覆盖 960×540 窄横屏和 2400×1080 的 20:9 横屏，并在浅色、深色背景下确认固定棋盘艺术仍然可读。布局读取 Android 可用安全区域；确定性预览的 `--safe-insets LEFT,TOP,RIGHT,BOTTOM` 使用实际窗口像素，再换算到当前虚拟像素，用于模拟横屏挖孔和手势边缘。右侧掷骰操作固定在拇指容易触达的底部区域；棋盘选择为每架可移动飞机提供至少 48dp 的容错直径，触摸按下先缩放反馈，释放后才提交，点得太远则不会误选。叠放飞机合并为一个选择目标，通过层叠边缘和数量角标表达组内数量，避免多套高亮互相干扰。
