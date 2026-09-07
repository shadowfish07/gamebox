# 刮刮收藏 UX Profile

```yaml
gameId: cat_scratch
displayName: 刮刮收藏
defaultOrientation: portrait
uxProfile: core-contract
inputMethods: [touch, android-back]
gameThemeRoles: [paper, ink, foil, common, rare, epic, legendary]
```

用户明确要求 Flutter 手机交互。此单人轻量游戏采用 Flutter 绘制玩法，是现有 Godot 玩法惯例的明确例外；不引入对战房间或跨引擎桥接。公共导航、主题、间距、弹层和按钮沿用 Gamebox Material 3 组件与 tokens。

采用 tokens 2.5.0 的 `game.scratch*` 美术角色。手机竖屏使用单张整面涂层，保持票面文字和触摸区域可用。

刮奖页以票面为主体，底部固定揭晓/再来一张按钮和三项导航。涂层是连续触摸画布，普通控件保持标准触摸目标。只保留传统刮奖，中奖率 20%；分组仅在图鉴和详情展示。部分揭晓不暴露结果文案，完全揭晓后显示新收藏、重复数或未中奖。

可见返回和 Android Back 共用保存状态检查。正常返回保留收藏；存储错误时提示重试，明确确认后才可放弃未保存进度。结果内联显示，详情和规则用可关闭底部弹层。图鉴与六格展柜允许纵向滚动。

验收状态包含：登录页入口、未刮、部分刮开、未中奖、分组浏览、完整揭晓、新/重复收藏、图鉴筛选、原画详情、展柜、系统返回、退出重启、窄屏明暗主题。采用组件测试与实际 Android APK 截图检查，无联网边界变更，不要求双设备 E2E。

证据见 [Flutter 验收记录](../cat-scratch/flutter-acceptance.md)。本地收藏仅用于试玩，不代表云同步或可信排名。
