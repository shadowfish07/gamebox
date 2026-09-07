import 'package:flutter/material.dart';

import '../../design_system/generated/gamebox_tokens.g.dart';
import 'scratch_social_api.dart';
import 'scratch_players_page.dart';

class ScratchCardOwners extends StatefulWidget {
  const ScratchCardOwners({
    super.key,
    required this.api,
    required this.card,
    this.beforeLoad,
  });
  final ScratchSocialApi api;
  final int card;
  final Future<void> Function()? beforeLoad;
  @override
  State<ScratchCardOwners> createState() => _ScratchCardOwnersState();
}

class _ScratchCardOwnersState extends State<ScratchCardOwners> {
  final _players = <ScratchPlayer>[];
  String _cursor = '';
  bool _loading = false, _failed = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      await widget.beforeLoad?.call();
      final page = await widget.api.list(_cursor, widget.card);
      if (!mounted) return;
      setState(() {
        for (final player in page.players) {
          _players.removeWhere((old) => old.userId == player.userId);
          _players.add(player);
        }
        _cursor = page.nextCursor;
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Divider(),
      Text('拥有这张卡的玩家', style: Theme.of(context).textTheme.titleMedium),
      SizedBox(height: GameboxTokens.spacing.compact),
      for (final player in _players)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.person_outline),
          title: Text(player.nickname),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '×${player.counts[widget.card]}',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => ScratchPlayerCollectionPage(player: player),
            ),
          ),
        ),
      if (_loading) const LinearProgressIndicator(),
      if (_failed)
        Row(
          children: [
            const Expanded(child: Text('暂时无法读取玩家')),
            TextButton(onPressed: _load, child: const Text('重试')),
          ],
        )
      else if (!_loading && _players.isEmpty)
        const Text('还没有玩家获得这张卡')
      else if (!_loading && _cursor.isNotEmpty)
        TextButton(onPressed: _load, child: const Text('查看更多玩家')),
    ],
  );
}
