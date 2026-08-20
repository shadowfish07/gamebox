import 'package:flutter/material.dart';

import '../../core/api/api_error.dart';
import 'session_controller.dart';

final class RegistrationPage extends StatefulWidget {
  const RegistrationPage({super.key, required this.controller});

  final SessionController controller;

  @override
  State<RegistrationPage> createState() => _RegistrationPageState();
}

final class _RegistrationPageState extends State<RegistrationPage> {
  final _inviteController = TextEditingController();
  final _nicknameController = TextEditingController();
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_controllerChanged);
  }

  @override
  void didUpdateWidget(RegistrationPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_controllerChanged);
      widget.controller.addListener(_controllerChanged);
    }
  }

  void _controllerChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_controllerChanged);
    _inviteController.dispose();
    _nicknameController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!widget.controller.canRegister) {
      return;
    }
    final invite = _inviteController.text.trim();
    final nickname = _nicknameController.text.trim();
    final localError = _validate(invite, nickname);
    setState(() => _errorMessage = localError);
    if (localError != null) {
      return;
    }
    final error = await widget.controller.register(invite, nickname);
    if (mounted && error != null) {
      setState(() => _errorMessage = _messageFor(error));
    }
  }

  String? _validate(String invite, String nickname) {
    if (invite.isEmpty) {
      return '请输入邀请码';
    }
    final runeCount = nickname.runes.length;
    if (runeCount < 2) {
      return '昵称至少需要 2 个字符';
    }
    if (runeCount > 16) {
      return '昵称不能超过 16 个字符';
    }
    return null;
  }

  String _messageFor(ApiError error) {
    return switch (error.code) {
      'invite_invalid' => '邀请码无效或已使用',
      'nickname_taken' => '昵称已被使用',
      'invalid_request' => '邀请码或昵称格式不正确',
      'network_error' => '网络连接失败，请稍后重试',
      'timeout' => '请求超时，请稍后重试',
      'storage_error' => '无法安全保存登录信息，请申请新的邀请码',
      _ => '注册失败，请稍后重试',
    };
  }

  @override
  Widget build(BuildContext context) {
    if (widget.controller.credentialCleanupPending ||
        widget.controller.canRetryCredentialCleanup) {
      return _buildCredentialCleanup(context);
    }
    if (widget.controller.canRetryRestore) {
      return _buildRetry(context);
    }
    final submitting = widget.controller.status == SessionStatus.submitting;
    final canSubmit = widget.controller.canRegister;
    return Scaffold(
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
                  '使用邀请码加入',
                  style: Theme.of(context).textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                const Text('邀请码'),
                const SizedBox(height: 8),
                Semantics(
                  key: const Key('invite-code'),
                  identifier: 'invite-code',
                  label: 'invite-code',
                  textField: true,
                  child: TextField(
                    controller: _inviteController,
                    enabled: canSubmit,
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Text('昵称'),
                const SizedBox(height: 8),
                Semantics(
                  key: const Key('nickname'),
                  identifier: 'nickname',
                  label: 'nickname',
                  textField: true,
                  child: TextField(
                    controller: _nicknameController,
                    enabled: canSubmit,
                    autocorrect: false,
                    textInputAction: TextInputAction.done,
                    onSubmitted: canSubmit ? (_) => _submit() : null,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                if (_errorMessage != null) ...[
                  const SizedBox(height: 16),
                  Semantics(
                    label: 'registration-error',
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
                  key: const Key('register'),
                  identifier: 'register',
                  label: 'register',
                  button: true,
                  enabled: canSubmit,
                  onTap: canSubmit ? _submit : null,
                  excludeSemantics: true,
                  child: FilledButton(
                    onPressed: canSubmit ? _submit : null,
                    child: submitting
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('注册并登录'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRetry(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Gamebox')),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '暂时无法恢复登录，请检查网络后重试',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 24),
                Semantics(
                  key: const Key('retry-session'),
                  label: 'retry-session',
                  button: true,
                  onTap: widget.controller.retryRestore,
                  excludeSemantics: true,
                  child: FilledButton(
                    onPressed: widget.controller.retryRestore,
                    child: const Text('重试登录'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCredentialCleanup(BuildContext context) {
    final pending = widget.controller.credentialCleanupPending;
    return Scaffold(
      appBar: AppBar(title: const Text('Gamebox')),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  pending ? '正在安全清理登录信息' : '无法安全清理登录信息，请重试',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 24),
                if (pending)
                  Semantics(
                    key: const Key('credential-cleanup-pending'),
                    label: 'credential-cleanup-pending',
                    child: const CircularProgressIndicator(),
                  )
                else
                  Semantics(
                    key: const Key('retry-credential-cleanup'),
                    label: 'retry-credential-cleanup',
                    button: true,
                    onTap: widget.controller.retryCredentialCleanup,
                    excludeSemantics: true,
                    child: FilledButton(
                      onPressed: widget.controller.retryCredentialCleanup,
                      child: const Text('重试安全清理'),
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
