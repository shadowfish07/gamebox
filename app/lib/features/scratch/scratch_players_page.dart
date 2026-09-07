import 'package:flutter/material.dart';

import '../../core/api/api_error.dart';
import '../../design_system/generated/gamebox_tokens.g.dart';
import 'scratch_controller.dart';
import 'scratch_social_api.dart';
import 'scratch_surface.dart';

class ScratchPlayersPage extends StatefulWidget {
  const ScratchPlayersPage({super.key, required this.api, this.beforeLoad});
  final ScratchSocialApi api;
  final Future<void> Function()? beforeLoad;
  @override
  State<ScratchPlayersPage> createState() => _ScratchPlayersPageState();
}

class _ScratchPlayersPageState extends State<ScratchPlayersPage> {
  final players = <ScratchPlayer>[];
  String cursor = '', error = '';
  bool loading = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool more = false}) async {
    if (loading) return;
    setState(() {
      loading = true;
      error = '';
    });
    try {
      await widget.beforeLoad?.call();
      final page = await widget.api.list(more ? cursor : '');
      if (!mounted) return;
      setState(() {
        if (!more) players.clear();
        for (final p in page.players) {
          players.removeWhere((old) => old.userId == p.userId);
          players.add(p);
        }
        cursor = page.nextCursor;
      });
    } catch (e) {
      if (mounted) setState(() => error = _error(e));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  String _error(Object e) => e is ApiError ? e.message : '暂时无法连接，请重试';
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.all(GameboxTokens.spacing.page),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (error.isNotEmpty)
                Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: loading ? null : () => _load(),
                  icon: const Icon(Icons.refresh),
                  label: Text(error.isEmpty ? '刷新' : '重试'),
                ),
              ),
            ],
          ),
        ),
        if (loading) const LinearProgressIndicator(),
        Expanded(
          child: players.isEmpty
              ? Center(
                  child: Text(
                    loading
                        ? '正在读取收藏'
                        : error.isNotEmpty
                        ? '收藏暂时不可用'
                        : '暂无玩家',
                  ),
                )
              : ListView.builder(
                  padding: EdgeInsets.symmetric(
                    horizontal: GameboxTokens.spacing.page,
                  ),
                  itemCount: players.length + (cursor.isEmpty ? 0 : 1),
                  itemBuilder: (context, i) {
                    if (i == players.length) {
                      return TextButton(
                        onPressed: loading ? null : () => _load(more: true),
                        child: const Text('查看更多玩家'),
                      );
                    }
                    final player = players[i];
                    return Card(
                      child: ListTile(
                        key: ValueKey('scratch-player-${player.userId}'),
                        leading: const Icon(Icons.person_outline),
                        title: Text(player.nickname),
                        subtitle: Text(
                          '已收集 ${player.collected}/${scratchCollectibles.length}',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                ScratchPlayerCollectionPage(player: player),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class ScratchPlayerCollectionPage extends StatelessWidget {
  const ScratchPlayerCollectionPage({super.key, required this.player});
  final ScratchPlayer player;
  @override
  Widget build(BuildContext context) {
    final owned = scratchCollectibles
        .where((item) => player.counts[item.index] > 0)
        .toList();
    return Scaffold(
      appBar: AppBar(title: Text('${player.nickname}的收藏')),
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: EdgeInsets.all(GameboxTokens.spacing.page),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '已收集 ${player.collected}/${scratchCollectibles.length}',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    SizedBox(height: GameboxTokens.spacing.layout),
                    for (final group in scratchGroups)
                      Text(
                        '${group.title} · ${owned.where((item) => item.groupId == group.id).length}/${scratchCollectibles.where((item) => item.groupId == group.id).length}',
                      ),
                    if (owned.isEmpty) const Text('这位玩家还没有收集到藏品'),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.all(GameboxTokens.spacing.page),
              sliver: SliverGrid.builder(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: GameboxTokens.spacing.layout,
                  mainAxisSpacing: GameboxTokens.spacing.layout,
                  childAspectRatio: .7,
                ),
                itemCount: owned.length,
                itemBuilder: (context, i) {
                  final item = owned[i];
                  return Card(
                    child: Padding(
                      padding: EdgeInsets.all(GameboxTokens.spacing.compact),
                      child: Column(
                        children: [
                          Expanded(
                            child: Center(
                              child: AspectRatio(
                                aspectRatio: 1,
                                child: CollectibleArtwork(cat: item),
                              ),
                            ),
                          ),
                          SizedBox(height: GameboxTokens.spacing.compact),
                          Text(
                            '${item.job} · ${item.name}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          ScratchRarityLabel(
                            rarity: item.rarity,
                            suffix: ' · ×${player.counts[item.index]}',
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
    );
  }
}
