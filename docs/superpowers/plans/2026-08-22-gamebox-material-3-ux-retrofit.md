# Gamebox Material 3 UX Retrofit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 使用已验证的 `$gamebox-material-3-ux` 审计并改造现有 Flutter App 与 Godot 五子棋，使二者共享 Gamebox Material 3 语义令牌、交互状态和运行时证据门禁，同时保留五子棋自己的棋盘视觉。

**Architecture:** 平台无关 JSON 是唯一可手工修改的数值令牌源；纯 Dart 生成器校验并生成 Flutter 与 GDScript 常量，两个运行时各自用原生主题和组件映射。Flutter 使用固定 Gamebox 协作青绿明暗 `ThemeData`；Godot 五子棋选择 `Lightweight Board` Profile 并组合公共反馈组件，不把该壳层强制推广到其他游戏。

**Tech Stack:** Flutter 3.35.1 / Dart 3.9.0、Material 3、Godot 4.7 stable / GDScript、Android API 36、Bash、ADB/UI Automator、Flutter Widget/Integration Test、现有双 AVD E2E。

**Spec:** `docs/superpowers/specs/2026-08-22-gamebox-material-3-ux-design.md`

## Locked Execution Baseline

本计划唯一允许的 Flutter/Dart 执行基线是已通过仓库门禁的 Flutter 3.35.1 / Dart 3.9.0，安装于 `/Users/shadowfish/flutter-backup-3.35.1-20260822-115538/bin`。默认 `PATH` 中的其他 Flutter SDK 与当前 lockfile 不兼容，不能用于生成 scheme、执行测试、构建 APK 或形成验收证据。每个新 shell、agent task 和从计划恢复的会话都必须先运行：

```bash
export GAMEBOX_FLUTTER_SDK_ROOT=/Users/shadowfish/flutter-backup-3.35.1-20260822-115538
export PATH="$GAMEBOX_FLUTTER_SDK_ROOT/bin:$PATH"
test "$(command -v flutter)" = "$GAMEBOX_FLUTTER_SDK_ROOT/bin/flutter"
flutter --version
dart --version
(cd app && flutter pub get --enforce-lockfile --dry-run)
```

Expected: `flutter --version` 报告 Flutter 3.35.1 和 Dart 3.9.0，`dart --version` 报告 Dart 3.9.0，lockfile dry-run exit 0。下文所有未写绝对路径的 `flutter`、`dart`、`bash tool/verify*.sh` 和 `bash tool/e2e_android.sh` 命令都继承这一已验证环境；若无法证明当前 shell 满足该基线，任务不得开始或继续。

## Global Constraints

- 开始前必须存在且通过验证的 `.agents/skills/gamebox-material-3-ux/`；每个任务按其入口加载公共、Flutter、Godot 或验收 reference。
- 固定品牌 seed 是 `#006B60`，不跟随 Android 壁纸动态取色；明暗 scheme 以令牌 JSON 的显式角色值锁定，不能在运行时依赖可能随 Flutter 版本改变的 [`ColorScheme.fromSeed` 输出](https://docs.flutter.dev/release/breaking-changes/new-color-scheme-roles)。
- 仅支持 Android 手机；五子棋固定竖屏并选择 `Lightweight Board`，其他未来游戏不自动继承可见壳层。
- Flutter 与 Godot 共享令牌名称、语义和值，不共享 Widget、Scene 或绘制代码。
- 服务端权威状态、网络协议、对局规则、匹配模型、launch ticket 安全边界和现有 `Semantics.identifier`/`Key`/UI Automator/host-smoke 自动化契约不得改变。
- 返回大厅不能隐式认输或取消；认输必须经过公共危险操作确认；pending、重连、错误和结算必须有独立可理解状态。
- 所有行为改动先写失败测试并确认 RED；生成代码只由已测试生成器产生。
- 无障碍合规、TalkBack、screen-reader semantics/roles/live regions、`AccessibilityServer` 探测、焦点顺序、放大字体验收、WCAG 对比度阈值和 reduced-motion 门禁是明确 non-goal，不实施也不决定最终 verdict。
- 任何用户可见改动只有在实际构建的 Android App/Godot 游戏运行并截图后才可判定完成；mock、golden、静态渲染和源码检查不能替代截图。
- E2E 证据不得包含邀请码、令牌、真实昵称或其他用户数据；只使用脚本创建的一次性测试身份。
- 使用 `bash tool/verify.sh` 作为统一构建/测试门禁，使用 `bash tool/e2e_android.sh` 取得双 AVD 可玩闭环和截图证据。
- 每个提交只暂存任务列出的文件；保留无关工作树变化；创建本地提交但不 push。

---

## File Map

```text
design_system/
├── schema/tokens.schema.json                 # 令牌 JSON 结构与必需角色
├── tokens/gamebox.tokens.json                # 版本 1.0.0 的唯一手工数值源
└── README.md                                 # 生成、修改和版本治理入口
tool/
├── design_tokens.dart                        # 解析、验证和 Dart/GDScript 渲染库
├── generate_design_tokens.dart               # 窄 CLI
├── test_design_tokens.dart                   # 生成器行为测试
└── verify_design_system.sh                   # 漂移与公共硬编码检查
app/lib/design_system/
├── generated/gamebox_tokens.g.dart           # 提交的生成结果
├── gamebox_theme.dart                        # ThemeData 原生适配
└── components/
    ├── gamebox_page_body.dart                # 安全区、手机宽度和统一页面留白
    ├── gamebox_async_panel.dart               # loading/empty/error/retry 稳定区域
    └── gamebox_pending_button.dart            # 可读 pending 与重复提交锁
app/test/design_system/
├── derive_color_scheme_test.dart              # 锁定 SDK 下确定性导出初始 scheme
├── gamebox_theme_test.dart
├── gamebox_page_body_test.dart
├── gamebox_async_panel_test.dart
└── gamebox_pending_button_test.dart
game_runtime/design_system/
├── generated/gamebox_tokens.gd               # 提交的生成结果
├── gamebox_theme.gd                           # Theme/StyleBox 原生适配
└── components/
    ├── gamebox_back_button.tscn
    ├── gamebox_connection_banner.tscn
    ├── gamebox_connection_banner.gd
    ├── gamebox_snackbar.tscn
    ├── gamebox_snackbar.gd
    ├── gamebox_confirmation_dialog.tscn
    ├── gamebox_loading_overlay.tscn
    ├── gamebox_loading_overlay.gd
    ├── gamebox_result_panel.tscn
    └── gamebox_result_panel.gd
game_runtime/test/
├── test_design_system.gd
└── test_design_system_components.gd
docs/design/
├── gamebox-material-3-ux-audit.md             # skill 驱动的改造前后审计
└── profiles/gomoku.md                         # 五子棋接入声明与截图矩阵
```

现有修改点：

```text
app/lib/app.dart
app/lib/features/auth/registration_page.dart
app/lib/features/home/home_page.dart
app/lib/features/home/opponent_page.dart
app/lib/features/update/update_action.dart
app/test/features/auth/registration_page_test.dart
app/test/features/home/home_page_test.dart
app/test/features/home/opponent_page_test.dart
app/test/features/update/update_action_test.dart
app/integration_test/semantics_test.dart
game_runtime/main.gd
game_runtime/games/gomoku/gomoku_scene.tscn
game_runtime/games/gomoku/gomoku_controller.gd
game_runtime/games/gomoku/gomoku_board.gd
game_runtime/test/run_tests.gd
game_runtime/test/test_main.gd
game_runtime/test/test_gomoku_scene.gd
game_runtime/test/test_gomoku_board.gd
tool/verify_fast.sh
tool/verify.sh
tool/e2e_android.sh
README.md
docs/superpowers/specs/2026-08-22-gamebox-material-3-ux-design.md
```

## Interface Contract

令牌文档固定包含 `$schema`、`version`、`brand`、`colorSchemes`、`game`、`typography`、`spacing`、`shape`、`motion`、`component` 十个顶层键。`version` 固定从 `1.0.0` 开始，`brand.seed` 固定为 `#006B60`，`colorSchemes` 必须同时含完整 `light` 与 `dark` 角色。

生成后的 Dart 稳定入口是 `GameboxTokens.version`、`lightColorScheme`、`darkColorScheme`、`spacing`、`shape`、`motion`、`components`、`gameColors`；对应类型依次为 `String`、两个 `ColorScheme`、`GameboxSpacing`、`GameboxShape`、`GameboxMotion`、`GameboxComponentTokens`、`GameboxGameColors`。GDScript 稳定入口是 `GameboxTokens.VERSION/LIGHT/DARK/GAME/TYPOGRAPHY/SPACING/SHAPE/MOTION/COMPONENT`，除版本字符串外均为只读字典常量。

## Coverage Map

| 规格范围 | 实施任务 |
| --- | --- |
| 规范等级、边界、Profile 与接入声明 | Task 1 |
| 无障碍范围移除与自动化标识契约 | Task 2 |
| 单一令牌源、schema、生成与版本治理 | Task 3 |
| Flutter 原生 Theme、组件状态和响应式 | Task 4 |
| 注册、目录、对手、更新、返回与危险操作 | Task 5 |
| Godot 原生 Theme 与首批共享组件 | Task 6 |
| 五子棋 pending、重连、返回、认输、结算与密集目标 | Task 7 |
| light/dark、窄/大手机、正常字号长文案和实际截图 | Task 8 |
| unified gate、最终 skill verdict 和完成治理 | Task 9 |

### Task 1: 使用 Skill 审计现状并冻结改造范围

**Files:**
- Create: `docs/design/gamebox-material-3-ux-audit.md`
- Create: `docs/design/profiles/gomoku.md`
- Read: `.agents/skills/gamebox-material-3-ux/SKILL.md`
- Read: `.agents/skills/gamebox-material-3-ux/references/*.md`
- Read: `app/lib/app.dart`
- Read: `app/lib/features/auth/registration_page.dart`
- Read: `app/lib/features/home/home_page.dart`
- Read: `app/lib/features/home/opponent_page.dart`
- Read: `app/lib/features/update/update_action.dart`
- Read: `game_runtime/games/gomoku/gomoku_scene.tscn`
- Read: `game_runtime/games/gomoku/gomoku_controller.gd`
- Read: `game_runtime/games/gomoku/gomoku_board.gd`

**Interfaces:**
- Consumes: 已验证的 skill 审计输出契约。
- Produces: 逐文件 MUST/SHOULD/MAY 差距、明确不改内容和后续截图矩阵。

- [ ] **Step 1: 显式加载 Skill 及审计所需 references**

```bash
sed -n '1,220p' .agents/skills/gamebox-material-3-ux/SKILL.md
sed -n '1,320p' .agents/skills/gamebox-material-3-ux/references/ux-standard.md
sed -n '1,320p' .agents/skills/gamebox-material-3-ux/references/flutter-app.md
sed -n '1,320p' .agents/skills/gamebox-material-3-ux/references/godot-games.md
sed -n '1,320p' .agents/skills/gamebox-material-3-ux/references/acceptance.md
```

Expected: 本任务选择 Flutter App + `Lightweight Board`，验收结论使用 skill 定义的固定格式。

- [ ] **Step 2: 记录现有证据而不修改 UI**

```bash
rg -n 'ColorScheme.fromSeed|Colors\.|EdgeInsets|SizedBox|FilledButton|TextButton|CircularProgressIndicator|Semantics' app/lib
rg -n 'Color\(|theme_override_|offset_|custom_minimum_size|BackButton|ResignButton|StatusLabel|ConnectionLabel|ErrorLabel' game_runtime/games/gomoku
```

Expected: 审计至少记录当前 Flutter `deepPurple` 临时 seed、两端公共样式硬编码、Godot 绝对布局、认输无确认、当前 pending/reconnect/error/terminal 状态和已有 semantics identifier。

- [ ] **Step 3: 创建改造审计报告**

报告固定使用以下结构，并为每个 finding 填写实际文件与行号：

```markdown
# Gamebox Material 3 UX Retrofit Audit

## Scope and Selected Profile
## Existing Strengths to Preserve
## MUST Findings
## SHOULD Findings and Decisions
## MAY Decisions
## Out of Scope
## Test Plan
## Android Screenshot Matrix
## Pre-change Verdict
```

`Out of Scope` 必须列出 Go 服务端、协议、匹配规则、其他未来游戏、平板/折叠屏、动态壁纸色和跨运行时共享渲染。

- [ ] **Step 4: 创建五子棋 Profile 声明**

`docs/design/profiles/gomoku.md` 固定声明：

```yaml
gameId: gomoku
displayName: 五子棋
defaultOrientation: portrait
uxProfile: lightweight-board
inputMethods: [touch, android-back]
gameThemeRoles: [board, grid, blackPiece, whitePiece, whitePieceOutline, lastMove, pendingMove]
```

文档正文记录：公共壳层是本游戏的选择，不是其他游戏的默认；棋盘密集目标使用整区连续命中和最近交点吸附；SHOULD 偏离必须逐项写理由。

- [ ] **Step 5: 验证审计文档并提交**

```bash
rg -n '^## (Scope|Existing|MUST|SHOULD|MAY|Out of Scope|Test Plan|Android Screenshot Matrix|Pre-change Verdict)' \
  docs/design/gamebox-material-3-ux-audit.md
rg -n '^gameId: gomoku$|^defaultOrientation: portrait$|^uxProfile: lightweight-board$' \
  docs/design/profiles/gomoku.md
git diff --check
git add docs/design/gamebox-material-3-ux-audit.md docs/design/profiles/gomoku.md
git commit -m "docs: audit Gamebox UX against Material 3 standard"
```

Expected: 提交只有审计与 Profile 声明，没有 UI 或业务代码变化。

### Task 2: 移除无障碍范围并冻结自动化标识契约

**Files:**
- Modify: `.agents/skills/gamebox-material-3-ux/SKILL.md`
- Modify: `.agents/skills/gamebox-material-3-ux/references/*.md`
- Modify: `docs/superpowers/specs/2026-08-22-gamebox-material-3-ux-design.md`
- Modify: `docs/superpowers/plans/2026-08-22-gamebox-material-3-ux-retrofit.md`
- Modify: `docs/design/gamebox-material-3-ux-audit.md`
- Modify: `docs/design/profiles/gomoku.md`

**Interfaces:**
- Preserves: 现有 `Semantics.identifier`、`Key`、UI Automator selector、host-smoke selector 仅作为自动化兼容契约。
- Produces: 不包含无障碍实施或验收门禁的当前 skill、规范、审计和改造计划。

- [ ] **Step 1: 记录行为 RED**

比较不读取 skill 的 control 与完整读取当前 skill 的样本。只要后者必须显式覆盖 skill 自身的 Accessibility MUST 才能服从用户，即证明当前规范不自洽。

- [ ] **Step 2: 精确撤销探针提交**

使用可恢复的 `git revert` 撤销 `67a7ad1`，不保留 `GAMEBOX_ACCESSIBILITY` marker、`AccessibilityServer` 调用或 E2E accessibility summary 逻辑。

- [ ] **Step 3: 同步当前规范与后续计划**

移除 TalkBack、screen-reader metadata/roles/live regions、focus order、enlarged-font acceptance、WCAG contrast threshold 和 reduced-motion 的正向 MUST/验收要求。保留 safe area、48dp 公共目标、正常字号长文案、Back、危险确认、交互状态、双 AVD 真实流程和 Android 截图。

- [ ] **Step 4: 重跑 skill 行为场景并校验**

使用相同的显式排除请求验证修订后 skill 不再要求执行者覆盖内部 MUST；同时运行 skill 结构校验和定向残留检查。

### Task 3: 建立共享令牌契约、生成器和漂移门禁

**Files:**
- Create: `design_system/schema/tokens.schema.json`
- Create: `design_system/tokens/gamebox.tokens.json`
- Create: `design_system/README.md`
- Create: `tool/design_tokens.dart`
- Create: `tool/generate_design_tokens.dart`
- Create: `tool/test_design_tokens.dart`
- Create: `tool/verify_design_system.sh`
- Create: `app/test/design_system/derive_color_scheme_test.dart`
- Create: `app/lib/design_system/generated/gamebox_tokens.g.dart`
- Create: `game_runtime/design_system/generated/gamebox_tokens.gd`
- Modify: `tool/verify_fast.sh:1-18`

**Interfaces:**
- Consumes: `DesignTokenDocument.fromJson(Map<String, Object?>)`。
- Produces: `renderDart(DesignTokenDocument)`、`renderGdscript(DesignTokenDocument)` 和两个提交的生成文件。

- [ ] **Step 1: 写生成器失败测试**

`tool/test_design_tokens.dart` 使用最小自运行 harness，至少覆盖：

```dart
void main() {
  test('accepts the canonical version and seed', () {
    final tokens = DesignTokenDocument.fromJson(canonicalFixture);
    expectEqual(tokens.version, '1.0.0');
    expectEqual(tokens.brandSeed, '#006B60');
  });
  test('rejects a missing on-color role', () {
    expectThrows(
      () => DesignTokenDocument.fromJson(fixtureWithout('light.onPrimary')),
      contains: 'light.onPrimary',
    );
  });
  test('renders deterministic platform constants', () {
    final tokens = DesignTokenDocument.fromJson(canonicalFixture);
    expectEqual(renderDart(tokens), renderDart(tokens));
    expectEqual(renderGdscript(tokens), renderGdscript(tokens));
  });
  test('keeps semantic foreground and container roles distinct', () {
    final tokens = DesignTokenDocument.fromJson(canonicalFixture);
    expectNotEqual(tokens.lightColors['primary'], tokens.lightColors['onPrimary']);
    expectNotEqual(tokens.darkColors['surface'], tokens.darkColors['onSurface']);
  });
  test('reconciles every registered normative numeric claim', () {
    verifyNormativeClaims(canonicalFixture, repositoryRoot);
  });
}
```

测试 harness 的 `test`、`expectEqual`、`expectNotEqual`、`expectThrows` 在同一文件内实现，不为根目录增加 package 依赖。`verifyNormativeClaims` 从 canonical fixture 的 JSON path 取值，不在测试中复制预期数字；初始 RED 可先因解析器和 reconciliation 接口均不存在而失败。

- [ ] **Step 2: 运行测试确认 RED**

```bash
dart tool/test_design_tokens.dart
```

Expected: 编译失败，因为 `tool/design_tokens.dart` 和目标接口尚不存在。

- [ ] **Step 3: 创建 schema 与 canonical token 文档**

schema 要求每个明暗 scheme 包含：

```text
primary/onPrimary/primaryContainer/onPrimaryContainer
primaryFixed/primaryFixedDim/onPrimaryFixed/onPrimaryFixedVariant
secondary/onSecondary/secondaryContainer/onSecondaryContainer
secondaryFixed/secondaryFixedDim/onSecondaryFixed/onSecondaryFixedVariant
tertiary/onTertiary/tertiaryContainer/onTertiaryContainer
tertiaryFixed/tertiaryFixedDim/onTertiaryFixed/onTertiaryFixedVariant
error/onError/errorContainer/onErrorContainer
surface/onSurface/surfaceDim/surfaceBright
surfaceContainerLowest/surfaceContainerLow/surfaceContainer/surfaceContainerHigh/surfaceContainerHighest
onSurfaceVariant/outline/outlineVariant/inverseSurface/onInverseSurface/inversePrimary/surfaceTint/shadow/scrim
```

所有颜色格式为 `^#[0-9A-F]{6}$`。游戏角色固定为 `board/grid/blackPiece/whitePiece/whitePieceOutline/lastMove/pressedMove/pendingMove/pendingOverlayAlpha`；排版采用 Material 3 的 15 个语义层级。首版 JSON 在本步骤定义并成为唯一数值权威：spacing 语义键为 `base/layout/compact/page/section/large/xlarge/xxlarge`，shape 为 `input/card/floating/dialog/full`，motion 为 `fast/standard/slow/pageEnter`，component 包含 `minimumTouchTarget/pageMaxWidth/pagePadding/sectionSpacing/smallProgressSize`。其首版值按已批准设计分别初始化为 `4/8/12/16/24/32/40/48`、`8/12/16/28/999`、`100/200/300/400` 和 `48/560/16/24/20`；写入后，后续 prose、测试和两端生成物只能按语义 JSON path 引用或由机械 reconciliation 校验，不能再成为独立数值权威。Godot 1080×1920 设计画布由适配器把逻辑单位按固定 `2.0` runtime scale 换算；该画布/适配比例属于 Gomoku runtime 坐标契约，不是跨运行时 token。

`app/test/design_system/derive_color_scheme_test.dart` 在锁定基线中用 `ColorScheme.fromSeed(seedColor: Color(0xFF006B60), dynamicSchemeVariant: DynamicSchemeVariant.tonalSpot, contrastLevel: 0.0)` 分别导出 light/dark 全角色 JSON。先把输出写入 `mktemp` 文件并人工/机械核对角色完整性，再复制为 canonical token 的初始 scheme；`brand.schemeSource` 必须记录 `flutter-3.35.1-dart-3.9.0-tonal-spot-contrast-0.0`。旧工具链生成的任何候选值不得沿用或标为 canonical。执行命令：

```bash
scheme_artifact="$(mktemp -t gamebox-scheme.XXXXXX.json)"
trap 'rm -f "$scheme_artifact"' EXIT
(cd app && flutter test \
  --dart-define=GAMEBOX_SCHEME_OUTPUT="$scheme_artifact" \
  test/design_system/derive_color_scheme_test.dart)
jq -e '.light and .dark' "$scheme_artifact"
```

helper 在 canonical JSON 建立后还必须断言重新导出的角色与已锁定 `light/dark` 完全相等，因此 Flutter SDK 或 Material color utilities 漂移会直接失败。运行时和后续验证只读取已锁定 JSON，不再次调用 `fromSeed`，Flutter 升级也不能静默改色。

`design_system/README.md` 记录唯一修改入口、生成命令、漂移命令和版本规则：删除/改名 token 或改变公共交互含义提升 major；兼容新增角色或调整锁定值至少提升 minor；生成器实现修复但输出与接口不变提升 patch。首版固定为 `1.0.0`。

- [ ] **Step 4: 实现严格解析与确定性渲染**

`tool/design_tokens.dart` 固定公开：

```dart
final class DesignTokenFormatException implements Exception {
  const DesignTokenFormatException(this.path, this.message);
  final String path;
  final String message;
}
```

`DesignTokenDocument` 使用显式 final 字段保存 `version/brandSeed/schemeSource/lightColors/darkColors/gameColors/typography/spacing/shape/motion/components`，提供 `factory DesignTokenDocument.fromJson(Map<String, Object?> json)`；同文件公开 `String renderDart(DesignTokenDocument)` 与 `String renderGdscript(DesignTokenDocument)`。解析器拒绝未知顶层键、缺失角色、非法 hex 和非正数尺寸；renderer 对 map key 排序并以单个尾随换行结束。

- [ ] **Step 5: 实现窄 CLI 并生成两端常量**

```bash
dart tool/generate_design_tokens.dart \
  --input design_system/tokens/gamebox.tokens.json \
  --dart-output app/lib/design_system/generated/gamebox_tokens.g.dart \
  --godot-output game_runtime/design_system/generated/gamebox_tokens.gd
```

Expected: 生成 Dart `ColorScheme` 与 typed spacing/shape/motion/game colors；生成 GDScript 字典和版本常量；两端包含同一 `1.0.0` 和 `#006B60`。

- [ ] **Step 6: 运行生成器测试确认 GREEN**

```bash
dart tool/test_design_tokens.dart
dart format tool/design_tokens.dart tool/generate_design_tokens.dart tool/test_design_tokens.dart \
  app/lib/design_system/generated/gamebox_tokens.g.dart
dart tool/test_design_tokens.dart
```

Expected: 所有测试 PASS，format 后复跑仍 PASS。

- [ ] **Step 7: 创建漂移与硬编码检查**

`tool/verify_design_system.sh` 必须：先用 `jq -e` 验证 schema 与 token JSON 可解析，再生成到 `mktemp -d`、`cmp` 两个提交结果；拒绝 Flutter 生产 UI 中新出现的 `Colors.*`/`Color(0x...)`、literal `fontSize`、`BorderRadius`、`Duration(milliseconds:)` 和直接数字页面 spacing，拒绝 Godot 生产 UI 中生成目录外的新 literal `Color("...")`、`Color(0....)` 和 `theme_override_*`。允许玩法坐标和 `Color(existingColor, alpha)` 这种语义派生，但 alpha 必须来自 token。棋盘颜色从 `GameboxTokens.GAME` 读取，不建立公共颜色 allowlist。

同一脚本必须运行 normative-claim reconciliation：从 `gamebox.tokens.json` 动态读取 JSON path，不在脚本中复制数值，并核对 `ux-standard.md` 的 `spacing.base`/`spacing.layout`/`component.pagePadding`/`component.sectionSpacing`/`component.minimumTouchTarget`，以及 `flutter-app.md`、`godot-games.md`、`acceptance.md` 中重复的 `component.minimumTouchTarget`。对 `.agents/skills/gamebox-material-3-ux/references/*.md`、本 retrofit 计划、设计系统 README 和两端设计系统测试扫描 token-like `dp/sp/ms` literals；每一项必须是已登记并与 canonical JSON 相等的 claim、改成语义 token 引用，或在 `design_system/README.md` 明确登记为非 token 的标准/viewport/gameplay/runtime-coordinate 例外。未登记、新增、数值不一致或 prose 与 JSON 漂移都必须失败。这样保留已通过行为测试的 skill 文案，同时令 token JSON 在创建后保持唯一数值权威。

```bash
bash tool/verify_design_system.sh
```

Expected: 当前生成文件无漂移，公共硬编码检查和所有 normative numeric claim reconciliation 通过。

- [ ] **Step 8: 接入快速门禁并提交**

在 `tool/verify_fast.sh` 的 Flutter/Godot 检查前运行：

```bash
bash tool/verify_design_system.sh
```

然后执行：

```bash
bash tool/verify_design_system.sh
bash tool/verify_fast.sh
git diff --check
git add design_system tool/design_tokens.dart tool/generate_design_tokens.dart \
  tool/test_design_tokens.dart tool/verify_design_system.sh tool/verify_fast.sh \
  app/test/design_system/derive_color_scheme_test.dart \
  app/lib/design_system/generated/gamebox_tokens.g.dart \
  game_runtime/design_system/generated/gamebox_tokens.gd
git commit -m "feat: add shared Gamebox design tokens"
```

Expected: 令牌、生成器、两端输出和门禁在一个提交内；尚未改变当前界面。

### Task 4: 建立 Flutter Theme 与真实复用组件

**Files:**
- Create: `app/lib/design_system/gamebox_theme.dart`
- Create: `app/lib/design_system/components/gamebox_page_body.dart`
- Create: `app/lib/design_system/components/gamebox_async_panel.dart`
- Create: `app/lib/design_system/components/gamebox_pending_button.dart`
- Create: `app/test/design_system/gamebox_theme_test.dart`
- Create: `app/test/design_system/gamebox_page_body_test.dart`
- Create: `app/test/design_system/gamebox_async_panel_test.dart`
- Create: `app/test/design_system/gamebox_pending_button_test.dart`

**Interfaces:**
- Produces: `GameboxTheme.light()`, `GameboxTheme.dark()`, `GameboxPageBody`, `GameboxAsyncPanel`, `GameboxPendingButton`。

- [ ] **Step 1: 写 Theme 和组件失败测试**

测试固定断言：

```dart
expect(GameboxTheme.light().colorScheme, GameboxTokens.lightColorScheme);
expect(GameboxTheme.dark().colorScheme, GameboxTokens.darkColorScheme);
expect(GameboxTheme.light().useMaterial3, isTrue);
expect(find.text('正在注册'), findsOneWidget);
expect(tester.getSize(find.byType(FilledButton)).height, greaterThanOrEqualTo(48));
expect(tester.takeException(), isNull);
```

`GameboxPageBody` 分别在 360×800 和 412×915 的正常系统字号下泵入长文案；`GameboxAsyncPanel` 覆盖 loading/error/retry；pending button 覆盖默认、pressed、disabled、pending、failure-return-to-enabled，保留可见动词并禁用重复点击。Theme 测试断言输入框 8dp、卡片 12dp、浮动容器 16dp、Dialog 28dp、Button/Chip full shape。

- [ ] **Step 2: 运行 focused tests 确认 RED**

```bash
cd app
flutter test test/design_system
```

Expected: 编译失败，因为 Theme 和三个组件尚不存在。

- [ ] **Step 3: 实现 ThemeData 映射**

`GameboxTheme.light/dark` 使用生成的完整 `ColorScheme`，并显式配置：

```dart
ThemeData(
  useMaterial3: true,
  colorScheme: scheme,
  visualDensity: VisualDensity.standard,
  appBarTheme: const AppBarTheme(centerTitle: false, scrolledUnderElevation: 0),
  cardTheme: CardThemeData(clipBehavior: Clip.antiAlias),
  inputDecorationTheme: const InputDecorationTheme(filled: true),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      minimumSize: Size.square(GameboxTokens.components.minimumTouchTarget),
    ),
  ),
)
```

圆角、留白和动效只能从生成 tokens 读取；不在组件里复制 hex 或 duration。

- [ ] **Step 4: 实现三个最小复用组件**

- `GameboxPageBody`：`SafeArea -> Center -> ConstrainedBox(maxWidth: 560) -> ListView`，默认手机页面 padding 16、内容分组间距 24。
- `GameboxAsyncPanel`：固定占位区域，接收 `icon/title/message/actionLabel/onAction/isLoading`。
- `GameboxPendingButton`：接收 `identifier/label/pendingLabel/isPending/onPressed`，pending 时显示 20dp progress 和动作文案，`identifier` 仅延续既有自动化定位契约。

- [ ] **Step 5: 运行 tests 与 analyze 确认 GREEN**

```bash
cd app
flutter test test/design_system
flutter analyze
```

Expected: 新组件测试 PASS，analyze 无错误警告。

- [ ] **Step 6: 提交尚未接入页面的组件库**

```bash
git add app/lib/design_system/gamebox_theme.dart \
  app/lib/design_system/components \
  app/test/design_system
git commit -m "feat: add Flutter Gamebox theme components"
```

Expected: 组件库已测试但尚未改变实际 App 页面，因此本任务不声称完成任何可见 UI 改造。

### Task 5: 将现有 Flutter App 页面迁移到 Gamebox Theme

**Files:**
- Modify: `app/lib/app.dart:233-245`
- Modify: `app/lib/features/auth/registration_page.dart:100-310`
- Modify: `app/lib/features/home/home_page.dart:86-310`
- Modify: `app/lib/features/home/opponent_page.dart:105-235`
- Modify: `app/lib/features/update/update_action.dart:6-205`
- Modify: `app/test/features/auth/registration_page_test.dart`
- Modify: `app/test/features/home/home_page_test.dart`
- Modify: `app/test/features/home/opponent_page_test.dart`
- Create: `app/test/features/update/update_action_test.dart`
- Modify: `app/integration_test/semantics_test.dart`

**Interfaces:**
- Consumes: Task 4 的 Theme 和组件。
- Preserves: `invite-code`、`nickname`、`register`、`game-gomoku`、`choose-opponent`、`continue-match`、`cancel-match`、`opponent-<uuid>`、`app-update` identifier。
- Produces: 新增 `dismiss-cancel-match` 与 `confirm-cancel-match` dialog identifier。

- [ ] **Step 1: 先写页面行为与布局失败测试**

新增断言覆盖：

```dart
expect(find.text('加入 Gamebox'), findsOneWidget);
expect(find.text('输入邀请码，和朋友开始一局游戏'), findsOneWidget);
expect(find.byType(GameboxPendingButton), findsOneWidget);
expect(find.text('五子棋'), findsOneWidget);
expect(find.text('2 人 · 回合制'), findsOneWidget);
expect(find.bySemanticsIdentifier('choose-opponent'), findsOneWidget);
expect(find.text('游戏中'), findsWidgets);
expect(find.text('取消这局尚未开始的对局？'), findsOneWidget);
expect(tester.takeException(), isNull);
```

每个页面在 360×800、412×915、dark theme 和正常字号长文案下至少覆盖一个测试；现有 controller/API 行为断言保持不变。

`update_action_test.dart` 用真实 `UpdateController` 加窄 fake service/installer 覆盖 checking、up-to-date、available、downloading、permission-required、installer-opened、failed，断言 Dialog 只有一个最高强调安装动作、进度有文字、错误保留稳定反馈区域，长 release notes 可滚动且不 overflow。

- [ ] **Step 2: 运行 focused tests 确认 RED**

```bash
cd app
flutter test test/features/auth/registration_page_test.dart \
  test/features/home/home_page_test.dart \
  test/features/home/opponent_page_test.dart \
  test/features/update/update_action_test.dart
```

Expected: 新文案、组件或布局断言失败，原有业务行为测试仍可运行。

- [ ] **Step 3: 接入固定明暗 Theme**

`GameboxApp` 的 `MaterialApp` 改为：

```dart
theme: GameboxTheme.light(),
darkTheme: GameboxTheme.dark(),
themeMode: ThemeMode.system,
```

删除 `Colors.deepPurple` 和页面级公共颜色；错误色继续读取 `Theme.of(context).colorScheme.error`。

- [ ] **Step 4: 迁移注册页**

使用 `GameboxPageBody` 构建单列品牌加入流程：顶部 gamepad Material icon、`加入 Gamebox` 标题、说明文案、带 `labelText` 的邀请码/昵称输入、唯一最高强调注册按钮。邀请码为空和昵称长度错误通过各自 `InputDecoration.errorText` 归属字段，网络/服务/安全存储错误保留在稳定表单区域，失败后不清空输入。提交中保留更新入口、credential cleanup/retry 和所有 identifier；pending 按钮同时显示 spinner 与 `正在注册`。

- [ ] **Step 5: 迁移目录与活跃对局卡**

首页保持单一根目的地，不增加 NavigationBar。欢迎文案使用 title hierarchy；五子棋卡展示 `2 人 · 回合制` 和状态文本；选择/继续是唯一 Filled Button，取消未开始对局保持低强调 Text Button。点击取消先显示 Material AlertDialog，标题为“取消这局尚未开始的对局？”，正文说明双方将返回空闲状态，操作为“保留对局”与“取消对局”；二者分别暴露 `dismiss-cancel-match` 与 `confirm-cancel-match`，确认后才调用现有 controller。loading/error 使用稳定 `GameboxAsyncPanel`。

- [ ] **Step 6: 迁移对手列表与更新 Dialog**

对手项用头像占位、昵称、`在线/离线` 与 `可邀请/游戏中` 明确文本表达，可用令牌化辅助色增强普通视觉清晰度。更新入口保持 AppBar 次级操作；Dialog 维持检查、下载、权限、安装器、失败状态并使用统一 pending/error 层级。

- [ ] **Step 7: 运行 Flutter 全套验证**

```bash
cd app
flutter test test/design_system test/features/auth/registration_page_test.dart \
  test/features/home/home_page_test.dart \
  test/features/home/opponent_page_test.dart \
  test/features/update/update_action_test.dart \
  integration_test/semantics_test.dart
flutter analyze
flutter test
flutter build apk --debug
```

Expected: 所有稳定 identifier 仍存在；窄屏、dark 和正常字号长文案无 overflow；debug APK 构建成功。

- [ ] **Step 8: 创建可供实际运行验证的 Flutter 提交**

```bash
git add app/lib/app.dart app/lib/features/auth/registration_page.dart \
  app/lib/features/home/home_page.dart app/lib/features/home/opponent_page.dart \
  app/lib/features/update/update_action.dart \
  app/test/features/auth/registration_page_test.dart \
  app/test/features/home/home_page_test.dart \
  app/test/features/home/opponent_page_test.dart \
  app/test/features/update/update_action_test.dart \
  app/integration_test/semantics_test.dart
git commit -m "feat: apply Gamebox Material 3 UX to Flutter"
```

Expected: 提交完成自动测试，但最终视觉完成判定仍等待 Task 8 的实际 Android 截图。

### Task 6: 建立 Godot Theme 与六个公共反馈组件

**Files:**
- Create: `game_runtime/design_system/gamebox_theme.gd`
- Create: `game_runtime/design_system/components/gamebox_back_button.tscn`
- Create: `game_runtime/design_system/components/gamebox_connection_banner.tscn`
- Create: `game_runtime/design_system/components/gamebox_connection_banner.gd`
- Create: `game_runtime/design_system/components/gamebox_snackbar.tscn`
- Create: `game_runtime/design_system/components/gamebox_snackbar.gd`
- Create: `game_runtime/design_system/components/gamebox_confirmation_dialog.tscn`
- Create: `game_runtime/design_system/components/gamebox_loading_overlay.tscn`
- Create: `game_runtime/design_system/components/gamebox_loading_overlay.gd`
- Create: `game_runtime/design_system/components/gamebox_result_panel.tscn`
- Create: `game_runtime/design_system/components/gamebox_result_panel.gd`
- Create: `game_runtime/test/test_design_system.gd`
- Create: `game_runtime/test/test_design_system_components.gd`
- Modify: `game_runtime/test/run_tests.gd:3-14`

**Interfaces:**
- Produces: `GameboxTheme.create(dark: bool) -> Theme`、`GameboxTheme.system_prefers_dark() -> bool`、`ConnectionBanner.present(state, detail)`、`Snackbar.present(message, tone)`、`LoadingOverlay.set_loading(active, message)`、`ResultPanel.present(status, local_won)` 和六个 PackedScene 公共组件。

- [ ] **Step 1: 写 Theme 与组件失败测试**

测试断言：

```gdscript
var theme := GameboxTheme.create(false)
_check(theme.get_color("font_color", "Label") == GameboxTokens.LIGHT.on_surface, "label color drifted")
_check(theme.get_font_size("font_size", "Button") == 28, "button type scale drifted")
_check(back.custom_minimum_size.x >= 96.0 and back.custom_minimum_size.y >= 96.0, "back target below 48dp")
_check(dialog.dialog_text == "认输后本局立即结束，确认认输吗？", "danger copy changed")
```

组件测试还覆盖 back/button 的 default/pressed/disabled，connection `connecting/reconnecting/failed/hidden`、Snackbar 显示/消失、loading 输入锁和可见文案、result panel 返回信号以及稳定节点路径。

- [ ] **Step 2: 运行 Godot tests 确认 RED**

```bash
bash tool/verify_godot_tests.sh
```

Expected: 新 suite 无法 preload，因为 Theme 和组件尚不存在。

- [ ] **Step 3: 实现 Godot Theme 适配**

`GameboxTheme.create(dark)` 从生成字典读取语义值；提供私有 `_style_box(fill, radius, border)` 创建 `StyleBoxFlat`；字体和触控尺寸将逻辑单位乘以 `2.0`。`system_prefers_dark()` 只在 `DisplayServer.is_dark_mode_supported()` 为 true 时读取 `DisplayServer.is_dark_mode()`，否则稳定回退 light。Theme 覆盖 Label、Button、PanelContainer、ProgressBar、ConfirmationDialog，不把棋盘色写入公共 Theme。

- [ ] **Step 4: 实现六个窄组件**

- Back button：96×96 最小目标和可见 `返回大厅` 图标/文案。
- Connection banner：`present(state, detail)` 只在连接、重连、失败时突出；已连接稳定态隐藏。
- Snackbar：`present(message, tone)` 显示错误/动作拒绝短反馈，定时消失不挡住主要操作。
- Confirmation dialog：固定危险文案，取消与确认动作明确。
- Loading overlay：`set_loading(active, message)` 阻止重复输入并暴露 busy 状态。
- Result panel：`present(status, local_won)` 映射胜/负/和棋/取消/作废文案和唯一“返回大厅”操作。

- [ ] **Step 5: 注册 test suites 并确认 GREEN**

在 `run_tests.gd` 加入：

```gdscript
preload("res://test/test_design_system.gd"),
preload("res://test/test_design_system_components.gd"),
```

运行：

```bash
bash tool/verify_godot_tests.sh
bash tool/verify_design_system.sh
```

Expected: `GAMEBOX_GODOT_TESTS_PASSED`，生成文件无漂移，组件外没有新增公共 Color/theme override。

- [ ] **Step 6: 提交 Godot 组件库**

```bash
git add game_runtime/design_system/gamebox_theme.gd \
  game_runtime/design_system/components \
  game_runtime/test/test_design_system.gd \
  game_runtime/test/test_design_system_components.gd \
  game_runtime/test/run_tests.gd
git commit -m "feat: add Godot Gamebox UX components"
```

Expected: 组件已测试，但五子棋场景尚未改造。

### Task 7: 将五子棋迁移到 Lightweight Board Profile

**Files:**
- Modify: `game_runtime/games/gomoku/gomoku_scene.tscn:1-112`
- Modify: `game_runtime/games/gomoku/gomoku_controller.gd:1-410`
- Modify: `game_runtime/games/gomoku/gomoku_board.gd:1-230`
- Modify: `game_runtime/test/test_gomoku_scene.gd:14-330`
- Modify: `game_runtime/test/test_gomoku_board.gd:1-170`

**Interfaces:**
- Consumes: Task 6 的 Theme/组件和 `GameboxTokens.GAME`。
- Preserves: `cell_pressed(x, y)`、服务端权威 board/pending、`GAMEBOX_GODOT_READY/STATE/MATCH_RESULT` 日志协议、1080×1920 竖屏设计坐标。

- [ ] **Step 1: 先改测试表达目标 UX**

将场景测试改为断言：

```gdscript
_check(board.position.is_equal_approx(Vector2(60.0, 360.0)), "board origin changed")
_check(board.size.is_equal_approx(Vector2(960.0, 960.0)), "board stopped being square")
_check(back.custom_minimum_size.x >= 96.0 and back.custom_minimum_size.y >= 96.0, "back target too small")
_check(scene.get_node("ResignDialog").visible, "resign did not request confirmation")
_check(client.resign_requests == 0, "resign submitted before confirmation")
```

新增：对话框可取消、确认只发一次、Android back 先关闭可见 Dialog、返回不发 resign、已连接 banner 隐藏、reconnecting/failed banner 显示、terminal 使用 result panel，并保留现有节点路径、日志 marker 和输入 action。棋盘测试新增 touch-down 立即设置 `pressed_cell`、drag/cancel 清除、release 转为服务端权威 pending、接受后转为正式棋子的完整状态序列。

- [ ] **Step 2: 运行 focused Godot suite 确认 RED**

```bash
bash tool/verify_godot_tests.sh
```

Expected: 新确认、组件、pressed 状态和自动化契约断言失败，现有对局状态逻辑测试继续运行。

- [ ] **Step 3: 重组场景但保留棋盘坐标**

使用公共 Theme 和组件建立轻量浮动壳层：顶部返回+标题、连接状态、960×960 棋盘、玩家颜色/回合信息、Snackbar、次级认输、结算面板。安全边距至少 48 design px；棋盘继续位于 `(60, 360)`，避免破坏现有 E2E 坐标和连续命中模型。

- [ ] **Step 4: 将控制器映射到统一状态组件**

保留现有 `_status_text`、`_connection_text` 和服务端状态机；`_refresh_ui()` 只把状态映射到 connection banner、loading overlay、Snackbar 和 result panel。连接恢复前继续锁定棋盘和认输；错误清除仍以权威快照为准。

- [ ] **Step 5: 实现两步认输和返回语义**

```gdscript
func _on_resign_pressed() -> void:
	if _can_offer_resign():
		$ResignDialog.popup_centered()

func _on_resign_confirmed() -> void:
	if _can_offer_resign() and not _resign_submitted:
		_resign_submitted = true
		_client.request_resign()
```

`ui_cancel` 在 Dialog 可见时只关闭 Dialog；否则执行现有非破坏性返回大厅。终局不显示认输，result panel 承载返回。

- [ ] **Step 6: 将棋盘绘制迁移到 game tokens**

删除 `BOARD_COLOR` 等硬编码，改读 `GameboxTokens.GAME`；保留棋盘木色、黑白棋子、last move 与 pending 的游戏个性。touch-down 使用 `pressedMove` 立即画轻量状态层；release 后清除 pressed，并在请求成功时显示填充+描边的 pending；权威接受后才绘制正式棋子。last move、pressed 与 pending 通过状态层、填充和描边保持清晰区分。

- [ ] **Step 7: 验证自动化与输入契约**

断言可见返回、认输、确认、加载、结算节点路径以及 `ui_cancel` 不漂移，继续保留 `GAMEBOX_GODOT_READY/STATE/MATCH_RESULT` 日志契约和 E2E 棋盘坐标。本步不新增读屏元数据、cell 子元素或辅助技术接口。

- [ ] **Step 8: 运行 Godot 与快速门禁确认 GREEN**

```bash
bash tool/verify_godot_tests.sh
bash tool/verify_design_system.sh
bash tool/verify_fast.sh
```

Expected: 所有 Godot 状态、确认、输入、token 和组件测试 PASS；Go/Flutter 既有测试无回归。

- [ ] **Step 9: 提交五子棋改造**

```bash
git add game_runtime/games/gomoku/gomoku_scene.tscn \
  game_runtime/games/gomoku/gomoku_controller.gd \
  game_runtime/games/gomoku/gomoku_board.gd \
  game_runtime/test/test_gomoku_scene.gd \
  game_runtime/test/test_gomoku_board.gd
git commit -m "feat: apply lightweight Gamebox UX to Gomoku"
```

Expected: 提交保持协议和玩法逻辑不变；最终视觉完成判定仍等待实际 Android 证据。

### Task 8: 扩展双 AVD E2E 为可审查的 UX 证据

**Files:**
- Modify: `tool/e2e_android.sh:1-35,738-820,1180-1460,1860-2350`
- Modify: `README.md:250-290`

**Interfaces:**
- Produces: `artifacts/e2e/<UTC>/screenshots/*.png`、`summary.json.uiEvidence` 和自动化契约检查结果。

- [ ] **Step 1: 先扩展 `--self-test` 的证据安全契约**

fixture 测试必须证明：secret flag 为 1 时拒绝截图；远端 UI dump 始终清理；截图文件名只允许固定 slug；summary 只能引用 artifact 内相对路径；脚本结束恢复两个 AVD 原来的 ui mode 和 display override。本任务不修改 font scale 或 accessibility service 设置。

- [ ] **Step 2: 运行 self-test 确认 RED**

```bash
bash tool/e2e_android.sh --self-test
```

Expected: 新 fixture 失败，因为 safe capture、ui mode restore 和 evidence manifest 尚不存在。

- [ ] **Step 3: 实现安全截图 helper**

```bash
capture_ui_evidence() {
  local serial="$1"
  local slug="$2"
  local secret_flag="$3"
  [[ "$secret_flag" == "0" && "$slug" =~ ^[a-z0-9-]+$ ]] || return 1
  local output="$ARTIFACT_DIR/screenshots/$slug.png"
  adb_for "$serial" exec-out screencap -p >"$output"
  [[ -s "$output" ]]
}
```

helper 只能在邀请码字段为空或页面已离开注册输入后调用；成功 artifact 继续通过现有 secret scanner。

- [ ] **Step 4: 在真实流程捕获 Flutter 页面**

项目自有 AVD A 使用 light 和典型大屏手机视口，B 使用 dark 和典型窄屏手机视口，两者保持正常系统字号，并在 trap 中恢复 ui mode 原值。外部传入 serial 不修改 display override；它们必须天然覆盖一窄一大两个手机视口，否则视觉矩阵明确失败。捕获：

```text
registration-light.png
registration-dark-narrow.png
lobby-idle-light.png
lobby-active-dark-narrow.png
opponents-light.png
cancel-match-dialog-dark-narrow.png
update-dialog-dark.png
```

注册页截图发生在输入邀请码之前；大厅和对手页只显示脚本生成的测试昵称；更新 Dialog 不展示本地路径、token 或私有 Release 内容。

现有第二局零步取消流程改为先点击 `cancel-match`、捕获 dialog、再点击 `confirm-cancel-match`；继续用服务端 snapshot 证明取消后双方 slot 释放。

- [ ] **Step 5: 在真实对局捕获 Godot 状态**

沿用现有 authoritative snapshot + board crop 断言，新增：

```text
gomoku-initial-light.png
gomoku-pending-light.png
gomoku-resign-confirm-light.png
gomoku-reconnecting.png
gomoku-connection-failed.png
gomoku-terminal-light.png
```

pending 通过暂停 E2E 自有 server 进程、点击合法落点、等待本地 pending marker 后截图，再恢复 server；reconnecting 通过同一受控暂停等待 `connection=reconnecting` marker；connection-failed 通过终止并以同一临时数据库、端口和测试 secrets 重启 E2E 自有 server 形成真实断线状态。所有暂停、终止和重启都由 trap 绑定到已验证的 E2E server PID，不能影响非 E2E 进程。

- [ ] **Step 6: 验证 Flutter 与 Godot 自动化契约**

在 Flutter 注册、目录、对手和取消确认流程验证现有 `Semantics.identifier`/`Key` 与 UI Automator selector 继续可定位；邀请码仍由现有私密 instrumentation helper 输入，UI Automator 不读取或记录其值。Godot 继续通过已有固定坐标、输入 action 和 `GAMEBOX_GODOT_READY/STATE/MATCH_RESULT` marker 验证返回、认输确认、落子与结算返回。不启用、修改或恢复 accessibility service。

- [ ] **Step 7: 把证据清单写入 summary**

`summary.json` 新增：

```json
{
  "uiEvidence": {
    "flutter": ["screenshots/registration-light.png", "screenshots/lobby-idle-light.png"],
    "godot": ["screenshots/gomoku-initial-light.png", "screenshots/gomoku-terminal-light.png"],
    "themes": ["light", "dark"],
    "viewports": ["narrow", "large"]
  }
}
```

实际数组包含 Step 4–5 的全部成功截图；缺任一要求状态时 E2E 失败，不生成 passed summary。

- [ ] **Step 8: 确认 self-test GREEN 并提交 harness**

```bash
bash tool/e2e_android.sh --self-test
bash -n tool/e2e_android.sh
git add tool/e2e_android.sh README.md
git commit -m "test: capture Gamebox UX Android evidence"
```

Expected: fixture、自清理、安全恢复和 Bash 语法全部通过。

- [ ] **Step 9: 在干净提交上运行实际双 AVD E2E**

```bash
bash tool/e2e_android.sh
```

Expected: 两台 API 36 AVD 完成注册、选人、真实对局、pending、重连、错误、认输取消、终局和返回；summary 为 passed；所有要求截图存在且无敏感信息。

- [ ] **Step 10: 逐张查看实际截图**

使用本地图片查看工具打开 `summary.json` 引用的每张 PNG，检查：裁切、系统栏安全区、明暗色、文案换行、主次操作、棋盘比例、Dialog、pending/reconnect/error/terminal。视觉问题必须回到对应失败测试和实现任务修复，再从干净新提交重跑 E2E。

### Task 9: 统一门禁、Skill 复审与完成提交

**Files:**
- Modify: `tool/verify.sh:235-290`
- Modify: `docs/design/gamebox-material-3-ux-audit.md`
- Modify: `docs/superpowers/specs/2026-08-22-gamebox-material-3-ux-design.md`

**Interfaces:**
- Consumes: 全部自动测试、目标运行时、截图和 `$gamebox-material-3-ux` 验收契约。
- Produces: 最终 `complete/incomplete/blocked` 判定和可定位证据。

- [ ] **Step 1: 将生成的 Godot 设计系统资产纳入 APK 门禁**

`tool/verify_fast.sh` 已经执行 `verify_design_system.sh`，不要在 `verify.sh` 重复运行。扩展 `verify.sh` 的 debug APK required assets，加入：

```text
assets/design_system/generated/gamebox_tokens.gd
assets/design_system/gamebox_theme.gd
assets/design_system/components/gamebox_back_button.tscn
assets/design_system/components/gamebox_connection_banner.tscn
assets/design_system/components/gamebox_connection_banner.gd
assets/design_system/components/gamebox_snackbar.tscn
assets/design_system/components/gamebox_snackbar.gd
assets/design_system/components/gamebox_confirmation_dialog.tscn
assets/design_system/components/gamebox_loading_overlay.tscn
assets/design_system/components/gamebox_loading_overlay.gd
assets/design_system/components/gamebox_result_panel.tscn
assets/design_system/components/gamebox_result_panel.gd
```

- [ ] **Step 2: 验证并提交门禁变化**

```bash
bash tool/verify.sh
git add tool/verify.sh
git commit -m "test: verify packaged Gamebox design assets"
git show --check --stat --oneline HEAD
git status --short
```

Expected: 完整门禁通过，提交后工作树干净，供 E2E 记录精确 HEAD。

- [ ] **Step 3: 在干净代码 HEAD 上运行实际双设备验证**

```bash
bash tool/verify.sh
bash tool/e2e_android.sh --self-test
bash tool/e2e_android.sh
```

Expected: unified gate、E2E self-test 和实际双设备闭环全部 exit 0；最后一次 E2E 对应当前干净 HEAD。

- [ ] **Step 4: 使用 Skill 做最终审计**

显式调用 `$gamebox-material-3-ux` 并加载公共、Flutter、Godot、acceptance references。逐项核对审计报告中的 MUST、SHOULD、MAY；MUST 只可标为 satisfied 或带精确证据的 blocked，SHOULD 偏离必须记录理由与替代措施。

- [ ] **Step 5: 更新审计、Profile 和规格状态**

在审计报告加入每项 finding 的测试命令、commit 和 artifact 相对路径；在 Gomoku Profile 填入最终截图清单。只有最终 skill verdict 为 `complete` 时，把规格状态改为：

```markdown
- 状态：Gamebox UX skill 与现有 Flutter App/Godot 五子棋改造均已完成验证
```

若截图或真实流程任一未通过，状态保持“等待现有改造”，并在审计中明确 `incomplete` 或 `blocked`。无障碍能力不影响 verdict。

- [ ] **Step 6: 最终差异与敏感信息检查**

```bash
git diff --check
git status --short
rg -n 'GAMEBOX_(JWT_SECRET|TOKEN_PEPPER)|launch-ticket|refresh-token|invite-code-value' \
  design_system app/lib game_runtime docs/design || true
```

Expected: diff 无空白错误；没有凭据值；出现的安全字段名只来自既有协议/测试上下文，不出现在截图或新增日志。

- [ ] **Step 7: 创建验收闭环提交**

```bash
git add docs/design/gamebox-material-3-ux-audit.md \
  docs/design/profiles/gomoku.md \
  docs/superpowers/specs/2026-08-22-gamebox-material-3-ux-design.md
git commit -m "docs: close Gamebox Material 3 UX retrofit"
git show --check --stat --oneline HEAD
git status --short
```

Expected: 最终提交只包含已验证文档；工作树干净；不 push。

- [ ] **Step 8: 在最终干净 HEAD 上复跑验收并交付截图**

```bash
bash tool/verify.sh
bash tool/e2e_android.sh
git status --short
```

Expected: 最终 HEAD 的 unified gate 与双 AVD E2E 均通过，工作树干净。最终回复附上实际 Android 截图本身，并列出 unified gate、E2E、自动化契约、源码 commit 和 artifact 结果；未通过的范围内能力必须保留 `incomplete` 或 `blocked` verdict。
