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
          title: const Text('我的战绩'),
        ),
        body: NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: GameboxPageBody(children: _children(context)),
        ),
      ),
    );
  }

  List<Widget> _children(BuildContext context) {
    final controller = widget.controller;
    if (controller.isInitialLoading ||
        (controller.statistics == null && controller.initialError == null)) {
      return const [_InitialLoading()];
    }
    final initialError = controller.initialError;
    if (initialError != null) {
      return [
        _InitialError(message: initialError.message, onRetry: controller.retry),
      ];
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
    return [
      _StatisticsCard(statistics: statistics),
      if (controller.matches.isEmpty)
        const _EmptyHistory()
      else ...[
        Text('最近对局', style: Theme.of(context).textTheme.titleLarge),
        _HistoryList(matches: controller.matches, footer: footer),
      ],
    ];
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GameboxAsyncPanel(
            icon: Icons.cloud_off_outlined,
            title: '暂时无法加载战绩',
            message: message,
          ),
          SizedBox(height: GameboxTokens.spacing.page),
          Semantics(
            key: const Key('retry-match-history'),
            identifier: 'retry-match-history',
            child: FilledButton(onPressed: onRetry, child: const Text('重试')),
          ),
        ],
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
  const _EmptyHistory();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: const Key('match-history-empty'),
      identifier: 'match-history-empty',
      container: true,
      child: const GameboxAsyncPanel(
        icon: Icons.history_toggle_off_outlined,
        title: '还没有已结束的对局',
        message: '完成一局五子棋后，战绩会显示在这里。',
      ),
    );
  }
}

final class _HistoryList extends StatelessWidget {
  const _HistoryList({required this.matches, this.footer});

  final List<MatchHistoryEntry> matches;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: const Key('match-history-list'),
      identifier: 'match-history-list',
      container: true,
      child: Column(
        children: [
          for (var index = 0; index < matches.length; index += 1) ...[
            if (index > 0) SizedBox(height: GameboxTokens.spacing.layout),
            _HistoryEntry(entry: matches[index]),
          ],
          if (footer case final footer?) ...[
            SizedBox(height: GameboxTokens.spacing.layout),
            footer,
          ],
        ],
      ),
    );
  }
}

final class _HistoryEntry extends StatelessWidget {
  const _HistoryEntry({required this.entry});

  final MatchHistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final local = entry.finishedAt.toLocal();
    final material = MaterialLocalizations.of(context);
    final finished =
        '${material.formatShortDate(local)} '
        '${material.formatTimeOfDay(TimeOfDay.fromDateTime(local), alwaysUse24HourFormat: true)}';
    final color = entry.color == GomokuColor.black ? '黑方' : '白方';
    final outcome = _OutcomeStyle.resolve(context, entry.outcome);
    final identifier = 'match-history-entry-${entry.id}';
    return Semantics(
      key: Key(identifier),
      identifier: identifier,
      label:
          '${outcome.label}，对手${entry.opponentNickname}，$color，'
          '结束于 $finished，${entry.moveCount} 手',
      container: true,
      excludeSemantics: true,
      child: Card(
        child: ListTile(
          contentPadding: EdgeInsets.all(GameboxTokens.components.pagePadding),
          title: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Chip(
                label: Text(
                  outcome.label,
                  style: TextStyle(color: outcome.foreground),
                ),
                backgroundColor: outcome.background,
              ),
              SizedBox(width: GameboxTokens.spacing.layout),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(top: GameboxTokens.spacing.layout),
                  child: Text(
                    entry.opponentNickname,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ),
            ],
          ),
          subtitle: Padding(
            padding: EdgeInsets.only(top: GameboxTokens.spacing.layout),
            child: Wrap(
              spacing: GameboxTokens.spacing.compact,
              runSpacing: GameboxTokens.spacing.layout,
              children: [
                Text(color),
                Text(finished),
                Text('${entry.moveCount} 手'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _OutcomeStyle {
  const _OutcomeStyle({
    required this.label,
    required this.background,
    required this.foreground,
  });

  factory _OutcomeStyle.resolve(BuildContext context, MatchOutcome outcome) {
    final scheme = Theme.of(context).colorScheme;
    return switch (outcome) {
      MatchOutcome.win => _OutcomeStyle(
        label: '胜',
        background: scheme.primaryContainer,
        foreground: scheme.onPrimaryContainer,
      ),
      MatchOutcome.loss => _OutcomeStyle(
        label: '负',
        background: scheme.surfaceContainerHighest,
        foreground: scheme.onSurface,
      ),
      MatchOutcome.draw => _OutcomeStyle(
        label: '和',
        background: scheme.tertiaryContainer,
        foreground: scheme.onTertiaryContainer,
      ),
      MatchOutcome.abandoned => _OutcomeStyle(
        label: '作废',
        background: scheme.surfaceContainer,
        foreground: scheme.onSurfaceVariant,
      ),
    };
  }

  final String label;
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
