import 'package:flutter/material.dart';

import '../../core/api/api_error.dart';
import '../gomoku/gomoku_models.dart';
import '../update/update_action.dart';
import '../update/update_controller.dart';
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
    this.updateController,
  });

  final HomeController? controller;
  final String? currentUserId;
  final String nickname;
  final Widget? publicSection;
  final VoidCallback? onEditNickname;
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
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                '你好，${widget.nickname}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 20),
              if (widget.publicSection case final publicSection?)
                Card(
                  key: const Key('public-section'),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: publicSection,
                  ),
                )
              else if (controller == null)
                const SizedBox.shrink()
              else if (controller.status == null && controller.isLoading)
                const Center(child: CircularProgressIndicator())
              else if (controller.status == null &&
                  controller.lastError != null)
                _HomeError(
                  message: controller.lastError!.message,
                  onRetry: controller.refresh,
                )
              else if (controller.status == null)
                const Center(child: CircularProgressIndicator())
              else
                _GomokuCard(
                  status: controller.status!,
                  isLaunching: controller.isLaunching,
                  isMutating: controller.isMutating,
                  onChoose: _chooseOpponent,
                  onContinue: _continueMatch,
                  onCancel: _cancelMatch,
                ),
            ],
          ),
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
        Text(message, textAlign: TextAlign.center),
        const SizedBox(height: 16),
        _ActionButton(
          semanticKey: const Key('retry-home'),
          semanticLabel: 'retry-home',
          onPressed: onRetry,
          child: const Text('重试'),
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
  });

  final GomokuStatus status;
  final bool isLaunching;
  final bool isMutating;
  final VoidCallback onChoose;
  final VoidCallback onContinue;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final descriptor = gameCatalog.single;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
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
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),
                    Text('${descriptor.playerCount} 人对战'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            switch (status) {
              GomokuIdleStatus _ => _ActionButton(
                semanticKey: const Key('choose-opponent'),
                semanticLabel: 'choose-opponent',
                onPressed: isMutating ? null : onChoose,
                child: const Text('选择对手'),
              ),
              GomokuActiveStatus active => _ActiveMatchActions(
                active: active,
                isLaunching: isLaunching,
                isMutating: isMutating,
                onContinue: onContinue,
                onCancel: onCancel,
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
        const SizedBox(height: 16),
        _ActionButton(
          semanticKey: const Key('continue-match'),
          semanticLabel: 'continue-match',
          onPressed: isMutating ? null : onContinue,
          child: isLaunching
              ? Semantics(
                  label: '正在启动对局',
                  liveRegion: true,
                  child: const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : const Text('继续对局'),
        ),
        if (match.revision == 0) ...[
          const SizedBox(height: 8),
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
    required this.child,
  });

  final Key semanticKey;
  final String semanticLabel;
  final VoidCallback? onPressed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      key: semanticKey,
      child: Semantics(
        identifier: semanticLabel,
        child: FilledButton(onPressed: onPressed, child: child),
      ),
    );
  }
}
