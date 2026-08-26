import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/platform/game_results_platform.dart';
import '../../design_system/components/gamebox_async_panel.dart';
import '../../design_system/components/gamebox_page_body.dart';
import '../../design_system/generated/gamebox_tokens.g.dart';
import 'game_history_controller.dart';
import 'game_history_store.dart';
import 'match_history_api.dart';
import 'match_history_controller.dart';
import 'match_history_models.dart';

final class GameHistoryPage extends StatefulWidget {
  const GameHistoryPage({super.key, required this.controller, this.publicApi});

  final GameHistoryController controller;
  final MatchHistoryApi? publicApi;

  @override
  State<GameHistoryPage> createState() => _GameHistoryPageState();
}

final class _GameHistoryPageState extends State<GameHistoryPage> {
  MatchHistoryController? _publicController;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    unawaited(widget.controller.refresh());
    _configurePublicController(widget.publicApi);
  }

  @override
  void didUpdateWidget(GameHistoryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
      unawaited(widget.controller.refresh());
    }
    if (oldWidget.publicApi != widget.publicApi) {
      _configurePublicController(widget.publicApi);
    }
  }

  void _configurePublicController(MatchHistoryApi? api) {
    final oldController = _publicController;
    oldController?.removeListener(_changed);
    oldController?.dispose();
    if (api == null) {
      _publicController = null;
      return;
    }
    final controller = MatchHistoryController(api: api);
    _publicController = controller;
    controller.addListener(_changed);
    unawaited(controller.load());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  bool _onScroll(ScrollNotification notification) {
    final controller = _publicController;
    if (controller != null &&
        notification.metrics.extentAfter <= GameboxTokens.spacing.large &&
        controller.loadMoreError == null) {
      unawaited(controller.loadMore());
    }
    return false;
  }

  Future<void> _refresh() async {
    await Future.wait([
      widget.controller.refresh(),
      if (_publicController case final controller?) controller.refresh(),
    ]);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _publicController?.removeListener(_changed);
    _publicController?.dispose();
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
          child: _body(),
        ),
      ),
    );
  }

  Widget _body() {
    final local = widget.controller;
    final public = _publicController;
    final items = _mergedItems(local.results, public?.matches ?? const []);
    final initiallyLoading =
        local.loading && local.results.isEmpty ||
        public != null && public.isInitialLoading && public.matches.isEmpty;
    if (initiallyLoading && items.isEmpty && local.pending.isEmpty) {
      return const GameboxPageBody(
        children: [
          GameboxAsyncPanel(
            icon: Icons.history,
            title: '正在加载战绩',
            message: '请稍候，正在合并本机与公网对局记录。',
            isLoading: true,
          ),
        ],
      );
    }

    final hasError =
        local.errorCode != null ||
        public?.initialError != null ||
        public?.loadMoreError != null;
    return RefreshIndicator(
      onRefresh: _refresh,
      child: Semantics(
        identifier: 'game-history-list',
        child: ListView(
          key: const Key('game-history-list'),
          padding: EdgeInsets.all(GameboxTokens.spacing.page),
          children: [
            if (_statistics(local.results, public) case final statistics?) ...[
              _StatisticsCard(statistics: statistics),
              SizedBox(height: GameboxTokens.spacing.layout),
            ],
            for (final item in local.pending) ...[
              _PendingCard(
                item: item,
                loading: local.loading,
                onRetry: () => local.retry(item),
              ),
              SizedBox(height: GameboxTokens.spacing.layout),
            ],
            if (hasError) ...[
              _HistoryError(
                onRetry: () async {
                  if (local.errorCode != null) await local.refresh();
                  final publicController = public;
                  if (publicController?.initialError != null ||
                      publicController?.loadMoreError != null) {
                    await publicController?.retry();
                  }
                },
              ),
              SizedBox(height: GameboxTokens.spacing.layout),
            ],
            if (items.isEmpty && local.pending.isEmpty && !hasError)
              const GameboxAsyncPanel(
                icon: Icons.history_toggle_off_outlined,
                title: '还没有已结束的对局',
                message: '完成一局五子棋后，战绩会显示在这里。',
              ),
            for (final item in items) ...[
              switch (item) {
                _LocalHistoryItem(:final record) => _LocalResultCard(
                  result: record,
                ),
                _PublicHistoryItem(:final entry) => _PublicResultCard(
                  result: entry,
                ),
              },
              SizedBox(height: GameboxTokens.spacing.layout),
            ],
            if (public?.isLoadingMore ?? false)
              Padding(
                padding: EdgeInsets.all(GameboxTokens.spacing.page),
                child: const Center(child: CircularProgressIndicator()),
              ),
          ],
        ),
      ),
    );
  }
}

sealed class _HistoryItem {
  const _HistoryItem();
  String get matchId;
  DateTime get finishedAt;
}

final class _LocalHistoryItem extends _HistoryItem {
  const _LocalHistoryItem(this.record);
  final GameHistoryRecord record;

  @override
  String get matchId => record.authoritative.matchId;

  @override
  DateTime get finishedAt => DateTime.fromMillisecondsSinceEpoch(
    record.authoritative.finishedAt,
    isUtc: true,
  );
}

final class _PublicHistoryItem extends _HistoryItem {
  const _PublicHistoryItem(this.entry);
  final MatchHistoryEntry entry;

  @override
  String get matchId => entry.id;

  @override
  DateTime get finishedAt => entry.finishedAt;
}

List<_HistoryItem> _mergedItems(
  List<GameHistoryRecord> local,
  List<MatchHistoryEntry> public,
) {
  final localIds = local.map((record) => record.authoritative.matchId).toSet();
  final items = <_HistoryItem>[
    ...local.map(_LocalHistoryItem.new),
    ...public
        .where((entry) => !localIds.contains(entry.id))
        .map(_PublicHistoryItem.new),
  ];
  items.sort((a, b) {
    final byTime = b.finishedAt.compareTo(a.finishedAt);
    return byTime != 0 ? byTime : a.matchId.compareTo(b.matchId);
  });
  return items;
}

_UnifiedStatistics? _statistics(
  List<GameHistoryRecord> local,
  MatchHistoryController? public,
) {
  final publicStatistics = public?.statistics;
  final additions = publicStatistics == null
      ? local
      : local.where((record) => record.source == GameResultSource.lan);
  var wins = publicStatistics?.wins ?? 0;
  var losses = publicStatistics?.losses ?? 0;
  var draws = publicStatistics?.draws ?? 0;
  for (final record in additions) {
    switch (record.outcome) {
      case LocalGameOutcome.win:
        wins += 1;
      case LocalGameOutcome.loss:
        losses += 1;
      case LocalGameOutcome.draw:
        draws += 1;
    }
  }
  final total = wins + losses + draws;
  if (total == 0 && publicStatistics == null && local.isEmpty) return null;
  return _UnifiedStatistics(
    matches: total,
    wins: wins,
    losses: losses,
    draws: draws,
  );
}

final class _UnifiedStatistics {
  const _UnifiedStatistics({
    required this.matches,
    required this.wins,
    required this.losses,
    required this.draws,
  });

  final int matches;
  final int wins;
  final int losses;
  final int draws;
}

final class _StatisticsCard extends StatelessWidget {
  const _StatisticsCard({required this.statistics});
  final _UnifiedStatistics statistics;

  @override
  Widget build(BuildContext context) {
    final winRate = statistics.matches == 0
        ? 0
        : (statistics.wins / statistics.matches * 100).round();
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
              Text('战绩统计', style: Theme.of(context).textTheme.titleMedium),
              SizedBox(height: GameboxTokens.spacing.compact),
              Wrap(
                spacing: GameboxTokens.spacing.page,
                runSpacing: GameboxTokens.spacing.layout,
                children: [
                  Text('胜率 $winRate%'),
                  Text('有效对局 ${statistics.matches}'),
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

final class _PendingCard extends StatelessWidget {
  const _PendingCard({
    required this.item,
    required this.loading,
    required this.onRetry,
  });

  final PendingGameResultRecord item;
  final bool loading;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        title: const Text('战绩保存待重试'),
        subtitle: const Text('重新连接后可恢复这局战绩。'),
        trailing: Semantics(
          identifier: 'retry-pending-${item.matchId}',
          child: FilledButton.tonal(
            onPressed: loading ? null : onRetry,
            child: const Text('重试'),
          ),
        ),
      ),
    );
  }
}

final class _HistoryError extends StatelessWidget {
  const _HistoryError({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const GameboxAsyncPanel(
          icon: Icons.cloud_off_outlined,
          title: '部分战绩暂时无法加载',
          message: '已加载的记录仍可查看，请稍后重试。',
        ),
        SizedBox(height: GameboxTokens.spacing.layout),
        OutlinedButton(onPressed: onRetry, child: const Text('重试加载')),
      ],
    );
  }
}

final class _LocalResultCard extends StatelessWidget {
  const _LocalResultCard({required this.result});
  final GameHistoryRecord result;

  @override
  Widget build(BuildContext context) {
    final authoritative = result.authoritative;
    final outcome = switch (result.outcome) {
      LocalGameOutcome.win => '胜利',
      LocalGameOutcome.loss => '失败',
      LocalGameOutcome.draw => '和棋',
    };
    final reason = switch (authoritative.result) {
      'five' => '五子连珠',
      'resignation' => '认输',
      _ => '棋盘已满',
    };
    final color = result.localPlayer.color == 'black' ? '黑方' : '白方';
    return Semantics(
      identifier: 'match-history-entry-${authoritative.matchId}',
      container: true,
      child: Card(
        key: Key('history-${authoritative.matchId}'),
        child: ExpansionTile(
          title: Text(
            '${result.localPlayer.nickname} · ${result.opponent.nickname}',
          ),
          subtitle: Text(
            '$outcome · $color · $reason · ${authoritative.finalRevision} 步 · '
            '${_date(authoritative.finishedAt)}',
          ),
          children: [
            for (final event in authoritative.events)
              ListTile(
                dense: true,
                title: Text('第 ${event.revision} 步'),
                subtitle: Text(event.type),
              ),
          ],
        ),
      ),
    );
  }
}

final class _PublicResultCard extends StatelessWidget {
  const _PublicResultCard({required this.result});
  final MatchHistoryEntry result;

  @override
  Widget build(BuildContext context) {
    final outcome = switch (result.outcome) {
      MatchOutcome.win => '胜利',
      MatchOutcome.loss => '失败',
      MatchOutcome.draw => '和棋',
      MatchOutcome.abandoned => '已中止',
    };
    final color = result.color.name == 'black' ? '黑方' : '白方';
    return Semantics(
      identifier: 'match-history-entry-${result.id}',
      container: true,
      child: Card(
        key: Key('history-${result.id}'),
        child: ListTile(
          title: Text('对手：${result.opponentNickname}'),
          subtitle: Text(
            '$outcome · $color · ${result.moveCount} 步 · '
            '${_date(result.finishedAt.millisecondsSinceEpoch)}',
          ),
        ),
      ),
    );
  }
}

String _date(int millisecondsSinceEpoch) {
  final finished = DateTime.fromMillisecondsSinceEpoch(millisecondsSinceEpoch)
      .toLocal();
  return '${finished.year}-${finished.month.toString().padLeft(2, '0')}-'
      '${finished.day.toString().padLeft(2, '0')}';
}
