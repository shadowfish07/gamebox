import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'lan_room_controller.dart';

final class LanHostPage extends StatefulWidget {
  const LanHostPage({
    super.key,
    required this.controller,
    required this.nickname,
  });
  final LanRoomController controller;
  final String nickname;

  @override
  State<LanHostPage> createState() => _LanHostPageState();
}

final class _LanHostPageState extends State<LanHostPage> {
  static const _screenshotPrivacy = bool.fromEnvironment(
    'GAMEBOX_SCREENSHOT_PRIVACY',
  );
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    if (widget.controller.state is LanIdle) {
      widget.controller.createHost(widget.nickname);
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

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.state;
    return Scaffold(
      appBar: AppBar(title: const Text('创建局域网房间')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: switch (state) {
            LanCreating() => const Center(child: CircularProgressIndicator()),
            LanWaitingForGuest(:final qr, :final errorCode) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(qr == null ? '等待可用的 Wi-Fi 或热点地址' : '请让对方扫描二维码加入'),
                const SizedBox(height: 20),
                if (qr != null)
                  Semantics(
                    identifier: 'credential-qr-sensitive',
                    label: '局域网加入二维码（敏感区域，截图需遮挡）',
                    child: RepaintBoundary(
                      key: const Key('credential-qr-sensitive'),
                      child: ColoredBox(
                        color: Colors.white,
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: _screenshotPrivacy
                              ? const SizedBox.square(
                                  dimension: 240,
                                  child: Center(child: Text('二维码已遮挡')),
                                )
                              : QrImageView(data: qr.encode(), size: 240),
                        ),
                      ),
                    ),
                  ),
                if (errorCode != null) ...[
                  const SizedBox(height: 12),
                  const Text('请开启 Wi-Fi 或系统热点后刷新。'),
                ],
                const Spacer(),
                OutlinedButton(
                  key: const Key('refresh-lan-endpoint'),
                  onPressed: widget.controller.refreshEndpoint,
                  child: const Text('刷新网络地址'),
                ),
                TextButton(
                  key: const Key('cancel-lan-room'),
                  onPressed: () async {
                    await widget.controller.cancelOrResign(confirmed: true);
                    if (context.mounted) Navigator.pop(context);
                  },
                  child: const Text('取消房间'),
                ),
              ],
            ),
            LanActive() ||
            LanEndpointChanged() ||
            LanFinishedAwaitingAck() => Center(
              child: FilledButton(
                key: const Key('open-host-game'),
                onPressed: widget.controller.continueHost,
                child: const Text('进入对局'),
              ),
            ),
            LanRoomFailure(:final code) => _Failure(
              code: code,
              onRetry: () => widget.controller.createHost(widget.nickname),
            ),
            _ => const Center(child: Text('房间状态已更新，请返回大厅。')),
          },
        ),
      ),
    );
  }
}

final class _Failure extends StatelessWidget {
  const _Failure({required this.code, required this.onRetry});
  final String code;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Text(lanMessage(code), textAlign: TextAlign.center),
      const SizedBox(height: 16),
      FilledButton(onPressed: onRetry, child: const Text('重试')),
    ],
  );
}

String lanMessage(String code) => switch (code) {
  'no_network_address' => '没有可用的 Wi-Fi 或热点地址。',
  'room_locked' => '房间已锁定。',
  'join_expired' => '加入二维码已过期。',
  'camera_denied' => '相机不可用，请手动输入。',
  _ => '局域网操作失败，请稍后重试。',
};
