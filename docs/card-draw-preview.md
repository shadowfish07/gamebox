# 抽卡效果 Debug 包

专用入口 `app/lib/main_card_draw_preview.dart` 直接打开生产抽卡界面。
每次启动按空白、稀有、史诗、传说循环；第二轮同卡重复，可检查重复收藏反馈。
收藏仅保存在当前进程内，不读写正式收藏、不连接收藏服务。重启后从空白重新开始。
普通应用入口不引用这套预览配置；专用入口拒绝非 Debug 构建。

在 `app/` 下构建适用于 ARM64 Android 手机的独立 Debug 包：

```bash
GAMEBOX_DEBUG_ARTIFACT=true \
ORG_GRADLE_PROJECT_gameboxAndroidAbi=arm64-v8a \
flutter build apk --debug --target-platform=android-arm64 \
  -t lib/main_card_draw_preview.dart
```

产物为 `app/build/app/outputs/flutter-apk/app-debug.apk`，包名
`me.zqydev.gamebox.debug`，桌面名称 `gamebox debug`，可与正式版共存。
它会替换同包名且签名兼容的既有 Debug 安装。

音效对应：普通 `card-place-3.ogg`，稀有 `jingles_STEEL16.ogg`，
史诗 `jingles_STEEL12.ogg`，传说 `jingles_STEEL02.ogg`。空白卡保持无奖励音效。
