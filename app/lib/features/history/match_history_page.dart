import 'dart:async';

import 'package:flutter/material.dart';

import '../../design_system/components/gamebox_async_panel.dart';
import '../../design_system/components/gamebox_page_body.dart';
import '../../design_system/generated/gamebox_tokens.g.dart';
import '../gomoku/gomoku_models.dart';
import 'match_history_controller.dart';
import 'match_history_models.dart';

final class MatchHistoryPage extends StatefulWidget {
  const MatchHistoryPage({super.key, required this.controller});

  final MatchHistoryController controller;

  @override
  State<MatchHistoryPage> createState() => _MatchHistoryPageState();
}

final class _MatchHistoryPageState extends State<MatchHistoryPage> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    unawaited(widget.controller.load());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.metrics.extentAfter <= GameboxTokens.spacing.large &&
        widget.controller.loadMoreError == null) {
      unawaited(widget.controller.loadMore());
    }
    return false;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: const Key('match-history-page'),
      identifier: 'match-history-page',
      container: true,
      child: Scaffold(
        appBar: AppBar(
          leading: Semantics(
            key: const Key('match-history-back'),
            identifier: 'match-history-back',
            child: BackButton(onPressed: () => Navigator.of(context).pop()),
          ),
          title: Text(widget.controller.game.pageTitle),
        ),
        body: NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: _body(context),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final controller = widget.controller;
    if (controller.isInitialLoading ||
        (controller.statistics == null && controller.initialError == null)) {
      return const GameboxPageBody(children: [_InitialLoading()]);
    }
    final initialError = controller.initialError;
    if (initialError != null) {
      return GameboxPageBody(
        children: [
          _InitialError(
            message: initialError.message,
            onRetry: controller.retry,
          ),
        ],
      );
    }
    final statistics = controller.statistics!;
    final Widget? footer;
    if (controller.isLoadingMore) {
      footer = const _LoadMoreLoading();
    } else if (controller.loadMoreError case final error?) {
      footer = _LoadMoreError(
        message: error.message,
        onRetry: controller.retry,
      );
    } else {
      footer = null;
    }
    if (controller.matches.isEmpty) {
      return GameboxPageBody(
        children: [
          _StatisticsCard(statistics: statistics),
          _EmptyHistory(game: controller.game),
        ],
      );
    }
    return _HistoryContent(
      statistics: statistics,
      matches: controller.matches,
      game: controller.game,
      footer: footer,
    );
  }
}

final class _InitialLoading extends StatelessWidget {
  const _InitialLoading();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: const Key('match-history-loading'),
      identifier: 'match-history-loading',
      container: true,
      child: const GameboxAsyncPanel(
        icon: Icons.history,
        title: '正在加载战绩',
        message: '请稍候，正在获取最新的已结束对局。',
        isLoading: true,
      ),
    );
  }
}

final class _InitialError extends StatelessWidget {
  const _InitialError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: const Key('match-history-error'),
      identifier: 'match-history-error',
      container: true,
      child: GameboxAsyncPanel(
        icon: Icons.cloud_off_outlined,
        title: '暂时无法加载战绩',
        message: message,
        actions: Semantics(
          key: const Key('retry-match-history'),
          identifier: 'retry-match-history',
          child: FilledButton(onPressed: onRetry, child: const Text('重试')),
        ),
      ),
    );
  }
}

final class _StatisticsCard extends StatelessWidget {
  const _StatisticsCard({required this.statistics});

  final MatchHistoryStatistics statistics;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final winRate = (statistics.winRate * 100).round();
    return Semantics(
      key: const Key('match-history-statistics'),
      identifier: 'match-history-statistics',
      container: true,
      child: Card(
        child: Padding(
          padding: EdgeInsets.all(GameboxTokens.components.pagePadding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('战绩统计', style: theme.textTheme.titleMedium),
              SizedBox(height: GameboxTokens.spacing.compact),
              Wrap(
                spacing: GameboxTokens.spacing.page,
                runSpacing: GameboxTokens.spacing.layout,
                children: [
                  Text('胜率 $winRate%'),
                  Text('有效对局 ${statistics.validMatches}'),
                  Text('胜 ${statistics.wins}'),
                  Text('负 ${statistics.losses}'),
                  Text('和 ${statistics.draws}'),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _EmptyHistory extends StatelessWidget {
  const _EmptyHistory({required this.game});

  final MatchHistoryGame game;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: const Key('match-history-empty'),
      identifier: 'match-history-empty',
      container: true,
      child: GameboxAsyncPanel(
        icon: Icons.history_toggle_off_outlined,
        title: '还没有已结束的对局',
        message: game.emptyMessage,
      ),
    );
  }
}

final class _HistoryContent extends StatelessWidget {
  const _HistoryContent({
    required this.statistics,
    required this.matches,
    required this.game,
    this.footer,
  });

  final MatchHistoryStatistics statistics;
  final List<MatchHistoryEntry> matches;
  final MatchHistoryGame game;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: const Key('match-history-list'),
      identifier: 'match-history-list',
      container: true,
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: GameboxTokens.components.pageMaxWidth,
            ),
            child: CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    GameboxTokens.components.pagePadding,
                    GameboxTokens.components.pagePadding,
                    GameboxTokens.components.pagePadding,
                    GameboxTokens.components.sectionSpacing,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: _StatisticsCard(statistics: statistics),
                  ),
                ),
                SliverPadding(
                  padding: EdgeInsets.only(
                    left: GameboxTokens.components.pagePadding,
                    right: GameboxTokens.components.pagePadding,
                    bottom: GameboxTokens.components.sectionSpacing,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: Text(
                      '最近对局',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                ),
                SliverPadding(
                  padding: EdgeInsets.symmetric(
                    horizontal: GameboxTokens.components.pagePadding,
                  ),
                  sliver: SliverList.separated(
                    itemCount: matches.length + (footer == null ? 0 : 1),
                    itemBuilder: (context, index) => index == matches.length
                        ? footer!
                        : _HistoryEntry(entry: matches[index], game: game),
                    separatorBuilder: (context, index) =>
                        SizedBox(height: GameboxTokens.spacing.layout),
                  ),
                ),
                SliverToBoxAdapter(
                  child: SizedBox(height: GameboxTokens.components.pagePadding),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _HistoryEntry extends StatelessWidget {
  const _HistoryEntry({required this.entry, required this.game});

  final MatchHistoryEntry entry;
  final MatchHistoryGame game;

  @override
  Widget build(BuildContext context) {
    final local = entry.finishedAt.toLocal();
    final material = MaterialLocalizations.of(context);
    final finished =
        '${material.formatShortDate(local)} '
        '${material.formatTimeOfDay(TimeOfDay.fromDateTime(local), alwaysUse24HourFormat: true)}';
    final leadingDetail = switch (game) {
      MatchHistoryGame.chineseCheckers =>
        entry.color == GomokuColor.black ? '先手' : '后手',
      MatchHistoryGame.flightChess =>
        entry.color == GomokuColor.black ? '红方 · 先手' : '黄方 · 后手',
      MatchHistoryGame.gomoku => entry.color == GomokuColor.black ? '黑方' : '白方',
      MatchHistoryGame.rps => entry.rpsFormat!.label,
    };
    final countDetail = '${entry.moveCount} ${game.countUnit}';
    final outcome = _OutcomeStyle.resolve(context, entry.outcome);
    final identifier = 'match-history-entry-${entry.id}';
    return Semantics(
      key: Key(identifier),
      identifier: identifier,
      label:
          '${outcome.label}，对手${entry.opponentNickname}，'
          '$leadingDetail，结束于 $finished，$countDetail',
      container: true,
      excludeSemantics: true,
      child: Card(
        child: Padding(
          padding: EdgeInsets.all(GameboxTokens.components.pagePadding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '对手',
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                        ),
                        SizedBox(height: GameboxTokens.spacing.base),
                        Text(
                          entry.opponentNickname,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: GameboxTokens.spacing.compact),
                  _OutcomeBadge(
                    badgeKey: Key('$identifier-outcome'),
                    outcome: outcome,
                  ),
                ],
              ),
              SizedBox(height: GameboxTokens.spacing.page),
              Wrap(
                spacing: GameboxTokens.spacing.page,
                runSpacing: GameboxTokens.spacing.layout,
                children: [
                  _HistoryMetadata(
                    icon: Icons.sports_esports_outlined,
                    label: leadingDetail,
                  ),
                  _HistoryMetadata(
                    icon: Icons.format_list_numbered_rounded,
                    label: countDetail,
                  ),
                ],
              ),
              SizedBox(height: GameboxTokens.spacing.layout),
              _HistoryMetadata(
                icon: Icons.schedule_rounded,
                label: finished,
                fillWidth: true,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _OutcomeBadge extends StatelessWidget {
  const _OutcomeBadge({required this.badgeKey, required this.outcome});

  final Key badgeKey;
  final _OutcomeStyle outcome;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(GameboxTokens.shape.full),
      child: ColoredBox(
        key: badgeKey,
        color: outcome.background,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: GameboxTokens.spacing.compact,
            vertical: GameboxTokens.spacing.base,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                outcome.icon,
                size: GameboxTokens.spacing.page,
                color: outcome.foreground,
              ),
              SizedBox(width: GameboxTokens.spacing.base),
              Text(
                outcome.label,
                style: Theme.of(context).textTheme.labelLarge
                    ?.copyWith(color: outcome.foreground),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _HistoryMetadata extends StatelessWidget {
  const _HistoryMetadata({
    required this.icon,
    required this.label,
    this.fillWidth = false,
  });

  final IconData icon;
  final String label;
  final bool fillWidth;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    final text = Text(
      label,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: color),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: GameboxTokens.spacing.page, color: color),
        SizedBox(width: GameboxTokens.spacing.base),
        if (fillWidth) Expanded(child: text) else text,
      ],
    );
  }
}

final class _OutcomeStyle {
  const _OutcomeStyle({
    required this.label,
    required this.icon,
    required this.background,
    required this.foreground,
  });

  factory _OutcomeStyle.resolve(BuildContext context, MatchOutcome outcome) {
    final scheme = Theme.of(context).colorScheme;
    return switch (outcome) {
      MatchOutcome.win => _OutcomeStyle(
        label: '胜利',
        icon: Icons.check_rounded,
        background: scheme.primaryContainer,
        foreground: scheme.onPrimaryContainer,
      ),
      MatchOutcome.loss => _OutcomeStyle(
        label: '失利',
        icon: Icons.close_rounded,
        background: scheme.surfaceContainerHighest,
        foreground: scheme.onSurfaceVariant,
      ),
      MatchOutcome.draw => _OutcomeStyle(
        label: '平局',
        icon: Icons.remove_rounded,
        background: scheme.tertiaryContainer,
        foreground: scheme.onTertiaryContainer,
      ),
      MatchOutcome.abandoned => _OutcomeStyle(
        label: '作废',
        icon: Icons.block_rounded,
        background: scheme.surfaceContainer,
        foreground: scheme.onSurfaceVariant,
      ),
    };
  }

  final String label;
  final IconData icon;
  final Color background;
  final Color foreground;
}

final class _LoadMoreLoading extends StatelessWidget {
  const _LoadMoreLoading();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: const Key('match-history-load-more'),
      identifier: 'match-history-load-more',
      container: true,
      child: Card(
        child: Padding(
          padding: EdgeInsets.all(GameboxTokens.components.pagePadding),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox.square(
                dimension: GameboxTokens.components.smallProgressSize,
                child: const CircularProgressIndicator(),
              ),
              SizedBox(width: GameboxTokens.spacing.compact),
              const Flexible(child: Text('正在加载更早的对局')),
            ],
          ),
        ),
      ),
    );
  }
}

final class _LoadMoreError extends StatelessWidget {
  const _LoadMoreError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: const Key('match-history-load-more'),
      identifier: 'match-history-load-more',
      container: true,
      child: Card(
        child: Padding(
          padding: EdgeInsets.all(GameboxTokens.components.pagePadding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(message, textAlign: TextAlign.center),
              SizedBox(height: GameboxTokens.spacing.layout),
              Semantics(
                key: const Key('retry-match-history-more'),
                identifier: 'retry-match-history-more',
                child: OutlinedButton(
                  onPressed: onRetry,
                  child: const Text('重试加载'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
