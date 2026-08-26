import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/lan/lan_qr_payload.dart';
import '../../design_system/components/gamebox_async_panel.dart';
import '../../design_system/components/gamebox_page_body.dart';
import '../../design_system/components/gamebox_pending_button.dart';
import '../../design_system/generated/gamebox_tokens.g.dart';
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
      appBar: AppBar(
        leading: Semantics(
          identifier: 'lan-host-back',
          child: BackButton(onPressed: () => Navigator.of(context).pop()),
        ),
        title: const Text('创建局域网房间'),
      ),
      body: GameboxPageBody(children: [_content(state)]),
    );
  }

  Widget _content(LanRoomState state) => switch (state) {
    LanCreating() => const GameboxAsyncPanel(
      icon: Icons.wifi_tethering,
      title: '正在创建房间',
      message: '正在启动本机房间服务，请稍候。',
      isLoading: true,
    ),
    LanWaitingForGuest(:final qr, :final errorCode) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (qr != null)
          _SensitiveQr(
            payload: qr,
            title: '请让对方扫描二维码加入',
            privacyEnabled: _screenshotPrivacy,
          )
        else
          const GameboxAsyncPanel(
            icon: Icons.wifi_off_outlined,
            title: '等待可用的网络地址',
            message: '开启 Wi-Fi 或系统热点后刷新网络地址。',
          ),
        if (errorCode != null) ...[
          SizedBox(height: GameboxTokens.spacing.layout),
          Text(lanMessage(errorCode)),
        ],
        SizedBox(height: GameboxTokens.spacing.page),
        OutlinedButton.icon(
          key: const Key('refresh-lan-endpoint'),
          onPressed: widget.controller.isBusy
              ? null
              : widget.controller.refreshEndpoint,
          icon: const Icon(Icons.refresh),
          label: Text(widget.controller.isBusy ? '正在刷新网络地址' : '刷新网络地址'),
        ),
        SizedBox(height: GameboxTokens.spacing.layout),
        TextButton(
          key: const Key('cancel-lan-room'),
          onPressed: widget.controller.isBusy ? null : _confirmCancel,
          child: const Text('取消并关闭房间'),
        ),
      ],
    ),
    LanEndpointChanged(:final qr) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SensitiveQr(
          payload: qr,
          title: '网络已变化，请让对方扫码恢复',
          privacyEnabled: _screenshotPrivacy,
        ),
        SizedBox(height: GameboxTokens.spacing.page),
        GameboxPendingButton(
          key: const Key('open-host-game'),
          identifier: 'open-host-game',
          label: '进入对局',
          pendingLabel: '正在进入对局',
          isPending: widget.controller.isBusy,
          onPressed: widget.controller.isBusy
              ? null
              : widget.controller.continueHost,
        ),
      ],
    ),
    LanActive() => GameboxPendingButton(
      key: const Key('open-host-game'),
      identifier: 'open-host-game',
      label: '进入对局',
      pendingLabel: '正在进入对局',
      isPending: widget.controller.isBusy,
      onPressed: widget.controller.isBusy
          ? null
          : widget.controller.continueHost,
    ),
    LanFinishedAwaitingAck() => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const GameboxAsyncPanel(
          icon: Icons.emoji_events_outlined,
          title: '对局已经结束',
          message: '战绩会在双方确认后自动保存到“我的战绩”。',
        ),
        SizedBox(height: GameboxTokens.spacing.page),
        OutlinedButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('返回大厅'),
        ),
      ],
    ),
    LanRoomFailure(:final code) => _Failure(
      code: code,
      onRetry: () => widget.controller.createHost(widget.nickname),
    ),
    _ => const GameboxAsyncPanel(
      icon: Icons.info_outline,
      title: '房间状态已更新',
      message: '返回大厅查看最新状态。',
    ),
  };

  Future<void> _confirmCancel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('cancel-lan-room-confirmation'),
        title: const Text('取消并关闭这个房间？'),
        content: const Text('对方将无法再通过当前二维码加入。'),
        actions: [
          TextButton(
            key: const Key('dismiss-cancel-lan-room'),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('保留房间'),
          ),
          FilledButton(
            key: const Key('confirm-cancel-lan-room'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('取消并关闭房间'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.controller.cancelOrResign(confirmed: true);
    if (mounted && widget.controller.state is LanIdle) {
      Navigator.of(context).pop();
    }
  }
}

final class _SensitiveQr extends StatelessWidget {
  const _SensitiveQr({
    required this.payload,
    required this.title,
    required this.privacyEnabled,
  });

  final LanQrPayload payload;
  final String title;
  final bool privacyEnabled;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        SizedBox(height: GameboxTokens.spacing.page),
        Center(
          child: Semantics(
            identifier: 'credential-qr-sensitive',
            label: '局域网加入二维码（敏感区域，截图需遮挡）',
            child: RepaintBoundary(
              key: const Key('credential-qr-sensitive'),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: GameboxTokens.components.pageMaxWidth / 2,
                ),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: ColoredBox(
                    color:
                        GameboxTokens.lightColorScheme.surfaceContainerLowest,
                    child: Padding(
                      padding: EdgeInsets.all(GameboxTokens.spacing.page),
                      child: privacyEnabled
                          ? const Center(child: Text('二维码已遮挡'))
                          : QrImageView(data: payload.encode()),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

final class _Failure extends StatelessWidget {
  const _Failure({required this.code, required this.onRetry});

  final String code;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      GameboxAsyncPanel(
        icon: Icons.cloud_off_outlined,
        title: '暂时无法创建房间',
        message: lanMessage(code),
      ),
      SizedBox(height: GameboxTokens.spacing.page),
      FilledButton(onPressed: onRetry, child: const Text('重试创建房间')),
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
