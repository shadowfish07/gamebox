import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../design_system/generated/gamebox_tokens.g.dart';
import 'reversi_controller.dart';
import 'reversi_models.dart';

final class ReversiPage extends StatefulWidget {
  const ReversiPage({super.key, required this.controller});
  final ReversiController controller;
  @override
  State<ReversiPage> createState() => _ReversiPageState();
}

final class _ReversiPageState extends State<ReversiPage>
    with WidgetsBindingObserver {
  ReversiController get controller => widget.controller;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    controller.addListener(_changed);
    unawaited(controller.start());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      controller.resume();
    } else {
      controller.pause();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.removeListener(_changed);
    controller.dispose();
    super.dispose();
  }

  Future<void> _resign() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('认输并结束这局黑白棋？'),
        content: const Text('认输后，对方获胜。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('继续对局'),
          ),
          TextButton(
            key: const Key('reversi-confirm-resign'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('认输'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) controller.resign();
  }

  void _rules() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('黑白棋规则'),
        content: const SingleChildScrollView(
          child: Text(
            '黑方先走。落子必须夹住并翻转对方棋子，横、竖、斜八个方向都有效。\n\n一次落子夹住的棋子全部翻转，不产生连锁翻转。\n\n无处可下时自动跳过；双方都无处可下时结束，棋子多的一方获胜，数量相同为平局。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = controller.snapshot;
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      key: const Key('reversi-page'),
      appBar: AppBar(
        title: const Text('黑白棋'),
        leading: BackButton(key: const Key('reversi-back')),
        actions: [
          IconButton(
            key: const Key('reversi-rules'),
            onPressed: _rules,
            tooltip: '规则',
            icon: const Icon(Icons.help_outline),
          ),
          if (s?.active == true)
            PopupMenuButton<String>(
              key: const Key('reversi-menu'),
              onSelected: (_) => _resign(),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'resign',
                  enabled: controller.canAct && s!.revision > 0,
                  child: const Text('认输'),
                ),
              ],
            ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: EdgeInsets.all(GameboxTokens.components.pagePadding),
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: GameboxTokens.components.pageMaxWidth,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (s != null) ...[
                      Row(
                        children: [
                          Expanded(child: _score(s, 'black', s.blackCount)),
                          SizedBox(width: GameboxTokens.spacing.page),
                          Expanded(child: _score(s, 'white', s.whiteCount)),
                        ],
                      ),
                      SizedBox(height: GameboxTokens.spacing.page),
                    ],
                    SizedBox(
                      height: GameboxTokens.components.minimumTouchTarget,
                      child: Center(
                        child: Text(
                          _status(s),
                          key: const Key('reversi-status'),
                          style: Theme.of(context).textTheme.titleMedium,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                    if (s == null &&
                        controller.connection != ReversiConnection.failed)
                      const AspectRatio(
                        aspectRatio: 1,
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (s != null)
                      ReversiBoard(
                        snapshot: s,
                        pendingCell: controller.pendingCell,
                        enabled: controller.canAct && controller.myTurn,
                        onMove: controller.move,
                      ),
                    SizedBox(height: GameboxTokens.spacing.page),
                    if (s?.active == true && s?.passedColor != null)
                      Text(
                        '${s!.passedColor == 'black' ? '黑方' : '白方'}无处可下，跳过回合',
                        key: const Key('reversi-pass'),
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    if (controller.error != null)
                      Text(
                        controller.error!,
                        key: const Key('reversi-error'),
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium
                            ?.copyWith(color: colors.error),
                      ),
                    if (controller.connection == ReversiConnection.failed)
                      OutlinedButton(
                        key: const Key('reversi-retry'),
                        onPressed: controller.reconnect,
                        child: const Text('重新连接'),
                      ),
                    if (s != null && !s.active)
                      FilledButton(
                        key: const Key('reversi-result-back'),
                        onPressed: () => Navigator.pop(context),
                        child: const Text('返回大厅'),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _score(ReversiSnapshot s, String color, int count) {
    final mine =
        controller.userId != null && s.colorFor(controller.userId!) == color;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: s.active && s.nextColor == color
          ? scheme.secondaryContainer
          : scheme.surfaceContainerLow,
      child: Padding(
        padding: EdgeInsets.all(GameboxTokens.spacing.page),
        child: Row(
          children: [
            SizedBox(
              width: GameboxTokens.spacing.section,
              height: GameboxTokens.spacing.section,
              child: _Disc(color: color == 'black' ? 1 : 2),
            ),
            SizedBox(width: GameboxTokens.spacing.compact),
            Expanded(
              child: Text(
                '${color == 'black' ? '黑方' : '白方'}${mine ? ' · 你' : ''}',
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
            Text(
              '$count',
              key: Key('reversi-score-$color'),
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ],
        ),
      ),
    );
  }

  String _status(ReversiSnapshot? s) {
    if (s != null && !s.active) {
      if (s.status == 'cancelled') return '对局已取消';
      if (s.status == 'abandoned') return '对局已结束';
      if (s.result == 'draw') return '平局';
      return s.winnerUserId == controller.userId ? '你赢了' : '对方获胜';
    }
    if (controller.pending) return '正在提交…';
    return switch (controller.connection) {
      ReversiConnection.connecting => '正在连接…',
      ReversiConnection.reconnecting => '正在恢复对局…',
      ReversiConnection.failed => '连接已断开',
      ReversiConnection.paused => '对局已暂停',
      ReversiConnection.ready => controller.myTurn ? '轮到你了' : '等待对方落子',
    };
  }
}

final class ReversiBoard extends StatelessWidget {
  const ReversiBoard({
    super.key,
    required this.snapshot,
    required this.pendingCell,
    required this.enabled,
    required this.onMove,
  });
  final ReversiSnapshot snapshot;
  final int? pendingCell;
  final bool enabled;
  final ValueChanged<int> onMove;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AspectRatio(
      aspectRatio: 1,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(GameboxTokens.shape.card),
        child: ColoredBox(
          color: colors.primaryContainer,
          child: GridView.builder(
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            itemCount: 64,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 8,
            ),
            itemBuilder: (context, i) {
              final piece = snapshot.board[i];
              final legal = enabled && snapshot.legalMoves.contains(i);
              return Semantics(
                identifier: 'reversi-cell-$i',
                child: Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    key: Key('reversi-cell-$i'),
                    onTap: legal ? () => onMove(i) : null,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: colors.onPrimaryContainer.withValues(
                            alpha: 0.18,
                          ),
                          width: 0.5,
                        ),
                      ),
                      child: Padding(
                        padding: EdgeInsets.all(GameboxTokens.spacing.base),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            if (piece != 0) _FlippingDisc(color: piece),
                            if (piece == 0 && legal)
                              FractionallySizedBox(
                                widthFactor: 0.2,
                                heightFactor: 0.2,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: colors.onPrimaryContainer.withValues(
                                      alpha: 0.45,
                                    ),
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ),
                            if (pendingCell == i)
                              Padding(
                                padding: EdgeInsets.all(
                                  GameboxTokens.spacing.base,
                                ),
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            if (snapshot.lastMove == i)
                              Align(
                                alignment: Alignment.bottomRight,
                                child: Icon(
                                  Icons.circle,
                                  size: 8,
                                  color: colors.tertiary,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

final class _FlippingDisc extends StatefulWidget {
  const _FlippingDisc({required this.color});
  final int color;
  @override
  State<_FlippingDisc> createState() => _FlippingDiscState();
}

final class _FlippingDiscState extends State<_FlippingDisc>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: GameboxTokens.motion.slow,
    value: 1,
  );
  int? _previous;
  @override
  void didUpdateWidget(_FlippingDisc old) {
    super.didUpdateWidget(old);
    if (old.color != widget.color) {
      _previous = old.color;
      _animation.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _animation,
    builder: (_, child) {
      final t = _animation.value;
      return Transform(
        alignment: Alignment.center,
        transform: Matrix4.diagonal3Values(
          math.cos(t * math.pi).abs().clamp(0.04, 1),
          1,
          1,
        ),
        child: _Disc(
          color: t < 0.5 ? (_previous ?? widget.color) : widget.color,
        ),
      );
    },
  );
}

final class _Disc extends StatelessWidget {
  const _Disc({required this.color});
  final int color;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: color == 1
          ? GameboxTokens.gameColors.blackPiece
          : GameboxTokens.gameColors.whitePiece,
      border: Border.all(
        color: GameboxTokens.gameColors.blackPiece.withValues(alpha: 0.3),
      ),
    ),
    child: const SizedBox.expand(),
  );
}
