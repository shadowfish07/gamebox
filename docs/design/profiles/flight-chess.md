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

飞行棋选用 Gamebox Material 3 的 **Lightweight Board** 配置，并以手机横屏为唯一默认方向。场景在 Android 请求 `SCREEN_SENSOR_LANDSCAPE`，允许用户左右横握但不进入竖屏。正方形棋盘始终是主视觉区；双方信息与骰子操作占用棋盘两侧的横向空间，不为了填满屏幕而拉伸或重排棋路。

## Board and interaction baseline

- 经典四角机库：黄色左上、绿色右上、红色右下、蓝色左下。双人原型使用对角的黄方与红方。
- 主路径是 52 格闭环，四方主路径起点相隔 13 格；每色拥有 6 格独立归家航道。
- 公共格按蓝、黄、绿、红循环；每色归家入口与长距离飞跃触发点都落在本色格，避免把起飞区误当作同色公共格。
- 四条长距离飞跃保持黄向下、绿向左、红向上、蓝向右的经典方向。
- 玩家先掷骰子，再手动选择一架可移动的飞机。仅掷出 6 可从机库起飞，并获得一次额外掷骰。
- 同色飞机允许叠放，不阻挡其他飞机；对手落在叠放位置时一次击落全部。

## Prototype boundary and acceptance states

当前 Godot 场景是本地可交互的棋盘与横屏 HUD 原型，用于验证盘面拓扑、缩放、触摸命中与“先掷后选”操作。它尚未注册进 Flutter 大厅、Go 服务端或联机协议，因此不把本地移动显示为服务端已确认状态。

本轮必须在真实 Godot 运行时检查：`ready`、`rolled`、`pressed`、`selected`、`stacked` 五个状态，至少覆盖 960×540 窄横屏和 2400×1080 的 20:9 横屏，并在浅色、深色背景下确认固定棋盘艺术仍然可读。布局读取 Android 可用安全区域；确定性预览通过 `--safe-insets LEFT,TOP,RIGHT,BOTTOM` 模拟横屏挖孔和手势边缘。右侧掷骰操作固定在拇指容易触达的底部区域；棋盘选择为每架可移动飞机提供至少 48dp 的容错直径，触摸按下先缩放反馈，释放后才提交，点得太远则不会误选。叠放飞机合并为一个选择目标，通过层叠边缘和数量角标表达组内数量，避免多套高亮互相干扰。返回键仅退出预览，不触发认输或放弃对局。
