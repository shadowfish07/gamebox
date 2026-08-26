import 'package:flutter/material.dart';
import 'package:flutter_release_updater/flutter_release_updater.dart';

import '../../core/api/api_error.dart';
import '../../design_system/components/gamebox_async_panel.dart';
import '../../design_system/components/gamebox_page_body.dart';
import '../../design_system/components/gamebox_pending_button.dart';
import '../../design_system/generated/gamebox_tokens.g.dart';
import '../gomoku/gomoku_models.dart';
import '../update/update_action.dart';
import 'game_catalog.dart';
import 'home_controller.dart';
import 'opponent_page.dart';

final class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.nickname,
    this.controller,
    this.currentUserId,
    this.publicSection,
    this.onEditNickname,
    this.onOpenPublic,
    this.onOpenLan,
    this.lanRecovery,
    this.onOpenHistory,
    this.updateController,
  });

  final HomeController? controller;
  final String? currentUserId;
  final String nickname;
  final Widget? publicSection;
  final VoidCallback? onEditNickname;
  final VoidCallback? onOpenPublic;
  final VoidCallback? onOpenLan;
  final Widget? lanRecovery;
  final VoidCallback? onOpenHistory;
  final UpdateController? updateController;

  @override
  State<HomePage> createState() => _HomePageState();
}

final class _HomePageState extends State<HomePage> {
  @override
  void initState() {
    super.initState();
    widget.controller?.addListener(_changed);
    widget.controller?.start();
  }

  @override
  void didUpdateWidget(HomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.removeListener(_changed);
      widget.controller?.addListener(_changed);
      widget.controller?.start();
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_changed);
    super.dispose();
  }

  Future<void> _chooseOpponent() async {
    final controller = widget.controller;
    final currentUserId = widget.currentUserId;
    if (controller == null || currentUserId == null) return;
    final error = await Navigator.of(context).push<ApiError?>(
      MaterialPageRoute<ApiError?>(
        settings: const RouteSettings(name: 'public/opponents'),
        builder: (_) =>
            OpponentPage(controller: controller, currentUserId: currentUserId),
      ),
    );
    if (mounted && error != null) _showError(error);
  }

  Future<void> _continueMatch() async {
    final error = await widget.controller?.openActiveMatch();
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
    final error = await widget.controller?.cancelActiveMatch();
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
    return Semantics(
      key: const Key('home-shell'),
      label: 'home-shell',
      container: true,
      explicitChildNodes: true,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Gamebox'),
          actions: [
            if (widget.onEditNickname != null)
              IconButton(
                key: const Key('edit-local-nickname'),
                tooltip: '编辑昵称',
                onPressed: widget.onEditNickname,
                icon: const Icon(Icons.edit_outlined),
              ),
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
                    SizedBox(height: GameboxTokens.spacing.page),
                    Semantics(
                      key: const Key('open-match-history'),
                      identifier: 'open-match-history',
                      child: OutlinedButton.icon(
                        onPressed: widget.onOpenHistory,
                        icon: const Icon(Icons.history),
                        label: const Text('我的战绩'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (widget.publicSection case final publicSection?) ...[
              Card(
                key: const Key('public-section'),
                child: Padding(
                  padding: EdgeInsets.all(GameboxTokens.components.pagePadding),
                  child: publicSection,
                ),
              ),
            ],
            if (widget.lanRecovery case final recovery?)
              recovery
            else if (controller != null &&
                controller.status == null &&
                controller.isLoading)
              const GameboxAsyncPanel(
                icon: Icons.sports_esports_outlined,
                title: '正在加载游戏',
                message: '请稍候，正在获取最新对局状态。',
                isLoading: true,
              )
            else if (controller != null &&
                controller.status == null &&
                controller.lastError != null)
              _HomeError(
                message: controller.lastError!.message,
                onRetry: controller.refresh,
              )
            else if (controller != null && controller.status == null)
              const GameboxAsyncPanel(
                icon: Icons.sports_esports_outlined,
                title: '正在加载游戏',
                message: '请稍候，正在获取最新对局状态。',
                isLoading: true,
              )
            else
              _GomokuCard(
                status: controller?.status,
                isLaunching: controller?.isLaunching ?? false,
                isMutating: controller?.isMutating ?? false,
                onChoose: widget.onOpenPublic ?? _chooseOpponent,
                onLan: widget.onOpenLan,
                onContinue: _continueMatch,
                onCancel: _cancelMatch,
              ),
          ],
        ),
      ),
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
    required this.onLan,
    required this.onContinue,
    required this.onCancel,
  });

  final GomokuStatus? status;
  final bool isLaunching;
  final bool isMutating;
  final VoidCallback onChoose;
  final VoidCallback? onLan;
  final VoidCallback onContinue;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final descriptor = gameCatalog.single;
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
              status == null
                  ? '可直接局域网对战，也可注册后使用公网匹配'
                  : status is GomokuIdleStatus
                  ? '可开始新对局'
                  : '对局进行中',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            SizedBox(height: GameboxTokens.spacing.page),
            Text('公网对战', style: Theme.of(context).textTheme.titleMedium),
            SizedBox(height: GameboxTokens.spacing.layout),
            switch (status) {
              null => _ActionButton(
                semanticKey: const Key('open-public-mode'),
                semanticLabel: 'open-public-mode',
                onPressed: isMutating ? null : onChoose,
                label: '使用邀请码注册',
                pendingLabel: '正在打开注册',
              ),
              GomokuIdleStatus _ => _ActionButton(
                semanticKey: const Key('choose-opponent'),
                semanticLabel: 'choose-opponent',
                onPressed: isMutating ? null : onChoose,
                label: '选择对手',
                pendingLabel: '正在创建对局',
                isPending: isMutating,
              ),
              GomokuActiveStatus active => _ActiveMatchActions(
                active: active,
                isLaunching: isLaunching,
                isMutating: isMutating,
                onContinue: onContinue,
                onCancel: onCancel,
              ),
            },
            SizedBox(height: GameboxTokens.spacing.page),
            Text('局域网对战', style: Theme.of(context).textTheme.titleMedium),
            SizedBox(height: GameboxTokens.spacing.layout),
            Semantics(
              key: const Key('open-lan-mode'),
              identifier: 'open-lan-mode',
              child: OutlinedButton.icon(
                onPressed: onLan,
                icon: const Icon(Icons.wifi_tethering),
                label: const Text('打开局域网模式'),
              ),
            ),
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
  });

  final GomokuActiveStatus active;
  final bool isLaunching;
  final bool isMutating;
  final VoidCallback onContinue;
  final VoidCallback onCancel;

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
        _ActionButton(
          semanticKey: const Key('continue-match'),
          semanticLabel: 'continue-match',
          onPressed: isMutating ? null : onContinue,
          label: '继续对局',
          pendingLabel: '正在启动对局',
          isPending: isLaunching,
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
