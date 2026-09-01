import 'package:flutter/material.dart';
import 'package:flutter_release_updater/flutter_release_updater.dart';

import '../../core/api/api_error.dart';
import '../../design_system/components/gamebox_async_panel.dart';
import '../../design_system/components/gamebox_page_body.dart';
import '../../design_system/components/gamebox_pending_button.dart';
import '../../design_system/generated/gamebox_tokens.g.dart';
import '../gomoku/gomoku_models.dart';
import '../history/match_history_api.dart';
import '../history/match_history_controller.dart';
import '../history/match_history_models.dart';
import '../history/match_history_page.dart';
import '../rps/rps_controller.dart';
import '../rps/rps_models.dart';
import '../rps/rps_opponent_page.dart';
import '../update/update_action.dart';
import 'game_catalog.dart';
import 'home_controller.dart';
import 'opponent_page.dart';

final class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.controller,
    required this.currentUserId,
    required this.nickname,
    required this.historyApi,
    this.rpsController,
    this.updateController,
  });

  final HomeController controller;
  final String currentUserId;
  final String nickname;
  final MatchHistoryApi historyApi;
  final RpsController? rpsController;
  final UpdateController? updateController;

  @override
  State<HomePage> createState() => _HomePageState();
}

final class _HomePageState extends State<HomePage> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    widget.controller.start();
    widget.rpsController?.addListener(_changed);
    widget.rpsController?.start();
  }

  @override
  void didUpdateWidget(HomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
      widget.controller.start();
    }
    if (oldWidget.rpsController != widget.rpsController) {
      oldWidget.rpsController?.removeListener(_changed);
      widget.rpsController?.addListener(_changed);
      widget.rpsController?.start();
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    widget.rpsController?.removeListener(_changed);
    super.dispose();
  }

  Future<void> _chooseOpponent() async {
    final error = await Navigator.of(context).push<ApiError?>(
      MaterialPageRoute<ApiError?>(
        builder: (_) => OpponentPage(
          controller: widget.controller,
          currentUserId: widget.currentUserId,
        ),
      ),
    );
    if (mounted && error != null) _showError(error);
  }

  Future<void> _continueMatch() async {
    final error = await widget.controller.openActiveMatch();
    if (mounted && error != null) _showError(error);
  }

  Future<void> _openHistory(MatchHistoryGame game) {
    final controller = MatchHistoryController(
      api: widget.historyApi,
      game: game,
    );
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => MatchHistoryPage(controller: controller),
      ),
    );
  }

  Future<void> _chooseRpsOpponent() async {
    final controller = widget.rpsController;
    if (controller == null) return;
    final error = await Navigator.of(context).push<ApiError?>(
      MaterialPageRoute<ApiError?>(
        builder: (_) => RpsOpponentPage(
          controller: controller,
          currentUserId: widget.currentUserId,
        ),
      ),
    );
    if (mounted && error != null) _showError(error);
  }

  Future<void> _continueRpsMatch() async {
    final error = await widget.rpsController?.openActiveMatch();
    if (mounted && error != null) _showError(error);
  }

  Future<void> _cancelMatch() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('取消这局尚未开始的对局？'),
        content: const Text('取消后，双方将返回空闲状态。'),
        actions: [
          Semantics(
            identifier: 'dismiss-cancel-match',
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('保留对局'),
            ),
          ),
          Semantics(
            identifier: 'confirm-cancel-match',
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('取消对局'),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final error = await widget.controller.cancelActiveMatch();
    if (mounted && error != null) _showError(error);
  }

  Future<void> _cancelRpsMatch() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('取消这局石头剪刀布对局？'),
        content: const Text('取消后，双方将返回空闲状态。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('保留对局'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('取消对局'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final error = await widget.rpsController?.cancelActiveMatch();
    if (mounted && error != null) _showError(error);
  }

  void _showError(ApiError error) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(error.message)));
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Scaffold(
      key: const Key('home-shell'),
      appBar: AppBar(
        title: const Text('Gamebox'),
        actions: [
          if (widget.updateController case final controller?)
            UpdateActionButton(controller: controller),
        ],
      ),
      body: GameboxPageBody(
        children: [
          Card(
            child: Padding(
              padding: EdgeInsets.all(GameboxTokens.components.pagePadding),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '你好，${widget.nickname}',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ],
              ),
            ),
          ),
          _buildGomoku(controller),
          if (widget.rpsController case final RpsController rpsController) ...[
            SizedBox(height: GameboxTokens.spacing.section),
            _buildRps(rpsController),
          ],
        ],
      ),
    );
  }

  Widget _buildGomoku(HomeController controller) {
    if (controller.status == null && controller.isLoading) {
      return const GameboxAsyncPanel(
        icon: Icons.sports_esports_outlined,
        title: '正在加载游戏',
        message: '请稍候，正在获取最新对局状态。',
        isLoading: true,
      );
    }
    if (controller.status == null && controller.lastError != null) {
      return _HomeError(
        message: controller.lastError!.message,
        onRetry: controller.refresh,
      );
    }
    final status = controller.status;
    if (status == null) return const SizedBox.shrink();
    return _GomokuCard(
      status: status,
      isLaunching: controller.isLaunching,
      isMutating: controller.isMutating,
      onChoose: _chooseOpponent,
      onContinue: _continueMatch,
      onCancel: _cancelMatch,
      onOpenHistory: () => _openHistory(MatchHistoryGame.gomoku),
    );
  }

  Widget _buildRps(RpsController controller) {
    if (controller.status == null && controller.isLoading) {
      return const GameboxAsyncPanel(
        icon: Icons.casino_outlined,
        title: '正在加载石头剪刀布',
        message: '请稍候，正在获取最新对局状态。',
        isLoading: true,
      );
    }
    if (controller.status == null && controller.lastError != null) {
      return _HomeError(
        message: controller.lastError!.message,
        onRetry: controller.refresh,
      );
    }
    final status = controller.status;
    if (status == null) return const SizedBox.shrink();
    return _RpsCard(
      status: status,
      isLaunching: controller.isLaunching,
      isMutating: controller.isMutating,
      onChoose: _chooseRpsOpponent,
      onContinue: _continueRpsMatch,
      onCancel: _cancelRpsMatch,
      onOpenHistory: () => _openHistory(MatchHistoryGame.rps),
    );
  }
}

final class _HomeError extends StatelessWidget {
  const _HomeError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        GameboxAsyncPanel(
          icon: Icons.cloud_off_outlined,
          title: '暂时无法加载',
          message: message,
        ),
        SizedBox(height: GameboxTokens.spacing.page),
        _ActionButton(
          semanticKey: const Key('retry-home'),
          semanticLabel: 'retry-home',
          label: '重试',
          pendingLabel: '正在重试',
          onPressed: onRetry,
        ),
      ],
    );
  }
}

final class _GomokuCard extends StatelessWidget {
  const _GomokuCard({
    required this.status,
    required this.isLaunching,
    required this.isMutating,
    required this.onChoose,
    required this.onContinue,
    required this.onCancel,
    required this.onOpenHistory,
  });

  final GomokuStatus status;
  final bool isLaunching;
  final bool isMutating;
  final VoidCallback onChoose;
  final VoidCallback onContinue;
  final VoidCallback onCancel;
  final VoidCallback onOpenHistory;

  @override
  Widget build(BuildContext context) {
    final descriptor = gameCatalog.firstWhere((game) => game.id == 'gomoku');
    return Card(
      child: Padding(
        padding: EdgeInsets.all(GameboxTokens.components.pagePadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MergeSemantics(
              key: const Key('game-gomoku'),
              child: Semantics(
                identifier: 'game-gomoku',
                header: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      descriptor.title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    SizedBox(height: GameboxTokens.spacing.layout),
                    Text('${descriptor.playerCount} 人 · 回合制'),
                  ],
                ),
              ),
            ),
            SizedBox(height: GameboxTokens.spacing.layout),
            Text(
              status is GomokuIdleStatus ? '可开始新对局' : '对局进行中',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            SizedBox(height: GameboxTokens.spacing.page),
            switch (status) {
              GomokuIdleStatus _ => _PrimaryAndHistoryActions(
                game: MatchHistoryGame.gomoku,
                onOpenHistory: onOpenHistory,
                primary: _ActionButton(
                  semanticKey: const Key('choose-opponent'),
                  semanticLabel: 'choose-opponent',
                  onPressed: isMutating ? null : onChoose,
                  label: '选择对手',
                  pendingLabel: '正在创建对局',
                  isPending: isMutating,
                ),
              ),
              GomokuActiveStatus active => _ActiveMatchActions(
                active: active,
                isLaunching: isLaunching,
                isMutating: isMutating,
                onContinue: onContinue,
                onCancel: onCancel,
                onOpenHistory: onOpenHistory,
              ),
            },
          ],
        ),
      ),
    );
  }
}

final class _ActiveMatchActions extends StatelessWidget {
  const _ActiveMatchActions({
    required this.active,
    required this.isLaunching,
    required this.isMutating,
    required this.onContinue,
    required this.onCancel,
    required this.onOpenHistory,
  });

  final GomokuActiveStatus active;
  final bool isLaunching;
  final bool isMutating;
  final VoidCallback onContinue;
  final VoidCallback onCancel;
  final VoidCallback onOpenHistory;

  @override
  Widget build(BuildContext context) {
    final match = active.match;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('对手：${match.opponent.nickname}'),
        Text('你的颜色：${match.color == GomokuColor.black ? '黑方' : '白方'}'),
        Text('当前步数：${match.revision}'),
        SizedBox(height: GameboxTokens.spacing.page),
        _PrimaryAndHistoryActions(
          game: MatchHistoryGame.gomoku,
          onOpenHistory: onOpenHistory,
          primary: _ActionButton(
            semanticKey: const Key('continue-match'),
            semanticLabel: 'continue-match',
            onPressed: isMutating ? null : onContinue,
            label: '继续对局',
            pendingLabel: '正在启动对局',
            isPending: isLaunching,
          ),
        ),
        if (match.revision == 0) ...[
          SizedBox(height: GameboxTokens.spacing.layout),
          MergeSemantics(
            key: const Key('cancel-match'),
            child: Semantics(
              identifier: 'cancel-match',
              child: TextButton(
                onPressed: isMutating ? null : onCancel,
                child: const Text('取消未开始对局'),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

final class _RpsCard extends StatelessWidget {
  const _RpsCard({
    required this.status,
    required this.isLaunching,
    required this.isMutating,
    required this.onChoose,
    required this.onContinue,
    required this.onCancel,
    required this.onOpenHistory,
  });

  final RpsStatus status;
  final bool isLaunching;
  final bool isMutating;
  final VoidCallback onChoose;
  final VoidCallback onContinue;
  final VoidCallback onCancel;
  final VoidCallback onOpenHistory;

  @override
  Widget build(BuildContext context) {
    final descriptor = gameCatalog.firstWhere((game) => game.id == 'rps');
    return Card(
      key: const Key('game-rps'),
      child: Padding(
        padding: EdgeInsets.all(GameboxTokens.components.pagePadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              descriptor.title,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            SizedBox(height: GameboxTokens.spacing.layout),
            Text('${descriptor.playerCount} 人 · 同时出拳'),
            SizedBox(height: GameboxTokens.spacing.layout),
            Text(
              status is RpsIdleStatus ? '可开始新对局' : '对局进行中',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            SizedBox(height: GameboxTokens.spacing.page),
            switch (status) {
              RpsIdleStatus _ => _PrimaryAndHistoryActions(
                game: MatchHistoryGame.rps,
                onOpenHistory: onOpenHistory,
                primary: _ActionButton(
                  semanticKey: const Key('rps-choose-opponent'),
                  semanticLabel: 'rps-choose-opponent',
                  onPressed: isMutating ? null : onChoose,
                  label: '选择赛制和对手',
                  pendingLabel: '正在创建对局',
                  isPending: isMutating,
                ),
              ),
              RpsActiveStatus(:final match) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('对手：${match.opponent.nickname}'),
                  Semantics(
                    identifier: 'rps-active-format-${match.format.wireValue}',
                    child: Text('赛制：${match.format.label}'),
                  ),
                  Text('当前轮次：第 ${match.revision ~/ 2 + 1} 轮'),
                  SizedBox(height: GameboxTokens.spacing.page),
                  _PrimaryAndHistoryActions(
                    game: MatchHistoryGame.rps,
                    onOpenHistory: onOpenHistory,
                    primary: _ActionButton(
                      semanticKey: const Key('rps-continue-match'),
                      semanticLabel: 'rps-continue-match',
                      onPressed: isMutating ? null : onContinue,
                      label: '继续对局',
                      pendingLabel: '正在启动对局',
                      isPending: isLaunching,
                    ),
                  ),
                  if (match.revision == 0) ...[
                    SizedBox(height: GameboxTokens.spacing.layout),
                    TextButton(
                      key: const Key('rps-cancel-match'),
                      onPressed: isMutating ? null : onCancel,
                      child: const Text('取消未开始对局'),
                    ),
                  ],
                ],
              ),
            },
          ],
        ),
      ),
    );
  }
}

final class _PrimaryAndHistoryActions extends StatelessWidget {
  const _PrimaryAndHistoryActions({
    required this.game,
    required this.primary,
    required this.onOpenHistory,
  });

  final MatchHistoryGame game;
  final Widget primary;
  final VoidCallback onOpenHistory;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: primary),
        SizedBox(width: GameboxTokens.spacing.layout),
        _HistoryButton(game: game, onPressed: onOpenHistory),
      ],
    );
  }
}

final class _HistoryButton extends StatelessWidget {
  const _HistoryButton({required this.game, required this.onPressed});

  final MatchHistoryGame game;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final identifier = 'open-${game.id}-history';
    return Semantics(
      key: Key(identifier),
      identifier: identifier,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: const Icon(Icons.history),
        label: const Text('战绩'),
      ),
    );
  }
}

final class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.semanticKey,
    required this.semanticLabel,
    required this.onPressed,
    required this.label,
    required this.pendingLabel,
    this.isPending = false,
  });

  final Key semanticKey;
  final String semanticLabel;
  final VoidCallback? onPressed;
  final String label;
  final String pendingLabel;
  final bool isPending;

  @override
  Widget build(BuildContext context) {
    return GameboxPendingButton(
      key: semanticKey,
      identifier: semanticLabel,
      label: label,
      pendingLabel: pendingLabel,
      isPending: isPending,
      onPressed: onPressed,
    );
  }
}
