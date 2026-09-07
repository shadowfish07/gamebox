# 稀有度揭晓动效

范围与 Profile：Core Contract。用户要求中奖揭晓后按稀有度递增华丽程度。

MUST：四档绑定实际中奖结果；不提前泄露稀有度；不中不庆祝；不阻挡继续刮奖。
SHOULD：奖品与文字保持可读；无新增偏离。
MAY：普通扫光与轻微缩放；稀有增加星芒；史诗增加扩散光环；传说增加三重光环、放射光束和更多星粒。使用现有稀有度色和共享动效节拍，时长分别为 0.6、1.2、1.8、2.7 秒。

## 需求追踪复核

| 需求或状态 | 实现 | 自动化证据 | 代码复核 |
| --- | --- | --- | --- |
| 四档递增、中奖后触发 | ScratchPage 的 claimed && winning 传入 ScratchRevealEffect；按 rarity 选择层数、粒子数、时长 | 四档 production page binding tests | 无阻塞项 |
| 未刮开、未中奖 | revealed 为 false，不挂载特效 painter | 默认状态测试；原有未中奖页面测试 | 无提前泄露或未中奖庆祝路径 |
| 动画期间继续操作、快速换卡 | IgnorePointer；按 ticket serial 重建并 dispose controller | 播放中点下一张、点击穿透、快速替换测试 | 不改保存/领奖状态机 |
| 已揭晓恢复、切回刮奖页 | 只响应 false → true；初始 true 不播放 | restored result、重复 rebuild 测试 | 无重播路径 |
| 结束状态 | 有限 AnimationController，结束后移除 painter | pumpAndSettle 后无 burst | 无常驻 ticker |
| 画面可读性与明暗窄屏 | 效果限制在原画圆角内，中心透明，文字/按钮在效果外 | 既有页面尺寸测试；Android 明暗两尺寸截图已检查 | 无代码级阻塞项 |

## 验证

初次顶层 gate 发现直接 Duration 数值不符合设计系统规则，已改为共享 motion.slow 的倍数。修正后 `bash tool/verify.sh` 通过（7 个顶层检查，17 条聚合警告；包含依赖更新提示和 Kotlin 插件迁移提示），正常入口 debug APK 构建通过。`flutter test test/features/scratch/scratch_reveal_effect_test.dart test/features/scratch/scratch_page_test.dart` 共 19 项通过。


## 目标运行时 UX 检查

在 Android API 36、slot 0 设备租约内运行生产 `ScratchPage`、`ScratchController` 和真实绘制组件。临时检查入口仅注入定向抽签随机源和独立文件存储，便于稳定检查四档；未使用 mock UI，未改正式抽奖概率。检查深色常规 1440×3120 / 560 dpi 与浅色 360×640 / 160 dpi 的四档中间帧、结束态及未中奖结果。另以真实手势刮开传说卡，检查部分擦除和揭晓结果。

截图检查：普通轻微扫光；稀有边缘星芒；史诗紫色光环；传说金色三重扩散环、放射线、星粒层次清楚。奖品面部、结果文案和底部按钮可读，特效结束后无残留；两尺寸无溢出。Flutter / AndroidRuntime 错误过滤日志为空。未进行真机 GPU 性能或双设备网络验收（本次不涉及相应边界）。检查完恢复设备尺寸、密度和正式入口 APK，释放租约。截图、检查入口及日志均为忽略的本地临时数据。

## Verdict

complete：需求追踪无未解决 MUST / SHOULD 项，测试、真实 Android 页面运行和截图检查通过。
