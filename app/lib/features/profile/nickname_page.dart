import 'package:flutter/material.dart';

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
      appBar: AppBar(title: const Text('Gamebox')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(24),
              children: [
                Text(
                  widget.initialNickname == null ? '先设置一个昵称' : '编辑昵称',
                  style: Theme.of(context).textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  '这个昵称保存在本机，无需注册也能使用。',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 24),
                const Text('昵称'),
                const SizedBox(height: 8),
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
                    decoration: const InputDecoration(
                      hintText: '2–16 个字符',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                if (_errorMessage != null) ...[
                  const SizedBox(height: 12),
                  Semantics(
                    label: 'nickname-error',
                    liveRegion: true,
                    child: Text(
                      _errorMessage!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                Semantics(
                  key: const Key('save-nickname'),
                  identifier: 'save-nickname',
                  label: 'save-nickname',
                  button: true,
                  enabled: !_submitting,
                  excludeSemantics: true,
                  child: FilledButton(
                    onPressed: _submitting ? null : _save,
                    child: _submitting
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('保存并继续'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
