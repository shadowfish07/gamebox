import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

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

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _startScanner() async {
    setState(() => _scanning = true);
    try {
      await _scanner.start();
    } on MobileScannerException {
      if (mounted) setState(() => _scanning = false);
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
      appBar: AppBar(title: const Text('加入局域网房间')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            if (_scanning)
              SizedBox(
                height: 260,
                child: MobileScanner(
                  controller: _scanner,
                  onDetect: (capture) {
                    final value = capture.barcodes.firstOrNull?.rawValue;
                    if (value != null) _submit(value);
                  },
                ),
              )
            else
              FilledButton.icon(
                key: const Key('start-lan-scanner'),
                onPressed: _startScanner,
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('扫码加入'),
              ),
            const SizedBox(height: 24),
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
                decoration: const InputDecoration(
                  labelText: '手动输入二维码内容',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Semantics(
              identifier: 'submit-lan-manual-input',
              button: true,
              child: FilledButton(
                key: const Key('submit-lan-manual-input'),
                onPressed: state is LanJoining
                    ? null
                    : () => _submit(_textController.text),
                child: state is LanJoining
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('加入'),
              ),
            ),
            if (state case LanRoomFailure(:final code)) ...[
              const SizedBox(height: 16),
              Text(lanMessage(code), key: const Key('lan-join-error')),
            ],
          ],
        ),
      ),
    );
  }
}
