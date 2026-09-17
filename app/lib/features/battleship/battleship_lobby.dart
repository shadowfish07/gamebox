import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design_system/components/gamebox_page_body.dart';
import '../../design_system/generated/gamebox_tokens.g.dart';
import 'battleship_api.dart';
import 'battleship_controller.dart';
import 'battleship_models.dart';
import 'battleship_page.dart';

final class BattleshipLobby extends StatefulWidget {
  const BattleshipLobby({
    super.key,
    required this.api,
    this.store = const SecureSeaPendingStore(),
  });
  final BattleshipApi api;
  final SeaPendingStore store;
  @override
  State<BattleshipLobby> createState() => _BattleshipLobbyState();
}

final class _BattleshipLobbyState extends State<BattleshipLobby>
    with WidgetsBindingObserver {
  List<SeaMatch> matches = [];
  String cursor = '';
  bool loading = false, foreground = true, opened = false;
  String? error;
  Timer? timer;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]),
    );
    unawaited(_load());
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(SystemChrome.setPreferredOrientations([]));
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    foreground = s == AppLifecycleState.resumed;
    if (foreground && !opened) {
      unawaited(_load());
    } else {
      timer?.cancel();
    }
  }

  Future<void> _load({bool more = false}) async {
    if (loading || !foreground || opened) return;
    setState(() => loading = true);
    timer?.cancel();
    try {
      final retainedCount = matches.length;
      final refreshed = <SeaMatch>[];
      var nextCursor = more ? cursor : '';
      do {
        final page = await widget.api.matches(nextCursor);
        if (!mounted) return;
        refreshed.addAll(page.items);
        nextCursor = page.nextCursor;
      } while (!more &&
          nextCursor.isNotEmpty &&
          refreshed.length < retainedCount);
      // Commit the full refresh together so a later-page failure retains the
      // previous list and cursor, including the user's loaded range.
      setState(() {
        matches = more ? [...matches, ...refreshed] : refreshed;
        cursor = nextCursor;
        error = null;
      });
    } catch (_) {
      if (mounted) setState(() => error = '无法加载对局，请重试');
    } finally {
      if (mounted) {
        setState(() => loading = false);
        if (foreground && !opened) {
          timer = Timer(const Duration(seconds: 15), () => _load());
        }
      }
    }
  }

  Future<void> _open(SeaMatch match) async {
    if (opened) return;
    opened = true;
    timer?.cancel();
    final controller = BattleshipController(widget.api, match.id, widget.store);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BattleshipPage(controller: controller),
      ),
    );
    opened = false;
    if (mounted) await _load();
  }

  Future<void> _choose() async {
    if (opened) return;
    opened = true;
    timer?.cancel();
    final match = await Navigator.of(context).push<SeaMatch>(
      MaterialPageRoute(builder: (_) => _SeaOpponents(api: widget.api)),
    );
    opened = false;
    if (!mounted) return;
    if (match != null) {
      await _open(match);
    } else {
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final sorted = [...matches]
      ..sort((a, b) {
        final aRank = a.ended
            ? 2
            : a.yourTurn || a.phase == 'placement' && !a.ready
            ? 0
            : 1;
        final bRank = b.ended
            ? 2
            : b.yourTurn || b.phase == 'placement' && !b.ready
            ? 0
            : 1;
        return aRank.compareTo(bRank);
      });
    return Scaffold(
      appBar: AppBar(
        title: const Text('海战棋'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: loading ? null : () => _load(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: GameboxPageBody(
        footer: FilledButton.icon(
          key: const Key('sea-new'),
          onPressed: _choose,
          icon: const Icon(Icons.add),
          label: const Text('开始新对局'),
        ),
        children: [
          if (loading) const LinearProgressIndicator(),
          if (error != null)
            TextButton(onPressed: () => _load(), child: Text(error!)),
          if (matches.isEmpty && !loading && error == null)
            Padding(
              padding: EdgeInsets.symmetric(
                vertical: GameboxTokens.spacing.xlarge,
              ),
              child: const Center(child: Text('还没有海战棋对局')),
            ),
          for (final m in sorted)
            Card(
              child: ListTile(
                key: ValueKey('sea-match-${m.id}'),
                leading: Icon(
                  m.ended ? Icons.flag_outlined : Icons.sailing_outlined,
                ),
                title: Text(m.opponentName),
                subtitle: Text(m.status(widget.api.userId)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _open(m),
              ),
            ),
          if (cursor.isNotEmpty)
            TextButton(
              onPressed: loading ? null : () => _load(more: true),
              child: const Text('加载更多'),
            ),
        ],
      ),
    );
  }
}

final class _SeaOpponents extends StatefulWidget {
  const _SeaOpponents({required this.api});
  final BattleshipApi api;
  @override
  State<_SeaOpponents> createState() => _SeaOpponentsState();
}

final class _SeaOpponentsState extends State<_SeaOpponents> {
  List<SeaOpponent> players = [];
  String cursor = '';
  bool busy = false;
  String? error;
  final ids = <String, String>{};
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final p = await widget.api.opponents(cursor);
      if (mounted) {
        setState(() {
          players.addAll(p.items);
          cursor = p.nextCursor;
          error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => error = '无法加载对手，请重试');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _create(SeaOpponent p) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final match = await widget.api.create(
        ids.putIfAbsent(p.id, battleshipId),
        p.id,
      );
      if (mounted) Navigator.pop(context, match);
    } catch (_) {
      if (mounted) setState(() => error = '创建未确认，请重试或返回对局列表');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('选择海战棋对手')),
    body: GameboxPageBody(
      children: [
        if (busy) const LinearProgressIndicator(),
        if (error != null)
          TextButton(onPressed: busy ? null : _load, child: Text(error!)),
        if (players.isEmpty && !busy && error == null) const Text('暂时没有可选对手'),
        for (final p in players)
          Card(
            child: ListTile(
              key: ValueKey('sea-opponent-${p.id}'),
              title: Text(p.nickname),
              trailing: const Icon(Icons.chevron_right),
              onTap: busy ? null : () => _create(p),
            ),
          ),
        if (cursor.isNotEmpty)
          Padding(
            padding: EdgeInsets.all(GameboxTokens.spacing.compact),
            child: TextButton(
              onPressed: busy ? null : _load,
              child: const Text('加载更多'),
            ),
          ),
      ],
    ),
  );
}
