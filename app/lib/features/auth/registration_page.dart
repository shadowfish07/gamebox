import 'package:flutter/material.dart';
import 'package:flutter_release_updater/flutter_release_updater.dart';

import '../../core/api/api_error.dart';
import '../../design_system/components/gamebox_async_panel.dart';
import '../../design_system/components/gamebox_page_body.dart';
import '../../design_system/components/gamebox_pending_button.dart';
import '../../design_system/generated/gamebox_tokens.g.dart';
import '../update/update_action.dart';
import 'session_controller.dart';

final class RegistrationPage extends StatefulWidget {
  const RegistrationPage({
    super.key,
    required this.controller,
    required this.nickname,
    required this.onEditNickname,
    this.updateController,
    this.embedded = false,
  });

  final SessionController controller;
  final String nickname;
  final VoidCallback onEditNickname;
  final UpdateController? updateController;
  final bool embedded;

  @override
  State<RegistrationPage> createState() => _RegistrationPageState();
}

final class _RegistrationPageState extends State<RegistrationPage> {
  final _inviteController = TextEditingController();
  String? _inviteError;
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
    super.dispose();
  }

  Future<void> _submit() async {
    if (!widget.controller.canRegister) {
      return;
    }
    final invite = _inviteController.text.trim();
    final inviteError = invite.isEmpty ? '请输入邀请码' : null;
    setState(() {
      _inviteError = inviteError;
      _errorMessage = null;
    });
    if (inviteError != null) {
      return;
    }
    final error = await widget.controller.register(invite, widget.nickname);
    if (mounted && error != null) {
      setState(() => _errorMessage = _messageFor(error));
    }
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
    final footer = Semantics(
      key: const Key('register'),
      identifier: 'register',
      label: 'register',
      button: true,
      enabled: canSubmit,
      onTap: canSubmit ? _submit : null,
      excludeSemantics: true,
      child: GameboxPendingButton(
        identifier: 'register',
        label: '注册并登录',
        pendingLabel: '正在注册',
        isPending: submitting,
        onPressed: canSubmit ? _submit : null,
      ),
    );
    return _page(
      footer: footer,
      children: [
        Column(
          children: [
            Icon(
              Icons.sports_esports_outlined,
              size: GameboxTokens.spacing.xlarge,
              color: Theme.of(context).colorScheme.primary,
            ),
            SizedBox(height: GameboxTokens.spacing.layout),
            Text(
              '使用邀请码加入',
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            SizedBox(height: GameboxTokens.spacing.layout),
            Text(
              '昵称使用本机资料；注册后也可随时切换局域网模式。',
              style: Theme.of(context).textTheme.bodyLarge,
              textAlign: TextAlign.center,
            ),
          ],
        ),
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
            decoration: InputDecoration(
              labelText: '邀请码',
              errorText: _inviteError,
            ),
          ),
        ),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('当前昵称', style: Theme.of(context).textTheme.labelMedium),
                  SizedBox(height: GameboxTokens.spacing.compact),
                  Text(
                    widget.nickname,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              ),
            ),
            TextButton(
              key: const Key('edit-nickname'),
              onPressed: submitting ? null : widget.onEditNickname,
              child: const Text('编辑昵称'),
            ),
          ],
        ),
        SizedBox(
          height: GameboxTokens.components.minimumTouchTarget,
          child: _errorMessage == null
              ? null
              : Semantics(
                  label: 'registration-error',
                  liveRegion: true,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _errorMessage!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildRetry(BuildContext context) {
    return _page(
      children: [
        const GameboxAsyncPanel(
          icon: Icons.cloud_off_outlined,
          title: '暂时无法恢复登录',
          message: '检查网络后再试一次。',
        ),
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
    );
  }

  Widget _buildCredentialCleanup(BuildContext context) {
    final pending = widget.controller.credentialCleanupPending;
    return _page(
      children: [
        if (pending)
          Semantics(
            key: const Key('credential-cleanup-pending'),
            label: 'credential-cleanup-pending',
            child: const GameboxAsyncPanel(
              icon: Icons.security_outlined,
              title: '正在安全清理登录信息',
              message: '请稍候。',
              isLoading: true,
            ),
          )
        else ...[
          const GameboxAsyncPanel(
            icon: Icons.security_outlined,
            title: '无法安全清理登录信息',
            message: '请重试安全清理。',
          ),
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
      ],
    );
  }

  Widget _page({required List<Widget> children, Widget? footer}) {
    if (widget.embedded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ...children,
          if (footer != null) ...[
            SizedBox(height: GameboxTokens.spacing.page),
            footer,
          ],
        ],
      );
    }
    return Scaffold(
      appBar: _appBar(),
      body: GameboxPageBody(footer: footer, children: children),
    );
  }

  AppBar _appBar() => AppBar(
    title: const Text('Gamebox'),
    actions: [
      if (widget.updateController case final controller?)
        UpdateActionButton(controller: controller),
    ],
  );
}
