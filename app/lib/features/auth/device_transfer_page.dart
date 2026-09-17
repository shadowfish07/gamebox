import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design_system/components/gamebox_page_body.dart';
import '../../design_system/components/gamebox_pending_button.dart';
import '../../design_system/generated/gamebox_tokens.g.dart';
import 'device_transfer.dart';

class DeviceTransferPage extends StatefulWidget {
  const DeviceTransferPage({
    super.key,
    required this.transfer,
    this.sending = false,
  });
  final DeviceTransfer transfer;
  final bool sending;
  @override
  State<DeviceTransferPage> createState() => _DeviceTransferPageState();
}

class _DeviceTransferPageState extends State<DeviceTransferPage> {
  final _input = TextEditingController();
  Timer? _timer;
  bool _allowPop = false;
  @override
  void initState() {
    super.initState();
    if (widget.sending) {
      if (!widget.transfer.outgoing) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(widget.transfer.generate());
        });
      }
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _input.dispose();
    super.dispose();
  }

  Future<void> _leave() async {
    if (widget.transfer.busy) return;
    if (widget.sending && !await widget.transfer.cancelOutgoing()) return;
    if (!mounted) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.transfer,
    builder: (context, _) {
      final t = widget.transfer;
      final expired =
          t.expiresAt == null || !t.expiresAt!.isAfter(DateTime.now());
      final sending = widget.sending;
      return PopScope(
        canPop: _allowPop || (!sending && !t.busy && !t.incoming),
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop && sending) unawaited(_leave());
        },
        child: Scaffold(
          appBar: AppBar(
            title: Text(sending ? '换设备' : '迁入账号'),
            leading: Navigator.of(context).canPop()
                ? BackButton(
                    onPressed: sending
                        ? _leave
                        : (t.busy || t.incoming
                              ? null
                              : () => Navigator.of(context).pop()),
                  )
                : null,
          ),
          body: GameboxPageBody(
            children: [
              if (sending) ...[
                const Text('在新设备选择「已有账号」，输入迁移码。'),
                if (t.busy)
                  const Center(child: CircularProgressIndicator())
                else if (t.code != null && !expired) ...[
                  Text(
                    '${t.code!.substring(0, 4)} · ${t.code!.substring(4)}',
                    key: const Key('transfer-code'),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineLarge,
                  ),
                  Text(
                    '10 分钟内有效，仅可使用一次',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  FilledButton.icon(
                    key: const Key('copy-transfer-code'),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: t.code!));
                      if (context.mounted) {
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(const SnackBar(content: Text('迁移码已复制')));
                      }
                    },
                    icon: const Icon(Icons.copy_outlined),
                    label: const Text('复制迁移码'),
                  ),
                ] else
                  GameboxPendingButton(
                    identifier: 'generate-transfer',
                    label: t.code == null ? '重试' : '重新生成',
                    pendingLabel: '正在生成',
                    isPending: t.busy,
                    onPressed: t.generate,
                  ),
                const Text('迁移成功后，本设备将退出账号。请勿将迁移码交给他人。'),
              ] else ...[
                TextField(
                  key: const Key('transfer-input'),
                  controller: _input,
                  enabled: !t.busy && !t.incoming,
                  autocorrect: false,
                  enableSuggestions: false,
                  textCapitalization: TextCapitalization.characters,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => t.receive(_input.text),
                  decoration: const InputDecoration(labelText: '迁移码'),
                ),
                const Text('成功后，旧设备将退出账号。'),
                GameboxPendingButton(
                  identifier: 'redeem-transfer',
                  label: t.incoming ? '重试迁入' : '迁入并登录',
                  pendingLabel: '正在迁入',
                  isPending: t.busy,
                  onPressed: t.busy ? null : () => t.receive(_input.text),
                ),
                TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('无法使用旧设备？'),
                      content: const Text(
                        '联系管理员核实账号并获取恢复码，在此输入即可。恢复码只能找回已保存在服务器的数据。',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('知道了'),
                        ),
                      ],
                    ),
                  ),
                  child: const Text('无法使用旧设备？'),
                ),
              ],
              if (t.error != null)
                Padding(
                  padding: EdgeInsets.symmetric(
                    vertical: GameboxTokens.spacing.compact,
                  ),
                  child: Text(
                    t.error!,
                    key: const Key('transfer-error'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}
