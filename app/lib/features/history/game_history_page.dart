import 'package:flutter/material.dart';

import 'game_history_controller.dart';
import 'game_history_store.dart';

final class GameHistoryPage extends StatefulWidget {
  const GameHistoryPage({super.key, required this.controller});
  final GameHistoryController controller;

  @override
  State<GameHistoryPage> createState() => _GameHistoryPageState();
}

final class _GameHistoryPageState extends State<GameHistoryPage> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    widget.controller.refresh();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Scaffold(
      appBar: AppBar(title: const Text('对战记录')),
      body: controller.loading && controller.results.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: controller.refresh,
              child: Semantics(
                identifier: 'game-history-list',
                child: ListView(
                  key: const Key('game-history-list'),
                  padding: const EdgeInsets.all(16),
                  children: [
                    for (final item in controller.pending)
                      Card(
                        child: ListTile(
                          title: const Text('战绩保存待重试'),
                          subtitle: Text('对局 ${item.matchId.substring(0, 8)}'),
                          trailing: Semantics(
                            identifier: 'retry-pending-${item.matchId}',
                            button: true,
                            child: FilledButton.tonal(
                              onPressed: controller.loading
                                  ? null
                                  : () => controller.retry(item),
                              child: const Text('重试'),
                            ),
                          ),
                        ),
                      ),
                    if (controller.errorCode != null)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('暂时无法读取战绩，请稍后重试'),
                      ),
                    if (controller.results.isEmpty &&
                        controller.pending.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(32),
                        child: Center(child: Text('还没有对战记录')),
                      ),
                    for (final result in controller.results)
                      _ResultCard(result: result),
                  ],
                ),
              ),
            ),
    );
  }
}

final class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.result});
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
    final finished = DateTime.fromMillisecondsSinceEpoch(
      authoritative.finishedAt,
    ).toLocal();
    return Card(
      key: Key('history-${authoritative.matchId}'),
      child: ExpansionTile(
        title: Text(
          '${result.localPlayer.nickname} · ${result.opponent.nickname}',
        ),
        subtitle: Text(
          '$outcome · $color · $reason · ${authoritative.finalRevision} 步 · '
          '${finished.year}-${finished.month.toString().padLeft(2, '0')}-'
          '${finished.day.toString().padLeft(2, '0')}',
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
    );
  }
}
