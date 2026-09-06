# 猫猫百业 · 浏览器 MVP

[设计与讨论记录](../../specs/2026-09-07-cat-scratch-design.md) · [验收记录](acceptance.md)

可玩内容：24 只职业猫、三种 Canvas 刮擦、四档概率、图鉴与原画预览、重复计数、本地存档、六格展柜、PNG 展示卡、明暗模式和可选声音。没有联网对战、账号同步、现金奖励或排行榜。

这是浏览器版本的实际应用，尚未接入 Gamebox Flutter/Godot/Android。数据仅属于当前浏览器来源，不同域名、端口或浏览器的收藏不会自动互通。不要将此客户端结果用于可信排行榜。

## 运行源版本

在仓库根目录执行，浏览器打开 `http://127.0.0.1:47863/`。如果端口已被占用，换一个空闲端口。源版本使用 ES modules，需要 HTTP 服务。

```sh
python3 -m http.server 47863 --bind 127.0.0.1 --directory docs/design/cat-scratch
```

## 检查与独立文件构建

无运行时第三方依赖。构建使用固定版本 esbuild，生成可直接打开或分享的单个 HTML，含全部图片和代码。产物和运行截图在忽略目录 `artifacts/cat-scratch/`，不提交重复的内嵌资源。

```sh
node --test --test-reporter=dot docs/design/cat-scratch/collection.test.mjs
mkdir -p artifacts/cat-scratch
npx --yes esbuild@0.25.12 docs/design/cat-scratch/app.mjs --bundle --format=iife --minify --outfile=artifacts/cat-scratch/app.bundle.js
python3 - <<'PY'
from pathlib import Path
import base64
root = Path('docs/design/cat-scratch')
out = Path('artifacts/cat-scratch')
image = 'data:image/webp;base64,' + base64.b64encode((root/'assets/cat-atlas.webp').read_bytes()).decode()
css = (root/'style.css').read_text().replace('assets/cat-atlas.webp', image)
js = (out/'app.bundle.js').read_text()
html = (root/'index.html').read_text().replace('<link rel="stylesheet" href="style.css">', '<style>'+css+'</style>').replace('<script type="module" src="app.mjs"></script>', '<script>'+js+'</script>')
(out/'cat-scratch-mvp.html').write_text(html)
print('Built:', out/'cat-scratch-mvp.html')
PY
```

仓库确定性总 gate 为 `bash tool/verify.sh`。本 MVP 的直接运行时是浏览器；仓库 APK 构建通过也不表示 APK 已包含此游戏。

## 文件与资源

- `collection.mjs`：猫猫目录、概率、票据领取、存档校验、收藏和覆盖率逻辑。
- `app.mjs`：实际交互、局部刮擦、页面、声音、存档异常、展示卡导出。
- `style.css`：响应式票面、图鉴、展柜和主题。
- `assets/cat-atlas.png`：本任务使用内置 imagegen 生成的 24 猫图集，原图 1024×1536。生成网格并非等高，代码使用实际行边界，防止裁到邻格。
- `assets/cat-atlas.webp`：相同尺寸的运行时编码版本，使用 `cwebp -q 88` 从 PNG 转码，保留 PNG 原稿。单文件试玩包约 726 KiB。
- `collection.test.mjs`：通过 Node 原生测试工具覆盖概率、领取、存档和展柜不变式。

公共主题颜色参考 `design_system/tokens/gamebox.tokens.json` 2.4.0；网页 MVP 手动映射 light/dark 语义角色，不修改共享生成器。纸票、徽章材质和猫猫原画是游戏美术。原画当前是图集中单猫切片；徽章是同一图的圆形珐琅框呈现，后续可独立重绘与提高分辨率。

## 验收注意

- 空浏览器应从 0/24 开始，预览未获得猫不会收入图鉴。
- 只有完整揭晓才入册，重复点击与刷新不重复领奖。
- 四格需要四格完成；职业证必须先刮线索；反复摩擦同一点不累加覆盖率。
- 浏览器存储失败有提示；损坏存档不会被静默覆盖；另一个标签页写入会暂停当前页，刷新恢复。
- 移动端在涂层以外滚动页面，触摸涂层专用于刮擦。
- Web Audio、震动和下载由浏览器能力决定；未做 Android 真机触感或宿主验收。
