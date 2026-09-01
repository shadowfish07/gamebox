import 'package:flutter/material.dart';

import '../../core/api/api_error.dart';
import '../../design_system/components/gamebox_async_panel.dart';
import '../../design_system/components/gamebox_page_body.dart';
import '../../design_system/generated/gamebox_tokens.g.dart';
import '../gomoku/gomoku_models.dart';
import 'home_controller.dart';

final class OpponentPage extends StatefulWidget {
  const OpponentPage({
    super.key,
    required this.controller,
    required this.currentUserId,
    this.pageTitle = '选择对手',
    this.semanticPrefix = '',
    this.gameTitle = '五子棋',
  });

  final HomeController controller;
  final String currentUserId;
  final String pageTitle;
  final String semanticPrefix;
  final String gameTitle;

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
      appBar: AppBar(title: Text(widget.pageTitle)),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final opponents = _opponents;
    if (opponents == null) {
      if (_loading) {
        return GameboxPageBody(
          children: [
            GameboxAsyncPanel(
              key: Key('${widget.semanticPrefix}opponent-loading'),
              icon: Icons.group_outlined,
              title: '正在加载对手',
              message: '请稍候，正在获取最新在线状态。',
              isLoading: true,
            ),
          ],
        );
      }
      if (_errorMessage != null) {
        return GameboxPageBody(
          children: [_ErrorView(message: _errorMessage!, onRetry: _load)],
        );
      }
      return const GameboxPageBody(children: []);
    }
    return GameboxPageBody(
      children: [
        if (_loading)
          LinearProgressIndicator(
            key: Key('${widget.semanticPrefix}opponent-loading'),
          ),
        if (_errorMessage != null)
          MergeSemantics(
            key: Key('${widget.semanticPrefix}opponent-error'),
            child: Semantics(
              identifier: '${widget.semanticPrefix}opponent-error',
              liveRegion: true,
              child: GameboxAsyncPanel(
                icon: Icons.error_outline,
                title: '无法创建对局',
                message: _errorMessage!,
                actionLabel: '重试',
                onAction: _load,
              ),
            ),
          ),
        if (opponents.isEmpty)
          const GameboxAsyncPanel(
            icon: Icons.group_outlined,
            title: '暂无可选对手',
            message: '朋友在线后即可发起对局。',
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
      key: Key('${widget.semanticPrefix}opponent-${opponent.id}'),
      identifier: '${widget.semanticPrefix}opponent-${opponent.id}',
      label: creating
          ? '${opponent.nickname}\n${_availabilityText(opponent)}\n正在创建对局'
          : '${opponent.nickname}\n${_availabilityText(opponent)}',
      button: true,
      enabled: enabled,
      onTap: onTap,
      excludeSemantics: true,
      child: ListTile(
        enabled: enabled,
        leading: const CircleAvatar(child: Icon(Icons.person_outline)),
        title: Text(opponent.nickname),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_availabilityText(opponent)),
            if (creating) const Text('正在创建对局'),
          ],
        ),
        trailing: creating
            ? SizedBox.square(
                dimension: GameboxTokens.components.smallProgressSize,
                child: const CircularProgressIndicator(),
              )
            : null,
        onTap: onTap,
      ),
    );
  }

  static String _availabilityText(GomokuOpponent opponent) {
    if (opponent.availability == OpponentAvailability.busy) {
      return opponent.presence == OpponentPresence.offline
          ? '离线 · 游戏中'
          : '在线 · 游戏中';
    }
    return opponent.presence == OpponentPresence.offline
        ? '离线 · 可邀请'
        : '在线 · 可邀请';
  }

  String _actionError(ApiError error) => switch (error.code) {
    'opponent_busy' => '对手已进入其他对局',
    'active_match_exists' => '你已在${widget.gameTitle}对局中',
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
    return GameboxAsyncPanel(
      icon: Icons.cloud_off_outlined,
      title: '暂时无法加载对手',
      message: message,
      actionLabel: '重试',
      onAction: onRetry,
    );
  }
}
