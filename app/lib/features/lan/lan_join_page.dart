import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../design_system/components/gamebox_async_panel.dart';
import '../../design_system/components/gamebox_page_body.dart';
import '../../design_system/components/gamebox_pending_button.dart';
import '../../design_system/generated/gamebox_tokens.g.dart';
import 'lan_host_page.dart';
import 'lan_room_controller.dart';

final class LanJoinPage extends StatefulWidget {
  const LanJoinPage({
    super.key,
    required this.controller,
    required this.nickname,
  });
  final LanRoomController controller;
  final String nickname;

  @override
  State<LanJoinPage> createState() => _LanJoinPageState();
}

final class _LanJoinPageState extends State<LanJoinPage> {
  final _textController = TextEditingController();
  late final MobileScannerController _scanner = MobileScannerController(
    autoStart: false,
    formats: const [BarcodeFormat.qrCode],
  );
  var _scanning = false;
  var _accepted = false;
  var _scannerError = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _startScanner() async {
    setState(() {
      _scanning = true;
      _scannerError = false;
    });
    try {
      await _scanner.start();
    } on MobileScannerException {
      if (mounted) {
        setState(() {
          _scanning = false;
          _scannerError = true;
        });
      }
    }
  }

  Future<void> _submit(String raw) async {
    if (_accepted || raw.trim().isEmpty) return;
    _accepted = true;
    await _scanner.stop();
    await widget.controller.joinRaw(raw.trim(), widget.nickname);
    if (widget.controller.state is LanRoomFailure) _accepted = false;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _textController.dispose();
    _scanner.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.state;
    return Scaffold(
      appBar: AppBar(
        leading: Semantics(
          identifier: 'lan-join-back',
          child: BackButton(onPressed: () => Navigator.of(context).pop()),
        ),
        title: const Text('加入局域网房间'),
      ),
      body: GameboxPageBody(
        children: [
          const GameboxAsyncPanel(
            icon: Icons.qr_code_scanner,
            title: '扫描房主的二维码',
            message: '相机只在你点击扫码后启动；也可以粘贴加入信息。',
          ),
          if (_scanning)
            ClipRRect(
              borderRadius: BorderRadius.circular(GameboxTokens.shape.card),
              child: SizedBox(
                height: GameboxTokens.components.mediaViewportHeight,
                child: MobileScanner(
                  controller: _scanner,
                  onDetect: (capture) {
                    final value = capture.barcodes.firstOrNull?.rawValue;
                    if (value != null) _submit(value);
                  },
                ),
              ),
            )
          else
            OutlinedButton.icon(
              key: const Key('start-lan-scanner'),
              onPressed: _startScanner,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('扫码加入'),
            ),
          if (_scannerError) const Text('相机暂时不可用，请使用下方手动输入。'),
          Semantics(
            identifier: 'lan-manual-input',
            textField: true,
            child: TextField(
              key: const Key('lan-manual-input'),
              controller: _textController,
              minLines: 3,
              maxLines: 6,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: '手动输入加入信息'),
            ),
          ),
          GameboxPendingButton(
            key: const Key('submit-lan-manual-input'),
            identifier: 'submit-lan-manual-input',
            label: '加入房间',
            pendingLabel: '正在加入房间',
            isPending: state is LanJoining,
            onPressed: state is LanJoining
                ? null
                : () => _submit(_textController.text),
          ),
          if (state case LanRoomFailure(:final code)) ...[
            Semantics(
              identifier: 'lan-join-error-$code',
              child: GameboxAsyncPanel(
                key: const Key('lan-join-error'),
                icon: Icons.cloud_off_outlined,
                title: '暂时无法加入房间',
                message: lanMessage(code),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
