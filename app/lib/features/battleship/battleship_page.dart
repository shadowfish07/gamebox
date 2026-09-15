import 'dart:async';

import 'package:flutter/material.dart';

import '../../design_system/components/gamebox_page_body.dart';
import '../../design_system/components/gamebox_pending_button.dart';
import '../../design_system/generated/gamebox_tokens.g.dart';
import 'battleship_board.dart';
import 'battleship_controller.dart';
import 'battleship_models.dart';

final class BattleshipPage extends StatefulWidget {
  const BattleshipPage({super.key, required this.controller});
  final BattleshipController controller;
  @override
  State<BattleshipPage> createState() => _BattleshipPageState();
}

final class _BattleshipPageState extends State<BattleshipPage>
    with WidgetsBindingObserver {
  int shipId = 0;
  bool vertical = false, ownBoard = false;
  int? target;
  BattleshipController get c => widget.controller;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    c.addListener(_changed);
    unawaited(c.start());
  }

  void _changed() {
    if (mounted) {
      final m = c.match;
      if (target != null && m != null && m.shots.any((s) => s.cell == target)) {
        target = null;
      }
      setState(() {});
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      c.setForeground(state == AppLifecycleState.resumed);
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    c.removeListener(_changed);
    c.dispose();
    super.dispose();
  }

  Future<void> _danger(
    String kind,
    String title,
    String message,
    String action,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('继续对局'),
          ),
          TextButton(
            key: const Key('sea-confirm-danger'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action),
          ),
        ],
      ),
    );
    if (ok == true && mounted) await c.submit(kind);
  }

  void _place(int cell) {
    final ship = FleetShip(shipId, cell, vertical);
    final ships = [...c.shownShips.where((s) => s.id != shipId), ship];
    if (!validFleet(ships)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('这里放不下这艘船')));
      return;
    }
    unawaited(c.submit('save', ships: ships));
  }

  void _rules() => showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('海战棋规则'),
      content: const SingleChildScrollView(
        child: Text(
          '每人五艘船，占 5、4、3、3、2 格。舰船可横放或竖放，可以相邻，不能重叠。\n\n双方轮流打一发，命中后也换人。打中一艘船的所有格子才算击沉，先击沉全部敌舰获胜。\n\n× 表示命中，圆点表示未命中，边框标出已击沉的船。\n\n布阵和出手不限时，离开后随时回来继续。',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) {
    final m = c.match;
    final can = c.canAct;
    final pad = GameboxTokens.spacing.compact;
    return Scaffold(
      appBar: AppBar(
        title: const Text('海战棋'),
        actions: [
          IconButton(
            tooltip: '游戏规则',
            onPressed: _rules,
            icon: const Icon(Icons.help_outline),
          ),
          if (m != null && !m.ended)
            PopupMenuButton<String>(
              tooltip: '对局操作',
              enabled: can,
              onSelected: (v) {
                if (v == 'cancel') {
                  unawaited(_danger(v, '取消这局海战棋？', '取消后不计胜负。', '取消对局'));
                }
                if (v == 'resign') {
                  unawaited(_danger(v, '认输并结束对局？', '对方将获得本局胜利。', '认输'));
                }
                if (v == 'offer_end') {
                  unawaited(_danger(v, '提议结束对局？', '双方同意后取消，不计胜负。', '提议结束'));
                }
              },
              itemBuilder: (_) => [
                if (m.phase == 'placement')
                  const PopupMenuItem(value: 'cancel', child: Text('取消对局')),
                if (m.phase == 'battle')
                  const PopupMenuItem(value: 'resign', child: Text('认输')),
                if (m.phase == 'battle' && m.endOffer.isEmpty)
                  const PopupMenuItem(value: 'offer_end', child: Text('提议结束')),
              ],
            ),
        ],
      ),
      body: GameboxPageBody(
        footer: _footer(m, can),
        children: [
          if (m == null) const Center(child: Text('正在加载对局')),
          SizedBox(
            height: GameboxTokens.spacing.base,
            child: c.syncing || c.busy
                ? const LinearProgressIndicator(key: Key('sea-progress'))
                : null,
          ),
          if (c.error != null || c.pendingAction != null && !c.busy)
            Card(
              child: Padding(
                padding: EdgeInsets.all(pad),
                child: Row(
                  children: [
                    Expanded(child: Text(c.error ?? '有一项操作待确认')),
                    TextButton(
                      key: const Key('sea-retry'),
                      onPressed: c.busy ? null : () => c.retry(),
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
            ),
          if (m != null) ...[
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  m.status(c.api.userId),
                  key: const Key('sea-status'),
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                SizedBox(height: pad),
                Text(
                  '对手：${m.opponentName}',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
            if (m.endOffer.isNotEmpty)
              Card(
                child: Padding(
                  padding: EdgeInsets.all(pad),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        m.endOffer == c.api.userId
                            ? '已提议结束，等待对方同意'
                            : '对方提议结束对局',
                      ),
                      Wrap(
                        spacing: pad,
                        children: [
                          if (m.endOffer != c.api.userId)
                            TextButton(
                              onPressed: can
                                  ? () => _danger(
                                      'offer_end',
                                      '同意结束这局？',
                                      '本局将取消，不计胜负。',
                                      '同意结束',
                                    )
                                  : null,
                              child: const Text('同意结束'),
                            ),
                          TextButton(
                            onPressed: can
                                ? () => c.submit('decline_end')
                                : null,
                            child: Text(
                              m.endOffer == c.api.userId ? '撤回提议' : '继续对局',
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            if (m.phase == 'placement') ...[
              BattleshipBoard(
                ships: c.shownShips,
                preview: m.ready
                    ? null
                    : c.shownShips.where((s) => s.id == shipId).firstOrNull,
                pending: c.pendingAction != null,
                shots: const [],
                onCell: can && !m.ready ? _place : null,
              ),
              if (!m.ready)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: pad,
                      children: [
                        for (var i = 0; i < 5; i++)
                          ChoiceChip(
                            key: ValueKey('sea-ship-$i'),
                            label: Text('${fleetNames[i]} ${fleetLengths[i]}'),
                            selected: shipId == i,
                            onSelected: can
                                ? (_) => setState(() => shipId = i)
                                : null,
                          ),
                      ],
                    ),
                    SizedBox(height: pad),
                    Wrap(
                      spacing: pad,
                      children: [
                        OutlinedButton.icon(
                          key: const Key('sea-rotate'),
                          onPressed: can
                              ? () => setState(() => vertical = !vertical)
                              : null,
                          icon: const Icon(Icons.rotate_90_degrees_ccw),
                          label: Text(vertical ? '竖向' : '横向'),
                        ),
                        OutlinedButton.icon(
                          key: const Key('sea-random'),
                          onPressed: can
                              ? () => c.submit('save', ships: randomFleet())
                              : null,
                          icon: const Icon(Icons.shuffle),
                          label: const Text('随机布阵'),
                        ),
                      ],
                    ),
                  ],
                ),
            ] else ...[
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('对方海域')),
                  ButtonSegment(value: true, label: Text('我的海域')),
                ],
                selected: {ownBoard},
                onSelectionChanged: (s) => setState(() => ownBoard = s.single),
              ),
              BattleshipBoard(
                ships: ownBoard ? m.ownShips : m.enemyShips,
                shots: ownBoard ? m.incoming : m.shots,
                selected: ownBoard ? null : target,
                pending: c.busy,
                onCell: !ownBoard && can && m.yourTurn
                    ? (cell) {
                        if (!m.shots.any((s) => s.cell == cell)) {
                          setState(() => target = cell);
                        }
                      }
                    : null,
              ),
              Row(
                children: [
                  Expanded(child: Text('已击沉 ${m.sunkCount} / 5')),
                  if (m.shots.isNotEmpty)
                    Text(
                      '${coordinate(m.shots.last.cell)} · ${m.shots.last.hit ? '命中' : '未命中'}',
                    ),
                ],
              ),
              if (m.enemyShips.isNotEmpty)
                Wrap(
                  spacing: pad,
                  children: [
                    for (final ship in m.enemyShips)
                      Chip(label: Text(fleetNames[ship.id])),
                  ],
                ),
            ],
          ],
        ],
      ),
    );
  }

  Widget? _footer(SeaMatch? m, bool can) {
    if (m == null) return null;
    if (m.ended) {
      if (m.nextMatchId.isNotEmpty) {
        return FilledButton(
          key: const Key('sea-next'),
          onPressed: () {
            final controller = BattleshipController(
              c.api,
              m.nextMatchId,
              c.store,
            );
            Navigator.of(context).pushReplacement(
              MaterialPageRoute<void>(
                builder: (_) => BattleshipPage(controller: controller),
              ),
            );
          },
          child: const Text('进入下一局'),
        );
      }
      return GameboxPendingButton(
        identifier: 'sea-rematch',
        label: m.rematchRequested
            ? '等待对方再来一局'
            : m.enemyRematchRequested
            ? '同意再来一局'
            : '再来一局',
        pendingLabel: '发送中',
        isPending: c.busy,
        onPressed: can && !m.rematchRequested
            ? () => c.submit('rematch')
            : null,
      );
    }
    if (m.phase == 'placement') {
      return GameboxPendingButton(
        identifier: 'sea-ready',
        label: m.ready ? '等待对方布阵' : '准备好了',
        pendingLabel: '保存中',
        isPending: c.busy,
        onPressed: can && !m.ready && c.shownShips.length == 5
            ? () => c.submit('ready', ships: c.shownShips)
            : null,
      );
    }
    return GameboxPendingButton(
      identifier: 'sea-fire',
      label: !m.yourTurn
          ? '等待对方出手'
          : target == null
          ? '选择攻击位置'
          : '向 ${coordinate(target!)} 开火',
      pendingLabel: '开火中',
      isPending: c.busy,
      onPressed: can && m.yourTurn && target != null && !ownBoard
          ? () => c.submit('fire', cell: target!)
          : null,
    );
  }
}
