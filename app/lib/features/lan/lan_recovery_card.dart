import 'package:flutter/material.dart';

import 'lan_room_controller.dart';

final class LanRecoveryCard extends StatelessWidget {
  const LanRecoveryCard({super.key, required this.controller});

  final LanRoomController controller;

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    if (state is LanIdle || state is LanRoomFailure) {
      return const SizedBox.shrink();
    }
    return Card(
      key: const Key('lan-recovery-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              state is LanRecoveryCorrupt ? '局域网房间数据损坏' : '有未完成的局域网对局',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            if (state is! LanRecoveryCorrupt)
              Semantics(
                identifier: 'continue-lan-room',
                button: true,
                child: FilledButton(
                  key: const Key('continue-lan-room'),
                  onPressed: controller.continueHost,
                  child: const Text('继续局域网对局'),
                ),
              ),
            const SizedBox(height: 8),
            OutlinedButton(
              key: const Key('abandon-lan-room'),
              onPressed: () =>
                  _confirm(context, corrupt: state is LanRecoveryCorrupt),
              child: Text(state is LanRecoveryCorrupt ? '删除损坏房间' : '放弃'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirm(BuildContext context, {required bool corrupt}) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('lan-abandon-confirmation'),
        title: Text(corrupt ? '删除损坏房间？' : '放弃局域网对局？'),
        content: Text(
          corrupt ? '损坏的对局无法生成可信战绩。此操作会删除本机恢复数据。' : '已经开始的对局会按认输结束，未开始的房间只会取消。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('返回'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(corrupt ? '确认删除' : '确认放弃'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (corrupt) {
      await controller.discardCorrupt(confirmed: true);
    } else {
      await controller.cancelOrResign(confirmed: true);
    }
  }
}
