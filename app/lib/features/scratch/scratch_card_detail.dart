import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../design_system/generated/gamebox_tokens.g.dart';
import 'scratch_controller.dart';
import 'scratch_surface.dart';
import 'scratch_card_owners.dart';
import 'scratch_social_api.dart';

class ScratchCardDetail extends StatefulWidget {
  const ScratchCardDetail({
    super.key,
    required this.cat,
    required this.controller,
    required this.api,
    required this.beforeLoad,
    required this.onDraw,
  });
  final ScratchCollectible cat;
  final ScratchController controller;
  final ScratchSocialApi api;
  final Future<void> Function() beforeLoad;
  final VoidCallback onDraw;

  @override
  State<ScratchCardDetail> createState() => _ScratchCardDetailState();
}

class _ScratchCardDetailState extends State<ScratchCardDetail> {
  final _detailScroll = ScrollController();
  bool _showOwners = false;
  bool _ownersOpened = false;

  @override
  void dispose() {
    _detailScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope<void>(
    canPop: !_showOwners,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && _showOwners) setState(() => _showOwners = false);
    },
    child: FractionallySizedBox(
      heightFactor: .9,
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: GameboxTokens.spacing.compact,
            ),
            child: Row(
              children: [
                if (_showOwners)
                  IconButton(
                    onPressed: () => setState(() => _showOwners = false),
                    tooltip: '返回卡片详情',
                    icon: const Icon(Icons.arrow_back),
                  ),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(
                      left: GameboxTokens.spacing.compact,
                    ),
                    child: Text(
                      _showOwners ? '持有玩家' : '卡片详情',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  tooltip: '关闭详情',
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Expanded(
            child: IndexedStack(
              index: _showOwners ? 1 : 0,
              children: [
                ListenableBuilder(
                  listenable: widget.controller,
                  builder: (context, _) => _story(context),
                ),
                if (_ownersOpened)
                  _owners(context)
                else
                  const SizedBox.shrink(),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget _ownership(BuildContext context) {
    final theme = Theme.of(context);
    final count = widget.controller.counts[widget.cat.index];
    final first = widget.controller.firstFound[widget.cat.index];
    return Card.filled(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: EdgeInsets.all(GameboxTokens.spacing.page),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.collections_bookmark_outlined,
                  color: theme.colorScheme.primary,
                ),
                SizedBox(width: GameboxTokens.spacing.layout),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('我的收藏', style: theme.textTheme.labelLarge),
                      if (count > 0 && first != null) ...[
                        SizedBox(height: GameboxTokens.spacing.compact),
                        Text(
                          '首次相遇 ${first.substring(0, 10)}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                SizedBox(width: GameboxTokens.spacing.compact),
                if (count > 0)
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: '$count',
                              style:
                                  (count < 1000000
                                          ? theme.textTheme.headlineLarge
                                          : theme.textTheme.titleLarge)
                                      ?.copyWith(
                                        color: theme.colorScheme.primary,
                                      ),
                            ),
                            TextSpan(
                              text: ' 张',
                              style: theme.textTheme.titleMedium,
                            ),
                          ],
                        ),
                        key: const Key('scratch-owned-count'),
                      ),
                    ),
                  )
                else
                  Text('尚未收藏', style: theme.textTheme.titleMedium),
              ],
            ),
            SizedBox(height: GameboxTokens.spacing.layout),
            const Divider(height: 1),
            SizedBox(height: GameboxTokens.spacing.compact),
            TextButton(
              key: const Key('scratch-view-owners'),
              onPressed: () => setState(() {
                _ownersOpened = true;
                _showOwners = true;
              }),
              child: Row(
                children: [
                  const Icon(Icons.people_outline),
                  SizedBox(width: GameboxTokens.spacing.compact),
                  const Expanded(child: Text('查看持有玩家')),
                  const Icon(Icons.chevron_right),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _owners(BuildContext context) => Column(
    children: [
      Padding(
        padding: EdgeInsets.all(GameboxTokens.spacing.page),
        child: Row(
          children: [
            SizedBox(
              width: GameboxTokens.components.minimumTouchTarget,
              height: GameboxTokens.components.minimumTouchTarget,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(GameboxTokens.shape.card),
                child: CollectibleArtwork(cat: widget.cat),
              ),
            ),
            SizedBox(width: GameboxTokens.spacing.layout),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${widget.cat.job} · ${widget.cat.name}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  SizedBox(height: GameboxTokens.spacing.compact),
                  ScratchRarityLabel(rarity: widget.cat.rarity),
                ],
              ),
            ),
          ],
        ),
      ),
      const Divider(height: 1),
      Expanded(
        child: SingleChildScrollView(
          key: const PageStorageKey('scratch-owners-scroll'),
          padding: EdgeInsets.all(GameboxTokens.spacing.page),
          child: ScratchCardOwners(
            key: ValueKey('scratch-owners-${widget.cat.index}'),
            api: widget.api,
            card: widget.cat.index,
            beforeLoad: widget.beforeLoad,
          ),
        ),
      ),
    ],
  );

  Widget _story(BuildContext context) {
    final owned = widget.controller.counts[widget.cat.index] > 0;
    final text = Theme.of(context).textTheme;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        controller: _detailScroll,
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
              Text(
                scratchGroups
                    .firstWhere((group) => group.id == widget.cat.groupId)
                    .title,
                style: text.labelLarge,
              ),
              SizedBox(height: GameboxTokens.spacing.layout),
              Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: math.min(
                      320,
                      MediaQuery.sizeOf(context).height * .25,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(
                      GameboxTokens.shape.card,
                    ),
                    child: CollectibleArtwork(cat: widget.cat),
                  ),
                ),
              ),
              SizedBox(height: GameboxTokens.spacing.page),
              Text(
                '${widget.cat.job} · ${widget.cat.name}',
                style: text.headlineSmall,
              ),
              SizedBox(height: GameboxTokens.spacing.compact),
              Row(
                children: [
                  ScratchRarityLabel(rarity: widget.cat.rarity),
                  SizedBox(width: GameboxTokens.spacing.layout),
                  Text(
                    'NO.${(widget.cat.index + 1).toString().padLeft(3, '0')}',
                    style: text.labelLarge,
                  ),
                ],
              ),
              SizedBox(height: GameboxTokens.spacing.page),
              _ownership(context),
              SizedBox(height: GameboxTokens.spacing.page),
              Text(widget.cat.story, style: text.bodyMedium),
              SizedBox(height: GameboxTokens.spacing.layout),
              if (!owned)
                FilledButton(
                  onPressed: () {
                    widget.onDraw();
                  },
                  child: const Text('去抽一张'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
