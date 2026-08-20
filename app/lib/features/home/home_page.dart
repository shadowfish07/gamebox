import 'package:flutter/material.dart';

import '../../core/api/api_error.dart';
import '../gomoku/gomoku_models.dart';
import 'game_catalog.dart';
import 'home_controller.dart';
import 'opponent_page.dart';

final class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.controller,
    required this.currentUserId,
    required this.nickname,
  });

  final HomeController controller;
  final String currentUserId;
  final String nickname;

  @override
  State<HomePage> createState() => _HomePageState();
}

final class _HomePageState extends State<HomePage> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    widget.controller.start();
  }

  @override
  void didUpdateWidget(HomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
      widget.controller.start();
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
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

  Future<void> _cancelMatch() async {
    final error = await widget.controller.cancelActiveMatch();
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
      appBar: AppBar(title: const Text('Gamebox')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              '你好，${widget.nickname}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 20),
            if (controller.status == null && controller.isLoading)
              const Center(child: CircularProgressIndicator())
            else if (controller.status == null && controller.lastError != null)
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
                isCancelling: controller.isCancelling,
                onChoose: _chooseOpponent,
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
        Text(message, textAlign: TextAlign.center),
        const SizedBox(height: 16),
        Semantics(
          key: const Key('retry-home'),
          label: 'retry-home',
          container: true,
          button: true,
          onTap: onRetry,
          excludeSemantics: true,
          child: FilledButton(onPressed: onRetry, child: const Text('重试')),
        ),
      ],
    );
  }
}

final class _GomokuCard extends StatelessWidget {
  const _GomokuCard({
    required this.status,
    required this.isLaunching,
    required this.isCancelling,
    required this.onChoose,
    required this.onContinue,
    required this.onCancel,
  });

  final GomokuStatus status;
  final bool isLaunching;
  final bool isCancelling;
  final VoidCallback onChoose;
  final VoidCallback onContinue;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final descriptor = gameCatalog.single;
    return Semantics(
      key: const Key('game-gomoku'),
      label: 'game-gomoku',
      container: true,
      explicitChildNodes: true,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                descriptor.title,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text('${descriptor.playerCount} 人对战'),
              const SizedBox(height: 16),
              switch (status) {
                GomokuIdleStatus _ => _ActionButton(
                  semanticKey: const Key('choose-opponent'),
                  semanticLabel: 'choose-opponent',
                  onPressed: onChoose,
                  child: const Text('选择对手'),
                ),
                GomokuActiveStatus active => _ActiveMatchActions(
                  active: active,
                  isLaunching: isLaunching,
                  isCancelling: isCancelling,
                  onContinue: onContinue,
                  onCancel: onCancel,
                ),
              },
            ],
          ),
        ),
      ),
    );
  }
}

final class _ActiveMatchActions extends StatelessWidget {
  const _ActiveMatchActions({
    required this.active,
    required this.isLaunching,
    required this.isCancelling,
    required this.onContinue,
    required this.onCancel,
  });

  final GomokuActiveStatus active;
  final bool isLaunching;
  final bool isCancelling;
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
          onPressed: isLaunching ? null : onContinue,
          child: isLaunching
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('继续对局'),
        ),
        if (match.revision == 0) ...[
          const SizedBox(height: 8),
          Semantics(
            key: const Key('cancel-match'),
            label: 'cancel-match',
            container: true,
            button: true,
            enabled: !isCancelling,
            onTap: isCancelling ? null : onCancel,
            excludeSemantics: true,
            child: TextButton(
              onPressed: isCancelling ? null : onCancel,
              child: const Text('取消未开始对局'),
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
    return Semantics(
      key: semanticKey,
      label: semanticLabel,
      container: true,
      button: true,
      enabled: onPressed != null,
      onTap: onPressed,
      excludeSemantics: true,
      child: FilledButton(onPressed: onPressed, child: child),
    );
  }
}
