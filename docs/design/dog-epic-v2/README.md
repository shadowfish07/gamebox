# 狗狗史诗原画 v2

2026-09-08 使用 Poe GPT-Image-2（high，1024x1024）逐张生成；提示词见 prompts.json。
原稿保留于本工作区 artifacts/dog-epic-v2/；运行时从原稿等比例缩小，程序横向拼接为
app/assets/scratch/dog-epic-atlas.webp（2048x512，四格均为512x512，358182字节）。

从左至右：43 墨晶、44 北风、45 金豆、46 绮梦。目录仅更新这四张的 imageAsset、artIndex 和 artRows。
旧图集继续供其余狗狗使用，收藏编号、概率、故事和存档不变。运行时图集已采用。

## 需求追踪复核（Core Contract）

| 需求 | 实现和自动化证据 | 复核 |
| --- | --- | --- |
| 应用本次四张新图 | scratch_catalog.dart 四处映射及 pubspec.yaml 资源声明 | 通过 |
| 正方形且无拉伸 | 原稿1024方图；程序等比例缩小拼接；单行行边界[0,512] | 通过 |
| 稳定角色与收藏 | 仅修改美术字段，狗狗系列和裁切聚焦测试9项通过 | 通过 |
| Codex优先要求512原稿 | 根AGENTS.md，明确输出后核对尺寸 | 通过 |

MUST 无代码级阻塞；SHOULD 无新增偏离；MAY 沿用现有四列图集组件，避免引入新的显示路径。
完整 bash tool/verify.sh 通过7项检查，17条既有工具链提示。

## Android 视觉验收

在已持有共享独占租约的 Android 模拟器运行生产 ScratchPage、ScratchController、
ScratchCardDetail 和实际打包图片；验收入口使用隔离存储和可控抽取输入获得四张卡，
不代表线上抽取或同步验收。检查深色约412x891图鉴及四张详情、浅色360x640图鉴和详情。
原画比例正确，无邻格泄漏、变形或新增布局溢出；墨晶色调较暗但面部和瓶子可辨。
窄屏沿用可横向滚动的筛选条及纵向滚动图鉴。截图仅为本次实现检查和用户查看保留于
artifacts/dog-epic-v2/，不进入包体。

Verdict: complete。
