import 'package:flutter/material.dart';

import '../../design_system/components/gamebox_page_body.dart';
import '../../design_system/components/gamebox_pending_button.dart';
import '../../design_system/generated/gamebox_tokens.g.dart';
import 'profile_controller.dart';

final class NicknamePage extends StatefulWidget {
  const NicknamePage({
    super.key,
    required this.controller,
    this.initialNickname,
    this.onSaved,
  });

  final ProfileController controller;
  final String? initialNickname;
  final VoidCallback? onSaved;

  @override
  State<NicknamePage> createState() => _NicknamePageState();
}

final class _NicknamePageState extends State<NicknamePage> {
  late final TextEditingController _nicknameController;
  String? _errorMessage;
  var _submitting = false;

  @override
  void initState() {
    super.initState();
    _nicknameController = TextEditingController(text: widget.initialNickname);
  }

  @override
  void dispose() {
    _nicknameController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _errorMessage = null;
    });
    final failure = await widget.controller.commitNickname(
      _nicknameController.text,
    );
    if (!mounted) return;
    setState(() {
      _submitting = false;
      _errorMessage = switch (failure) {
        ProfileCommitFailure.invalidNickname => '昵称格式不正确，请重试',
        ProfileCommitFailure.unavailable => '无法安全保存昵称，请重试',
        null => null,
      };
    });
    if (failure == null) widget.onSaved?.call();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('nickname-page'),
      appBar: AppBar(
        leading: widget.initialNickname == null
            ? null
            : Semantics(
                identifier: 'nickname-back',
                child: BackButton(onPressed: () => Navigator.of(context).pop()),
              ),
        title: const Text('Gamebox'),
      ),
      body: GameboxPageBody(
        footer: Semantics(
          key: const Key('save-nickname'),
          identifier: 'save-nickname',
          label: 'save-nickname',
          button: true,
          enabled: !_submitting,
          excludeSemantics: true,
          child: GameboxPendingButton(
            identifier: 'save-nickname',
            label: '保存并继续',
            pendingLabel: '正在保存昵称',
            isPending: _submitting,
            onPressed: _submitting ? null : _save,
          ),
        ),
        children: [
          Text(
            widget.initialNickname == null ? '先设置一个昵称' : '编辑昵称',
            style: Theme.of(context).textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
          Text(
            '这个昵称保存在本机，无需注册也能使用。',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          Semantics(
            key: const Key('local-nickname'),
            identifier: 'local-nickname',
            label: 'local-nickname',
            textField: true,
            child: TextField(
              controller: _nicknameController,
              enabled: !_submitting,
              autofocus: true,
              textInputAction: TextInputAction.done,
              onSubmitted: _submitting ? null : (_) => _save(),
              decoration: InputDecoration(
                labelText: '昵称',
                hintText: '2–16 个字符',
                errorText: _errorMessage,
              ),
            ),
          ),
          if (_errorMessage != null)
            Semantics(
              label: 'nickname-error',
              liveRegion: true,
              child: SizedBox(
                height: GameboxTokens.components.minimumTouchTarget,
              ),
            ),
        ],
      ),
    );
  }
}
