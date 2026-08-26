import 'package:flutter/material.dart';

import '../../core/api/api_error.dart';
import '../../design_system/components/gamebox_async_panel.dart';
import '../../design_system/components/gamebox_page_body.dart';
import '../../design_system/generated/gamebox_tokens.g.dart';
import '../gomoku/gomoku_models.dart';
import 'rps_controller.dart';
import 'rps_models.dart';

final class RpsOpponentPage extends StatefulWidget {
  const RpsOpponentPage({
    super.key,
    required this.controller,
    required this.currentUserId,
  });

  final RpsController controller;
  final String currentUserId;

  @override
  State<RpsOpponentPage> createState() => _RpsOpponentPageState();
}

final class _RpsOpponentPageState extends State<RpsOpponentPage> {
  List<GomokuOpponent>? _opponents;
  RpsFormat _format = RpsFormat.singleRound;
  String? _creatingId;
  String? _error;
  var _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final opponents = await widget.controller.fetchOpponents();
      if (!mounted) return;
      setState(() {
        _loading = false;
        _opponents = opponents
            .where((item) => item.id != widget.currentUserId)
            .toList(growable: false);
      });
    } catch (caught) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = caught is ApiError ? caught.message : '无法加载对手，请重试';
      });
    }
  }

  Future<void> _choose(GomokuOpponent opponent) async {
    if (_creatingId != null ||
        opponent.availability != OpponentAvailability.idle) {
      return;
    }
    setState(() {
      _creatingId = opponent.id;
      _error = null;
    });
    final error = await widget.controller.createAndOpen(opponent.id, _format);
    if (!mounted) return;
    if (error == null || widget.controller.status is RpsActiveStatus) {
      Navigator.of(context).pop<ApiError?>(error);
      return;
    }
    if (error.code == 'opponent_busy') {
      await _load();
      if (!mounted) return;
    }
    setState(() {
      _creatingId = null;
      _error = error.message;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('创建石头剪刀布对局')),
      body: GameboxPageBody(
        children: [
          Text('选择赛制', style: Theme.of(context).textTheme.titleMedium),
          SizedBox(height: GameboxTokens.spacing.layout),
          SegmentedButton<RpsFormat>(
            key: const Key('rps-format-selector'),
            segments: RpsFormat.values
                .map(
                  (format) => ButtonSegment<RpsFormat>(
                    value: format,
                    label: Semantics(
                      identifier: 'rps-format-${format.wireValue}',
                      button: true,
                      child: Text(format.label),
                    ),
                  ),
                )
                .toList(growable: false),
            selected: {_format},
            onSelectionChanged: _creatingId == null
                ? (selection) => setState(() => _format = selection.single)
                : null,
          ),
          SizedBox(height: GameboxTokens.spacing.section),
          Text('选择对手', style: Theme.of(context).textTheme.titleMedium),
          SizedBox(height: GameboxTokens.spacing.layout),
          if (_loading && _opponents == null)
            const GameboxAsyncPanel(
              key: Key('rps-opponent-loading'),
              icon: Icons.group_outlined,
              title: '正在加载对手',
              message: '请稍候，正在获取最新状态。',
              isLoading: true,
            )
          else if (_error != null && _opponents == null)
            GameboxAsyncPanel(
              icon: Icons.cloud_off_outlined,
              title: '无法加载对手',
              message: _error!,
              actionLabel: '重试',
              onAction: _load,
            )
          else ...[
            if (_error != null)
              GameboxAsyncPanel(
                icon: Icons.error_outline,
                title: '无法创建对局',
                message: _error!,
              ),
            for (final opponent in _opponents ?? const <GomokuOpponent>[])
              _OpponentTile(
                opponent: opponent,
                pending: _creatingId == opponent.id,
                disabled: _creatingId != null,
                onTap: () => _choose(opponent),
              ),
          ],
        ],
      ),
    );
  }
}

final class _OpponentTile extends StatelessWidget {
  const _OpponentTile({
    required this.opponent,
    required this.pending,
    required this.disabled,
    required this.onTap,
  });

  final GomokuOpponent opponent;
  final bool pending;
  final bool disabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final idle = opponent.availability == OpponentAvailability.idle;
    final status =
        '${opponent.presence == OpponentPresence.online ? '在线' : '离线'} · ${idle ? '可邀请' : '游戏中'}';
    return Card(
      child: Semantics(
        identifier: 'rps-opponent-${opponent.id}',
        button: true,
        enabled: idle && !disabled,
        child: ListTile(
          key: Key('rps-opponent-${opponent.id}'),
          leading: const CircleAvatar(child: Icon(Icons.person_outline)),
          title: Text(opponent.nickname),
          subtitle: Text(status),
          trailing: pending
              ? SizedBox.square(
                  dimension: GameboxTokens.components.smallProgressSize,
                  child: const CircularProgressIndicator(),
                )
              : const Icon(Icons.chevron_right),
          enabled: idle && !disabled,
          onTap: idle && !disabled ? onTap : null,
        ),
      ),
    );
  }
}
