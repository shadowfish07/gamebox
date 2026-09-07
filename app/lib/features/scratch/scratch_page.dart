import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design_system/generated/gamebox_tokens.g.dart';
import 'scratch_controller.dart';
import 'scratch_surface.dart';

class ScratchEntry extends StatelessWidget {
  const ScratchEntry({super.key});
  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      key: const Key('open-cat-scratch'),
      leading: Icon(Icons.pets, color: Theme.of(context).colorScheme.primary),
      title: const Text('猫猫刮奖'),
      subtitle: const Text('单人 · 免费畅刮 · 收藏职业猫猫'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context)
          .push<void>(MaterialPageRoute(builder: (_) => const ScratchPage())),
    ),
  );
}

class ScratchPage extends StatefulWidget {
  const ScratchPage({super.key, this.controller});
  final ScratchController? controller;
  @override
  State<ScratchPage> createState() => _ScratchPageState();
}

class _ScratchPageState extends State<ScratchPage> {
  late final ScratchController controller;
  int tab = 0;
  int? filter;
  bool ownedOnly = false;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    controller =
        widget.controller ?? ScratchController(store: SecureScratchStore());
    controller.addListener(_changed);
    if (controller.loading) unawaited(controller.load());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    controller.removeListener(_changed);
    if (widget.controller == null) controller.dispose();
    super.dispose();
  }

  Future<void> _back() async {
    if (controller.saving) {
      _message('正在保存收藏，请稍候');
      return;
    }
    if (controller.unsaved) {
      final leave = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('离开并放弃未保存的进度？'),
          content: const Text('之前保存的收藏仍会保留。本次尚未保存的刮奖和展柜变化会丢失。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('留下重试'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('放弃并离开'),
            ),
          ],
        ),
      );
      if (leave != true || !mounted) return;
      setState(() => _leaving = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context);
      });
    } else {
      Navigator.pop(context);
    }
  }

  void _message(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: _leaving || (!controller.saving && !controller.unsaved),
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_back());
      },
      child: Scaffold(
        key: const Key('cat-scratch-page'),
        appBar: AppBar(
          leading: IconButton(
            key: const Key('scratch-back'),
            onPressed: _back,
            tooltip: '返回',
            icon: const Icon(Icons.arrow_back),
          ),
          title: Text(['猫猫刮奖', '猫猫图鉴', '我的展柜'][tab]),
          actions: [
            IconButton(
              key: const Key('scratch-rules'),
              onPressed: _rules,
              tooltip: '掉落规则',
              icon: const Icon(Icons.info_outline),
            ),
          ],
        ),
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              if (controller.error case final message?)
                MaterialBanner(
                  padding: EdgeInsets.all(GameboxTokens.spacing.compact),
                  content: Text(message),
                  actions: [
                    TextButton(
                      key: const Key('scratch-retry'),
                      onPressed: controller.saving ? null : controller.retry,
                      child: const Text('重试'),
                    ),
                  ],
                ),
              Expanded(
                child: controller.loading
                    ? const Center(child: CircularProgressIndicator())
                    : controller.error != null && !controller.unsaved
                    ? const Center(child: Text('收藏读取成功后即可继续'))
                    : switch (tab) {
                        0 => _play(context),
                        1 => _album(context),
                        _ => _showcase(context),
                      },
              ),
            ],
          ),
        ),
        bottomNavigationBar: NavigationBar(
          key: const Key('scratch-navigation'),
          selectedIndex: tab,
          onDestinationSelected: (index) => setState(() => tab = index),
          backgroundColor: scheme.surfaceContainer,
          destinations: const [
            NavigationDestination(
              key: Key('scratch-tab-play'),
              icon: Icon(Icons.touch_app_outlined),
              selectedIcon: Icon(Icons.touch_app),
              label: '刮一张',
            ),
            NavigationDestination(
              key: Key('scratch-tab-album'),
              icon: Icon(Icons.collections_bookmark_outlined),
              selectedIcon: Icon(Icons.collections_bookmark),
              label: '图鉴',
            ),
            NavigationDestination(
              key: Key('scratch-tab-showcase'),
              icon: Icon(Icons.workspace_premium_outlined),
              selectedIcon: Icon(Icons.workspace_premium),
              label: '展柜',
            ),
          ],
        ),
      ),
    );
  }

  Widget _play(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: GameboxTokens.spacing.page,
            vertical: GameboxTokens.spacing.compact,
          ),
          child: Row(
            children: [
              Icon(
                Icons.auto_awesome_outlined,
                color: scheme.primary,
                size: 20,
              ),
              SizedBox(width: GameboxTokens.spacing.compact),
              Text('猫猫百业 · 第一册', style: text.labelLarge),
              const Spacer(),
              Text(
                '${controller.collected} / 24',
                key: const Key('scratch-progress'),
                style: text.titleMedium?.copyWith(color: scheme.primary),
              ),
            ],
          ),
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: GameboxTokens.spacing.page),
          child: SizedBox(
            width: double.infinity,
            child: SegmentedButton<ScratchMode>(
              showSelectedIcon: false,
              segments: ScratchMode.values
                  .map(
                    (mode) =>
                        ButtonSegment(value: mode, label: Text(mode.label)),
                  )
                  .toList(),
              selected: {controller.mode},
              onSelectionChanged: controller.interactive
                  ? (value) => controller.changeMode(value.single)
                  : null,
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: EdgeInsets.all(GameboxTokens.spacing.page),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(
                  GameboxTokens.shape.floating,
                ),
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final extra = controller.mode == ScratchMode.career
                      ? 160.0
                      : 104.0;
                  final width = math
                      .min(
                        340.0,
                        math.min(
                          constraints.maxWidth - 24,
                          constraints.maxHeight - extra,
                        ),
                      )
                      .clamp(100.0, 340.0);
                  final compact = constraints.maxHeight < 390;
                  final ticketWidth = compact
                      ? math.min(340.0, constraints.maxWidth - 24)
                      : width;
                  final portraitSize = compact
                      ? math.max(
                          80.0,
                          math.min(
                            constraints.maxHeight - 116,
                            (ticketWidth - 24) *
                                (controller.mode == ScratchMode.career
                                    ? .55
                                    : 1),
                          ),
                        )
                      : width - 24;
                  return Center(
                    child: _ticket(
                      context,
                      ticketWidth,
                      portraitSize: portraitSize,
                      horizontalCareer:
                          compact && controller.mode == ScratchMode.career,
                    ),
                  );
                },
              ),
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.only(
            left: GameboxTokens.spacing.page,
            right: GameboxTokens.spacing.page,
            bottom: GameboxTokens.spacing.layout,
          ),
          child: Row(
            children: [
              Expanded(
                child: controller.claimed
                    ? OutlinedButton(
                        key: const Key('scratch-detail'),
                        onPressed: () => _detail(controller.cat),
                        child: const Text('看看这只猫'),
                      )
                    : Text(
                        '用手指慢慢刮开\n每张都有猫猫',
                        style: text.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
              ),
              SizedBox(width: GameboxTokens.spacing.compact),
              Expanded(
                child: FilledButton(
                  key: const Key('scratch-primary'),
                  onPressed: controller.interactive
                      ? () async {
                          HapticFeedback.selectionClick();
                          if (controller.claimed) {
                            await controller.next();
                          } else {
                            await controller.revealAll();
                          }
                        }
                      : null,
                  child: Text(
                    controller.saving
                        ? '正在保存'
                        : controller.claimed
                        ? '再来一张'
                        : '全部刮开',
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _ticket(
    BuildContext context,
    double width, {
    required double portraitSize,
    required bool horizontalCareer,
  }) {
    final text = Theme.of(context).textTheme;
    final result = controller.claimed;
    final clue = Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(
          color: GameboxTokens.gameColors.scratchCluePaper,
          child: Center(
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: GameboxTokens.spacing.layout,
              ),
              child: ExcludeSemantics(
                excluding: !controller.opened.contains(0),
                child: Text(
                  controller.cat.clue,
                  maxLines: horizontalCareer ? 4 : 2,
                  textAlign: TextAlign.center,
                  style: text.labelSmall?.copyWith(color: ScratchArt.ink),
                ),
              ),
            ),
          ),
        ),
        if (!controller.opened.contains(0)) _surface(0, clue: true),
      ],
    );
    final portrait = AspectRatio(
      aspectRatio: 1,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(GameboxTokens.shape.input),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ExcludeSemantics(child: CatArtwork(cat: controller.cat)),
            if (!result &&
                controller.mode == ScratchMode.career &&
                !controller.opened.contains(0))
              ColoredBox(
                color: ScratchArt.foil,
                child: Center(
                  child: Icon(
                    Icons.lock_outline,
                    color: GameboxTokens.gameColors.scratchLockedInk,
                    size: 32,
                  ),
                ),
              )
            else if (!result && controller.mode == ScratchMode.paws)
              Column(
                children: [
                  for (var y = 0; y < 2; y++)
                    Expanded(
                      child: Row(
                        children: [
                          for (var x = 0; x < 2; x++)
                            Expanded(
                              child: Padding(
                                padding: EdgeInsets.all(
                                  GameboxTokens.spacing.base,
                                ),
                                child: controller.opened.contains(y * 2 + x)
                                    ? const SizedBox.expand()
                                    : _surface(y * 2 + x),
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              )
            else if (!result)
              _surface(controller.mode == ScratchMode.career ? 1 : 0),
          ],
        ),
      ),
    );
    return Container(
      key: ValueKey(
        'scratch-ticket-${controller.serial}-${controller.mode.name}',
      ),
      width: width,
      padding: EdgeInsets.all(GameboxTokens.spacing.compact),
      decoration: BoxDecoration(
        color: ScratchArt.paper,
        borderRadius: BorderRadius.circular(GameboxTokens.shape.input),
        boxShadow: [
          BoxShadow(
            color: GameboxTokens.lightColorScheme.shadow.withValues(
              alpha: GameboxTokens.gameColors.boardSideCampAlpha,
            ),
            blurRadius: 16,
            offset: Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: EdgeInsets.only(bottom: GameboxTokens.spacing.layout),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '猫 猫 百 业',
                    maxLines: 1,
                    style: text.labelLarge?.copyWith(color: ScratchArt.ink),
                  ),
                ),
                Text(
                  'NO.${controller.serial.toString().padLeft(3, '0')}',
                  style: text.labelSmall?.copyWith(color: ScratchArt.ink),
                ),
              ],
            ),
          ),
          if (horizontalCareer)
            SizedBox(
              height: portraitSize,
              child: Row(
                children: [
                  Expanded(child: clue),
                  SizedBox(width: GameboxTokens.spacing.layout),
                  SizedBox(width: portraitSize, child: portrait),
                ],
              ),
            )
          else ...[
            if (controller.mode == ScratchMode.career) ...[
              SizedBox(
                height: GameboxTokens.components.minimumTouchTarget,
                child: clue,
              ),
              SizedBox(height: GameboxTokens.spacing.layout),
            ],
            SizedBox(
              width: portraitSize,
              height: portraitSize,
              child: portrait,
            ),
          ],
          SizedBox(
            height:
                GameboxTokens.components.minimumTouchTarget +
                GameboxTokens.spacing.compact,
            child: Center(
              child: AnimatedSwitcher(
                duration: GameboxTokens.motion.standard,
                child: Column(
                  key: ValueKey('$result-${controller.cat.index}'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      result
                          ? '${controller.cat.job} · ${controller.cat.name}'
                          : '刮开，遇见新朋友',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.titleSmall?.copyWith(color: ScratchArt.ink),
                    ),
                    SizedBox(height: GameboxTokens.spacing.base),
                    Text(
                      result
                          ? '${scratchRarities[controller.cat.rarity]} · ${controller.isNew ? '新朋友，已收入图鉴' : '又见面啦 ×${controller.counts[controller.cat.index]}'}'
                          : controller.mode == ScratchMode.career &&
                                controller.opened.contains(0)
                          ? '有头绪了吗？刮开身份照'
                          : '免费无限刮 · 一张一份小惊喜',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.labelSmall?.copyWith(color: ScratchArt.ink),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _surface(int region, {bool clue = false}) => ScratchSurface(
    key: ValueKey(
      'scratch-region-${controller.serial}-${controller.mode.name}-$region',
    ),
    mask: controller.masks[region],
    clue: clue,
    enabled: !controller.loading && controller.error == null,
    onComplete: () => controller.open(region),
    onEnd: () {
      if (!controller.claimed && controller.error == null) {
        unawaited(controller.persist());
      }
    },
  );

  Widget _album(BuildContext context) {
    final cats = scratchCats
        .where(
          (cat) =>
              (filter == null || cat.rarity == filter) &&
              (!ownedOnly || controller.counts[cat.index] > 0),
        )
        .toList();
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: GameboxTokens.spacing.page),
          child: Row(
            children: [
              Text(
                '已相遇 ${controller.collected} / 24',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const Spacer(),
              FilterChip(
                label: const Text('已拥有'),
                selected: ownedOnly,
                onSelected: (value) => setState(() => ownedOnly = value),
              ),
            ],
          ),
        ),
        SizedBox(
          height:
              GameboxTokens.components.minimumTouchTarget +
              GameboxTokens.spacing.layout,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(
              horizontal: GameboxTokens.spacing.page,
            ),
            children: [
              for (final value in <int?>[null, 0, 1, 2, 3])
                Padding(
                  padding: EdgeInsets.only(
                    right: GameboxTokens.spacing.compact,
                  ),
                  child: ChoiceChip(
                    label: Text(value == null ? '全部' : scratchRarities[value]),
                    selected: filter == value,
                    onSelected: (_) => setState(() => filter = value),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: cats.isEmpty
              ? const Center(child: Text('还没有猫猫，去刮一张吧'))
              : GridView.builder(
                  key: const Key('scratch-album-grid'),
                  padding: EdgeInsets.all(GameboxTokens.spacing.page),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: GameboxTokens.spacing.layout,
                    mainAxisSpacing: GameboxTokens.spacing.layout,
                    childAspectRatio: .66,
                  ),
                  itemCount: cats.length,
                  itemBuilder: (context, i) {
                    final cat = cats[i],
                        owned = controller.counts[cats[i].index] > 0;
                    return _catCell(context, cat, owned: owned);
                  },
                ),
        ),
      ],
    );
  }

  Widget _catCell(BuildContext context, ScratchCat cat, {required bool owned}) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Card(
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerLow,
      child: InkWell(
        key: ValueKey('scratch-cat-${cat.index}'),
        onTap: () => _detail(cat),
        child: Padding(
          padding: EdgeInsets.all(GameboxTokens.spacing.compact),
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '#${(cat.index + 1).toString().padLeft(2, '0')}',
                  style: text.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              Expanded(
                child: Center(
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: owned
                        ? CatArtwork(cat: cat, badge: true)
                        : DecoratedBox(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: scheme.surfaceContainerHighest,
                            ),
                            child: Icon(
                              Icons.pets_outlined,
                              color: scheme.outline,
                              size: 30,
                            ),
                          ),
                  ),
                ),
              ),
              SizedBox(height: GameboxTokens.spacing.layout),
              Text(
                owned ? cat.job : '等待相遇',
                style: text.labelMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                owned
                    ? '${scratchRarities[cat.rarity]} · ×${controller.counts[cat.index]}'
                    : scratchRarities[cat.rarity],
                style: text.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _showcase(BuildContext context) => Column(
    children: [
      Padding(
        padding: EdgeInsets.all(GameboxTokens.spacing.page),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '把喜欢的猫猫摆在一起',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Text('${controller.favorites.length} / 6'),
          ],
        ),
      ),
      Expanded(
        child: GridView.builder(
          padding: EdgeInsets.symmetric(horizontal: GameboxTokens.spacing.page),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: GameboxTokens.spacing.compact,
            mainAxisSpacing: GameboxTokens.spacing.compact,
            childAspectRatio: 1,
          ),
          itemCount: 6,
          itemBuilder: (context, i) => i < controller.favorites.length
              ? _catCell(
                  context,
                  scratchCats[controller.favorites[i]],
                  owned: true,
                )
              : Card(
                  margin: EdgeInsets.zero,
                  child: InkWell(
                    onTap: () => setState(() {
                      tab = 1;
                      ownedOnly = true;
                      filter = null;
                    }),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.add,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        SizedBox(height: GameboxTokens.spacing.layout),
                        const Text('从图鉴挑一只'),
                      ],
                    ),
                  ),
                ),
        ),
      ),
      Padding(
        padding: EdgeInsets.all(GameboxTokens.spacing.layout),
        child: Text(
          '收藏进度 ${controller.collected}/24 · 已刮开 ${controller.total} 张',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    ],
  );

  Future<void> _detail(ScratchCat cat) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (context) => ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final owned = controller.counts[cat.index] > 0;
        final text = Theme.of(context).textTheme;
        return SafeArea(
          top: false,
          child: SingleChildScrollView(
            child: Padding(
              padding: EdgeInsets.only(
                left: GameboxTokens.spacing.page,
                right: GameboxTokens.spacing.page,
                bottom: GameboxTokens.spacing.page,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          owned ? '已收藏 · 徽章与原画' : '收藏预览 · 尚未获得',
                          style: text.labelLarge,
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        tooltip: '关闭详情',
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: math.min(
                          320,
                          MediaQuery.sizeOf(context).height * .37,
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(
                          GameboxTokens.shape.card,
                        ),
                        child: CatArtwork(cat: cat),
                      ),
                    ),
                  ),
                  SizedBox(height: GameboxTokens.spacing.page),
                  Text('${cat.job} · ${cat.name}', style: text.headlineSmall),
                  SizedBox(height: GameboxTokens.spacing.compact),
                  Text(
                    '${scratchRarities[cat.rarity]} · NO.${(cat.index + 1).toString().padLeft(3, '0')}',
                    style: text.labelLarge,
                  ),
                  SizedBox(height: GameboxTokens.spacing.compact),
                  Text(cat.story, style: text.bodyMedium),
                  if (owned)
                    Padding(
                      padding: EdgeInsets.symmetric(
                        vertical: GameboxTokens.spacing.layout,
                      ),
                      child: Text(
                        '首次相遇 ${controller.firstFound[cat.index]!.substring(0, 10)} · 拥有 ×${controller.counts[cat.index]}',
                        style: text.bodySmall,
                      ),
                    ),
                  SizedBox(height: GameboxTokens.spacing.compact),
                  FilledButton(
                    key: const Key('scratch-favorite'),
                    onPressed: !owned
                        ? () {
                            Navigator.pop(context);
                            setState(() => tab = 0);
                          }
                        : controller.interactive
                        ? () async {
                            final message = await controller.favorite(
                              cat.index,
                            );
                            _message(controller.error ?? message);
                          }
                        : null,
                    child: Text(
                      !owned
                          ? '去刮一张'
                          : controller.saving
                          ? '正在保存'
                          : controller.favorites.contains(cat.index)
                          ? '从展柜取下'
                          : '放入我的展柜',
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );

  Future<void> _rules() => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    builder: (context) => SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Padding(
          padding: EdgeInsets.all(GameboxTokens.spacing.page),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '每一种刮法，同一个奖池',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              SizedBox(height: GameboxTokens.spacing.layout),
              const Text('普通 70% · 稀有 24% · 史诗 5.5% · 传说 0.5%'),
              SizedBox(height: GameboxTokens.spacing.layout),
              const Text('同一档内每只猫概率相同，每张独立随机，无保底。每张完全刮开后自动入册，重复获得只增加持有数量。'),
              SizedBox(height: GameboxTokens.spacing.layout),
              const Text('免费无限刮。收藏保存在此设备，卸载或清除应用数据后可能丢失，暂不支持账号同步。'),
              SizedBox(height: GameboxTokens.spacing.layout),
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('知道啦'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
