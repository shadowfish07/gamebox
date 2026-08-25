import 'package:flutter/material.dart';

import 'lan_host_page.dart';
import 'lan_join_page.dart';
import 'lan_recovery_card.dart';
import 'lan_room_controller.dart';

final class LanModePage extends StatefulWidget {
  const LanModePage({
    super.key,
    required this.controller,
    required this.nickname,
  });
  final LanRoomController controller;
  final String nickname;

  @override
  State<LanModePage> createState() => _LanModePageState();
}

final class _LanModePageState extends State<LanModePage> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    widget.controller.initialize();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  bool get _hasRecovery =>
      widget.controller.state is! LanIdle &&
      widget.controller.state is! LanRoomFailure;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('局域网对战')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          LanRecoveryCard(controller: widget.controller),
          if (_hasRecovery) const SizedBox(height: 16),
          Semantics(
            identifier: 'create-lan-room',
            button: true,
            child: FilledButton.icon(
              key: const Key('create-lan-room'),
              onPressed: _hasRecovery
                  ? null
                  : () => Navigator.push<void>(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => LanHostPage(
                          controller: widget.controller,
                          nickname: widget.nickname,
                        ),
                      ),
                    ),
              icon: const Icon(Icons.wifi_tethering),
              label: const Text('创建房间'),
            ),
          ),
          const SizedBox(height: 12),
          Semantics(
            identifier: 'join-lan-room',
            button: true,
            child: OutlinedButton.icon(
              key: const Key('join-lan-room'),
              onPressed: _hasRecovery
                  ? null
                  : () => Navigator.push<void>(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => LanJoinPage(
                          controller: widget.controller,
                          nickname: widget.nickname,
                        ),
                      ),
                    ),
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('扫码加入'),
            ),
          ),
          const SizedBox(height: 16),
          const Text('双方只需连接同一个 Wi-Fi，或由房主开启系统热点；对局不需要互联网。'),
        ],
      ),
    ),
  );
}
