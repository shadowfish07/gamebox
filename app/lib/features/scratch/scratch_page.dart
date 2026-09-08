import 'dart:async';

import 'package:flutter/material.dart';

import '../../design_system/generated/gamebox_tokens.g.dart';
import '../../core/api/api_client.dart';
import 'scratch_social_api.dart';
import 'scratch_collection_sync.dart';
import 'scratch_players_page.dart';
import 'scratch_compare_page.dart';
import 'scratch_compare_player_picker.dart';
import 'scratch_controller.dart';
import 'scratch_collectible_card.dart';
import 'scratch_card_detail.dart';
import 'card_draw_flow.dart';
import 'card_draw_play.dart';

class ScratchEntry extends StatelessWidget {
  const ScratchEntry({super.key, this.socialApi});
  final ScratchSocialApi? socialApi;
  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      key: const Key('open-cat-scratch'),
      leading: Icon(
        Icons.confirmation_number_outlined,
        color: Theme.of(context).colorScheme.primary,
      ),
      title: const Text('抽卡收藏'),
      subtitle: const Text('单人 · 免费抽卡 · 收集惊喜'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push<void>(
        MaterialPageRoute(builder: (_) => ScratchPage(socialApi: socialApi)),
      ),
    ),
  );
}

class ScratchPage extends StatefulWidget {
  const ScratchPage({super.key, this.controller, this.socialApi});
  final ScratchSocialApi? socialApi;
  final ScratchController? controller;
  @override
  State<ScratchPage> createState() => _ScratchPageState();
}

class _ScratchPageState extends State<ScratchPage> with WidgetsBindingObserver {
  late final ScratchController controller;
  late final CardDrawFlow drawFlow;
  ApiClient? _ownedSocialClient;
  late final ScratchSocialApi socialApi;
  late final ScratchCollectionSync collectionSync;
  int tab = 0;
  int? filter;
  String? groupFilter;
  final _selectedGroupKey = GlobalKey();
  bool ownedOnly = false;
  bool _leaving = false;
  bool _openingCompare = false;

  @override
  void initState() {
    super.initState();
    socialApi =
        widget.socialApi ??
        HttpScratchSocialApi(_ownedSocialClient = ApiClient());
    controller =
        widget.controller ?? ScratchController(store: SecureScratchStore());
    drawFlow = CardDrawFlow(controller)..addListener(_flowChanged);
    WidgetsBinding.instance.addObserver(this);
    collectionSync = ScratchCollectionSync(controller, socialApi);
    controller.addListener(_changed);
    if (controller.loading) unawaited(controller.load());
  }

  void _flowChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && tab == 0) {
      drawFlow.resume();
    } else {
      drawFlow.suspend();
    }
  }

  void _changed() {
    if (!controller.loading && drawFlow.phase == CardDrawPhase.idle)
      drawFlow.current ??= controller.lastResult;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    drawFlow.removeListener(_flowChanged);
    drawFlow.dispose();
    collectionSync.dispose();
    _ownedSocialClient?.close();
    controller.removeListener(_changed);
    if (widget.controller == null) controller.dispose();
    super.dispose();
  }

  Future<void> _compare() async {
    if (_openingCompare) return;
    _openingCompare = true;
    try {
      final api = socialApi;
      final selfId = api is HttpScratchSocialApi
          ? api.session?.session?.user.id
          : null;
      final player = await Navigator.push<ScratchPlayer>(
        context,
        MaterialPageRoute(
          builder: (_) =>
              ScratchComparePlayerPicker(api: api, excludeUserId: selfId),
        ),
      );
      if (!mounted || player == null) return;
      final mine = List<int>.unmodifiable(controller.counts);
      final group =
          groupFilter ??
          await showScratchCompareGroups(context, mine: mine, player: player);
      if (!mounted || group == null) return;
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => ScratchComparePage(
            api: api,
            player: player,
            mine: mine,
            groupId: group,
            excludeUserId: selfId,
          ),
        ),
      );
    } finally {
      _openingCompare = false;
    }
  }

  Future<void> _back() async {
    if (tab != 0) {
      setState(() => tab = 0);
      drawFlow.resume();
      return;
    }
    drawFlow.suspend();
    if (controller.saving) {
      _message('正在保存收藏，请稍候');
      drawFlow.resume();
      return;
    }
    if (controller.unsaved) {
      final leave = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('离开并放弃未保存的进度？'),
          content: const Text('之前保存的收藏仍会保留。本次尚未保存的抽卡进度会丢失。'),
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
      if (leave != true || !mounted) {
        if (mounted) drawFlow.resume();
        return;
      }
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
      canPop:
          _leaving || (tab == 0 && !controller.saving && !controller.unsaved),
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
          title: Text(['抽卡收藏', '收藏图鉴', '玩家收藏'][tab]),
          actions: [
            if (tab == 1)
              TextButton(
                key: const Key('scratch-compare'),
                onPressed:
                    controller.loading ||
                        controller.saving ||
                        controller.unsaved
                    ? null
                    : _compare,
                child: const Text('对比'),
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
                      onPressed: controller.saving ? null : drawFlow.retry,
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
                        _ => ScratchPlayersPage(
                          api: socialApi,
                          beforeLoad: collectionSync.sync,
                        ),
                      },
              ),
            ],
          ),
        ),
        bottomNavigationBar: NavigationBar(
          key: const Key('scratch-navigation'),
          selectedIndex: tab,
          onDestinationSelected: (index) {
            drawFlow.suspend();
            setState(() => tab = index);
            if (index == 0) drawFlow.resume();
          },
          backgroundColor: scheme.surfaceContainer,
          destinations: const [
            NavigationDestination(
              key: Key('scratch-tab-play'),
              icon: Icon(Icons.touch_app_outlined),
              selectedIcon: Icon(Icons.touch_app),
              label: '抽卡',
            ),
            NavigationDestination(
              key: Key('scratch-tab-album'),
              icon: Icon(Icons.collections_bookmark_outlined),
              selectedIcon: Icon(Icons.collections_bookmark),
              label: '图鉴',
            ),
            NavigationDestination(
              key: Key('scratch-tab-players'),
              icon: Icon(Icons.people_outline),
              selectedIcon: Icon(Icons.people),
              label: '玩家',
            ),
          ],
        ),
      ),
    );
  }

  Widget _play(BuildContext context) =>
      CardDrawPlay(flow: drawFlow, onDetail: _detail);

  Widget _album(BuildContext context) {
    final cats = scratchCollectibles
        .where(
          (cat) =>
              (groupFilter == null || cat.groupId == groupFilter) &&
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
                '已相遇 ${controller.collected} / ${scratchCollectibles.length}',
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
              for (final group in <ScratchGroup?>[null, ...scratchGroups])
                Padding(
                  padding: EdgeInsets.only(
                    right: GameboxTokens.spacing.compact,
                  ),
                  child: ChoiceChip(
                    key: group != null && groupFilter == group.id
                        ? _selectedGroupKey
                        : null,
                    label: Text(
                      group == null
                          ? '全部分组'
                          : '${group.title} ${scratchCollectibles.where((item) => item.groupId == group.id && controller.counts[item.index] > 0).length}/${scratchCollectibles.where((item) => item.groupId == group.id).length}',
                    ),
                    selected: groupFilter == group?.id,
                    onSelected: (_) => setState(() => groupFilter = group?.id),
                  ),
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
              ? const Center(child: Text('还没有藏品，去抽一张吧'))
              : GridView.builder(
                  key: const Key('scratch-album-grid'),
                  padding: EdgeInsets.all(GameboxTokens.spacing.page),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: GameboxTokens.spacing.layout,
                    mainAxisSpacing: GameboxTokens.spacing.layout,
                    childAspectRatio: .74,
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

  Widget _catCell(
    BuildContext context,
    ScratchCollectible cat, {
    required bool owned,
  }) {
    return ScratchCollectibleCard(
      key: ValueKey('scratch-cat-${cat.index}'),
      item: cat,
      count: owned ? controller.counts[cat.index] : 0,
      onTap: () => _detail(cat),
    );
  }

  Future<void> _detail(ScratchCollectible cat) async {
    drawFlow.suspend();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => SafeArea(
        top: false,
        child: ScratchCardDetail(
          cat: cat,
          controller: controller,
          api: socialApi,
          beforeLoad: collectionSync.sync,
          onViewGroup: () {
            Navigator.pop(context);
            setState(() {
              tab = 1;
              groupFilter = cat.groupId;
              filter = null;
              ownedOnly = false;
            });
            WidgetsBinding.instance.addPostFrameCallback((_) {
              final groupContext = _selectedGroupKey.currentContext;
              if (mounted && groupContext != null) {
                unawaited(
                  Scrollable.ensureVisible(groupContext, alignment: .5),
                );
              }
            });
          },
          onDraw: () {
            Navigator.pop(context);
            setState(() => tab = 0);
          },
        ),
      ),
    );
    if (mounted && tab == 0) drawFlow.resume();
  }
}
