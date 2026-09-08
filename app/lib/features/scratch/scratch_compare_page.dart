import 'package:flutter/material.dart';

import '../../design_system/generated/gamebox_tokens.g.dart';
import 'scratch_catalog.dart';
import 'scratch_compare_player_picker.dart';
import 'scratch_social_api.dart';
import 'scratch_surface.dart';

int _count(List<int> counts, int index) =>
    index < counts.length ? counts[index] : 0;
List<ScratchCollectible> _groupCards(String group) =>
    scratchCollectibles.where((c) => c.groupId == group).toList();
int _owned(List<ScratchCollectible> cards, List<int> counts) =>
    cards.where((c) => _count(counts, c.index) > 0).length;

enum _Difference { need, only, both, all }

bool _matches(_Difference filter, int mine, int theirs) => switch (filter) {
  _Difference.need => mine == 0 && theirs > 0,
  _Difference.only => mine > 0 && theirs == 0,
  _Difference.both => mine > 0 && theirs > 0,
  _Difference.all => true,
};

Future<String?> showScratchCompareGroups(
  BuildContext context, {
  required List<int> mine,
  required ScratchPlayer player,
  String? selected,
}) => showModalBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (context) => Padding(
    padding: EdgeInsets.only(
      left: GameboxTokens.spacing.page,
      right: GameboxTokens.spacing.page,
      bottom: GameboxTokens.spacing.page + MediaQuery.paddingOf(context).bottom,
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          selected == null ? '选择卡片集' : '切换卡片集',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        SizedBox(height: GameboxTokens.spacing.layout),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final group in scratchGroups)
                Builder(
                  builder: (context) {
                    final cards = _groupCards(group.id);
                    final missing = cards
                        .where(
                          (c) => _matches(
                            _Difference.need,
                            _count(mine, c.index),
                            _count(player.counts, c.index),
                          ),
                        )
                        .length;
                    return Padding(
                      padding: EdgeInsets.only(
                        bottom: GameboxTokens.spacing.compact,
                      ),
                      child: ListTile(
                        key: ValueKey('compare-group-${group.id}'),
                        selected: group.id == selected,
                        selectedTileColor: Theme.of(context)
                            .colorScheme
                            .secondaryContainer,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            GameboxTokens.shape.card,
                          ),
                        ),
                        leading: SizedBox.square(
                          dimension:
                              GameboxTokens.components.minimumTouchTarget,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(
                              GameboxTokens.shape.input,
                            ),
                            child: CollectibleArtwork(cat: cards.first),
                          ),
                        ),
                        title: Text(group.title),
                        subtitle: Text(
                          '我 ${_owned(cards, mine)}/${cards.length} · ${player.nickname} ${_owned(cards, player.counts)}/${cards.length}\n$missing 种对方有我没有',
                        ),
                        trailing: Icon(
                          group.id == selected
                              ? Icons.check
                              : Icons.chevron_right,
                        ),
                        onTap: () => Navigator.pop(context, group.id),
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      ],
    ),
  ),
);

class ScratchComparePage extends StatefulWidget {
  const ScratchComparePage({
    super.key,
    required this.api,
    required this.player,
    required this.mine,
    required this.groupId,
    required this.onDetail,
    this.excludeUserId,
  });
  final ScratchSocialApi api;
  final ScratchPlayer player;
  final List<int> mine;
  final String groupId;
  final Future<void> Function(ScratchCollectible card) onDetail;
  final String? excludeUserId;

  @override
  State<ScratchComparePage> createState() => _ScratchComparePageState();
}

class _ScratchComparePageState extends State<ScratchComparePage> {
  late ScratchPlayer _player = widget.player;
  late String _group = widget.groupId;
  _Difference _filter = _Difference.need;
  bool _opening = false;
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _resetScroll() {
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  Future<void> _friend() async {
    if (_opening) return;
    _opening = true;
    try {
      final player = await Navigator.push<ScratchPlayer>(
        context,
        MaterialPageRoute(
          builder: (_) => ScratchComparePlayerPicker(
            api: widget.api,
            excludeUserId: widget.excludeUserId,
          ),
        ),
      );
      if (!mounted || player == null) return;
      setState(() => _player = player);
      _resetScroll();
    } finally {
      _opening = false;
    }
  }

  Future<void> _series() async {
    if (_opening) return;
    _opening = true;
    try {
      final group = await showScratchCompareGroups(
        context,
        mine: widget.mine,
        player: _player,
        selected: _group,
      );
      if (!mounted || group == null) return;
      setState(() => _group = group);
      _resetScroll();
    } finally {
      _opening = false;
    }
  }

  Future<void> _detail(ScratchCollectible card) async {
    if (_opening) return;
    _opening = true;
    try {
      await widget.onDetail(card);
    } finally {
      _opening = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final group = scratchGroups.firstWhere((g) => g.id == _group);
    final cards = _groupCards(_group);
    final totals = {
      for (final f in _Difference.values)
        f: cards
            .where(
              (c) => _matches(
                f,
                _count(widget.mine, c.index),
                _count(_player.counts, c.index),
              ),
            )
            .length,
    };
    final visible = cards
        .where(
          (c) => _matches(
            _filter,
            _count(widget.mine, c.index),
            _count(_player.counts, c.index),
          ),
        )
        .toList();
    final labels = {
      _Difference.need: '对方有我没有',
      _Difference.only: '我有对方没有',
      _Difference.both: '共同拥有',
      _Difference.all: '全部',
    };
    final summary = switch (_filter) {
      _Difference.need => '对方有 ${visible.length} 种你还没有',
      _Difference.only => '你有 ${visible.length} 种对方还没有',
      _Difference.both => '你们共同拥有 ${visible.length} 种',
      _Difference.all => '${group.title} · ${cards.length} 种',
    };
    return Scaffold(
      appBar: AppBar(title: const Text('收藏对比')),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: GameboxTokens.spacing.page,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: _selector(
                      key: const Key('compare-friend'),
                      label: '对比好友',
                      value: _player.nickname,
                      leading: const Icon(Icons.person_outline),
                      onTap: _friend,
                    ),
                  ),
                  SizedBox(width: GameboxTokens.spacing.compact),
                  Expanded(
                    child: _selector(
                      key: const Key('compare-group'),
                      label: '卡片集',
                      value: group.title,
                      leading: SizedBox.square(
                        dimension:
                            GameboxTokens.components.minimumTouchTarget / 2,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(
                            GameboxTokens.shape.input,
                          ),
                          child: CollectibleArtwork(cat: cards.first),
                        ),
                      ),
                      onTap: _series,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.all(GameboxTokens.spacing.page),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: GameboxTokens.spacing.compact,
                  runSpacing: GameboxTokens.spacing.base,
                  children: [
                    for (final f in _Difference.values)
                      ChoiceChip(
                        key: ValueKey('compare-filter-${f.name}'),
                        label: Text('${labels[f]} ${totals[f]}'),
                        selected: f == _filter,
                        showCheckmark: false,
                        onSelected: (_) {
                          setState(() => _filter = f);
                          _resetScroll();
                        },
                      ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: CustomScrollView(
                controller: _scroll,
                slivers: [
                  SliverPadding(
                    padding: EdgeInsets.symmetric(
                      horizontal: GameboxTokens.spacing.page,
                    ),
                    sliver: SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '我 ${_owned(cards, widget.mine)}/${cards.length} · ${_player.nickname} ${_owned(cards, _player.counts)}/${cards.length}',
                            style: text.bodyMedium,
                          ),
                          SizedBox(height: GameboxTokens.spacing.compact),
                          Text(summary, style: text.headlineSmall),
                          SizedBox(height: GameboxTokens.spacing.page),
                        ],
                      ),
                    ),
                  ),
                  if (visible.isEmpty)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(child: Text('这里还没有卡片')),
                    )
                  else
                    SliverPadding(
                      padding: EdgeInsets.only(
                        left: GameboxTokens.spacing.page,
                        right: GameboxTokens.spacing.page,
                        bottom: GameboxTokens.spacing.page,
                      ),
                      sliver: SliverGrid.builder(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          crossAxisSpacing: GameboxTokens.spacing.layout,
                          mainAxisSpacing: GameboxTokens.spacing.layout,
                          childAspectRatio: .65,
                        ),
                        itemCount: visible.length,
                        itemBuilder: (context, i) {
                          final card = visible[i];
                          final mine = _count(widget.mine, card.index),
                              theirs = _count(_player.counts, card.index);
                          final known = mine > 0 || theirs > 0;
                          return Card(
                            margin: EdgeInsets.zero,
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              key: ValueKey('compare-card-${card.index}'),
                              onTap: known ? () => _detail(card) : null,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  AspectRatio(
                                    aspectRatio: 1,
                                    child: known
                                        ? CollectibleArtwork(cat: card)
                                        : ColoredBox(
                                            color: scheme.surfaceContainerLow,
                                            child: const Icon(
                                              Icons.lock_outline,
                                            ),
                                          ),
                                  ),
                                  Expanded(
                                    child: Padding(
                                      padding: EdgeInsets.all(
                                        GameboxTokens.spacing.compact,
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Text(
                                            known
                                                ? '${card.job} · ${card.name}'
                                                : '未获得',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: text.titleSmall,
                                          ),
                                          SizedBox(
                                            height: GameboxTokens.spacing.base,
                                          ),
                                          Text(
                                            '我 $mine 张',
                                            style: text.labelMedium?.copyWith(
                                              color: scheme.primary,
                                            ),
                                          ),
                                          Text(
                                            '${_player.nickname} $theirs 张',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: text.labelMedium?.copyWith(
                                              color: scheme.onSurfaceVariant,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _selector({
    required Key key,
    required String label,
    required String value,
    required Widget leading,
    required VoidCallback onTap,
  }) => FilledButton.tonal(
    key: key,
    onPressed: onTap,
    style: FilledButton.styleFrom(
      padding: EdgeInsets.all(GameboxTokens.spacing.layout),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(GameboxTokens.shape.card),
      ),
    ),
    child: Row(
      children: [
        leading,
        SizedBox(width: GameboxTokens.spacing.compact),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: Theme.of(context).textTheme.labelSmall),
              Text(value, maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
        const Icon(Icons.expand_more),
      ],
    ),
  );
}
