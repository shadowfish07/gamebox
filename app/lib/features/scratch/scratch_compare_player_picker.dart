import 'package:flutter/material.dart';

import '../../design_system/generated/gamebox_tokens.g.dart';
import 'scratch_social_api.dart';

class ScratchComparePlayerPicker extends StatefulWidget {
  const ScratchComparePlayerPicker({
    super.key,
    required this.api,
    this.excludeUserId,
  });
  final ScratchSocialApi api;
  final String? excludeUserId;

  @override
  State<ScratchComparePlayerPicker> createState() =>
      _ScratchComparePlayerPickerState();
}

class _ScratchComparePlayerPickerState
    extends State<ScratchComparePlayerPicker> {
  final _players = <ScratchPlayer>[];
  final _search = TextEditingController();
  String _cursor = '';
  bool _loading = false;
  bool _failed = false;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  // Search walks the same paginated collection API; results are not limited
  // to the first page. Closing the picker stops scheduling further requests.
  Future<void> _load() async {
    if (_loading || _finished) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      do {
        final page = await widget.api.list(_cursor);
        if (!mounted) return;
        setState(() {
          for (final player in page.players) {
            _players.removeWhere((old) => old.userId == player.userId);
            if (player.userId != widget.excludeUserId) _players.add(player);
          }
          _cursor = page.nextCursor;
          _finished = _cursor.isEmpty;
        });
      } while (!_finished && _search.text.trim().isNotEmpty);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _queryChanged(String _) {
    setState(() {});
    if (!_loading && !_finished && !_failed && _search.text.trim().isNotEmpty) {
      _load();
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final players = _players
        .where((p) => p.nickname.toLowerCase().contains(query))
        .toList();
    return Scaffold(
      appBar: AppBar(title: const Text('选择对比好友')),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.all(GameboxTokens.spacing.page),
              child: TextField(
                key: const Key('compare-player-search'),
                controller: _search,
                onChanged: _queryChanged,
                decoration: const InputDecoration(
                  labelText: '搜索昵称',
                  prefixIcon: Icon(Icons.search),
                ),
              ),
            ),
            if (_loading) const LinearProgressIndicator(),
            if (_failed)
              Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: GameboxTokens.spacing.page,
                ),
                child: Row(
                  children: [
                    const Expanded(child: Text('暂时无法读取玩家')),
                    TextButton(
                      key: const Key('compare-players-retry'),
                      onPressed: _loading ? null : _load,
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: ListView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: EdgeInsets.symmetric(
                  horizontal: GameboxTokens.spacing.page,
                ),
                children: [
                  for (final player in players)
                    ListTile(
                      key: ValueKey('compare-player-${player.userId}'),
                      leading: const Icon(Icons.person_outline),
                      title: Text(
                        player.nickname,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text('已收集 ${player.collected} 种'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.pop(context, player),
                    ),
                  if (players.isEmpty && !_loading && !_failed && _finished)
                    Padding(
                      padding: EdgeInsets.all(GameboxTokens.spacing.page),
                      child: Text(
                        query.isEmpty ? '暂无其他玩家' : '没有找到这位好友',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  if (!_finished && !_loading && !_failed)
                    TextButton(
                      key: const Key('compare-players-more'),
                      onPressed: _load,
                      child: const Text('查看更多玩家'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
