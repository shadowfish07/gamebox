import 'package:flutter/material.dart';

import '../../core/api/api_error.dart';
import '../gomoku/gomoku_models.dart';
import 'home_controller.dart';

final class OpponentPage extends StatefulWidget {
  const OpponentPage({
    super.key,
    required this.controller,
    required this.currentUserId,
  });

  final HomeController controller;
  final String currentUserId;

  @override
  State<OpponentPage> createState() => _OpponentPageState();
}

final class _OpponentPageState extends State<OpponentPage> {
  List<GomokuOpponent>? _opponents;
  String? _creatingOpponentId;
  String? _errorMessage;
  Future<void>? _loadInFlight;
  var _generation = 0;
  var _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() {
    final existing = _loadInFlight;
    if (existing != null) return existing;
    late final Future<void> operation;
    operation = _performLoad().whenComplete(() {
      if (identical(_loadInFlight, operation)) _loadInFlight = null;
    });
    _loadInFlight = operation;
    return operation;
  }

  Future<void> _performLoad() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _errorMessage = null;
    });
    try {
      final opponents = await widget.controller.fetchOpponents();
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _errorMessage = null;
        _opponents = opponents
            .where((opponent) => opponent.id != widget.currentUserId)
            .toList(growable: false);
      });
    } catch (caught) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _errorMessage = _loadError(caught);
      });
    }
  }

  Future<void> _choose(GomokuOpponent opponent) async {
    if (_creatingOpponentId != null ||
        opponent.availability != OpponentAvailability.idle) {
      return;
    }
    setState(() {
      _creatingOpponentId = opponent.id;
      _errorMessage = null;
    });
    final error = await widget.controller.createAndOpen(opponent.id);
    if (!mounted) return;
    if (error == null ||
        (error.code != 'operation_in_progress' &&
            widget.controller.status is GomokuActiveStatus)) {
      Navigator.of(context).pop<ApiError?>(error);
      return;
    }
    if (error.code == 'opponent_busy') {
      await _load();
      if (!mounted) return;
    }
    setState(() {
      _creatingOpponentId = null;
      _errorMessage = _actionError(error);
    });
  }

  @override
  void dispose() {
    _generation += 1;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('选择对手')),
      body: SafeArea(child: _buildBody(context)),
    );
  }

  Widget _buildBody(BuildContext context) {
    final opponents = _opponents;
    if (opponents == null) {
      if (_loading) {
        return const Center(
          child: CircularProgressIndicator(key: Key('opponent-loading')),
        );
      }
      if (_errorMessage != null) {
        return _ErrorView(message: _errorMessage!, onRetry: _load);
      }
      return const SizedBox.shrink();
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 12),
      children: [
        if (_loading)
          const LinearProgressIndicator(key: Key('opponent-loading')),
        if (_errorMessage != null)
          MergeSemantics(
            key: const Key('opponent-error'),
            child: Semantics(
              identifier: 'opponent-error',
              liveRegion: true,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: Text(
                  _errorMessage!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ),
          ),
        if (opponents.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text('暂无可选对手')),
          )
        else
          for (final opponent in opponents) _opponentRow(opponent),
      ],
    );
  }

  Widget _opponentRow(GomokuOpponent opponent) {
    final creating = _creatingOpponentId == opponent.id;
    final enabled =
        !_loading &&
        _creatingOpponentId == null &&
        opponent.availability == OpponentAvailability.idle;
    final onTap = enabled ? () => _choose(opponent) : null;
    return Semantics(
      key: Key('opponent-${opponent.id}'),
      identifier: 'opponent-${opponent.id}',
      label: '${opponent.nickname}\n${_availabilityText(opponent)}',
      button: true,
      enabled: enabled,
      onTap: onTap,
      excludeSemantics: true,
      child: ListTile(
        enabled: enabled,
        title: Text(opponent.nickname),
        subtitle: Text(_availabilityText(opponent)),
        trailing: creating
            ? const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : null,
        onTap: onTap,
      ),
    );
  }

  static String _availabilityText(GomokuOpponent opponent) {
    if (opponent.availability == OpponentAvailability.busy) return '游戏中';
    return opponent.presence == OpponentPresence.offline
        ? '离线 · 可邀请'
        : '在线 · 可邀请';
  }

  static String _actionError(ApiError error) => switch (error.code) {
    'opponent_busy' => '对手已进入其他对局',
    'active_match_exists' => '你已在五子棋对局中',
    'network_error' => '网络连接失败，请稍后重试',
    'timeout' => '请求超时，请稍后重试',
    'launch_failed' => '无法启动游戏，请重试',
    'operation_in_progress' => '已有操作正在进行，请稍后重试',
    _ => '创建对局失败，请稍后重试',
  };

  static String _loadError(Object caught) => switch (caught) {
    ApiError(code: 'network_error') => '网络连接失败，请稍后重试',
    ApiError(code: 'timeout') => '请求超时，请稍后重试',
    _ => '加载对手失败，请稍后重试',
  };
}

final class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}
