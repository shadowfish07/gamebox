import 'package:flutter/material.dart';

import 'app_update.dart';
import 'update_controller.dart';

final class UpdateActionButton extends StatelessWidget {
  const UpdateActionButton({super.key, required this.controller});

  final UpdateController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final hasUpdate = controller.availableUpdate != null;
        return Semantics(
          key: const Key('app-update'),
          identifier: 'app-update',
          button: true,
          child: IconButton(
            tooltip: hasUpdate ? '安装更新' : '检查更新',
            onPressed: () => showUpdateDialog(context, controller),
            icon: Badge(
              isLabelVisible: hasUpdate,
              child: controller.isBusy
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.system_update_alt),
            ),
          ),
        );
      },
    );
  }
}

Future<void> showUpdateDialog(
  BuildContext context,
  UpdateController controller,
) async {
  if (controller.status == UpdateStatus.idle) {
    await controller.checkNow();
    if (!context.mounted) return;
  }
  await showDialog<void>(
    context: context,
    builder: (context) => _UpdateDialog(controller: controller),
  );
}

final class _UpdateDialog extends StatelessWidget {
  const _UpdateDialog({required this.controller});

  final UpdateController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final update = controller.availableUpdate;
        return AlertDialog(
          title: const Text('应用更新'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('当前版本 v${controller.installedVersion}'),
                  const SizedBox(height: 16),
                  if (update != null) ...[
                    Text(
                      '新版本 v${update.version}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (update.title.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(update.title),
                    ],
                    if (update.releaseNotes.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(update.releaseNotes),
                    ],
                    const SizedBox(height: 16),
                  ],
                  _UpdateState(controller: controller),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: controller.isBusy ? null : () => controller.checkNow(),
              child: const Text('重新检查'),
            ),
            if (update != null && !controller.isBusy)
              FilledButton.icon(
                key: const Key('install-update'),
                onPressed: controller.downloadAndInstall,
                icon: Icon(
                  controller.status == UpdateStatus.permissionRequired
                      ? Icons.security
                      : Icons.download,
                ),
                label: Text(
                  controller.status == UpdateStatus.permissionRequired
                      ? '继续安装'
                      : '下载并安装',
                ),
              ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }
}

final class _UpdateState extends StatelessWidget {
  const _UpdateState({required this.controller});

  final UpdateController controller;

  @override
  Widget build(BuildContext context) {
    return switch (controller.status) {
      UpdateStatus.idle => const Text('尚未检查更新'),
      UpdateStatus.checking => const _ProgressMessage(message: '正在检查更新...'),
      UpdateStatus.upToDate => const Text('当前已是最新版本'),
      UpdateStatus.available => const Text('更新已准备好下载'),
      UpdateStatus.downloading => _DownloadProgress(
        progress: controller.downloadProgress,
      ),
      UpdateStatus.permissionRequired => const Text(
        '请在系统设置中允许 Gamebox 安装未知应用，返回后点“继续安装”。',
      ),
      UpdateStatus.installerOpened => const Text('系统安装器已打开，请确认安装。'),
      UpdateStatus.failed => Text(
        controller.errorMessage,
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      ),
    };
  }
}

final class _ProgressMessage extends StatelessWidget {
  const _ProgressMessage({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const SizedBox.square(
          dimension: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(message)),
      ],
    );
  }
}

final class _DownloadProgress extends StatelessWidget {
  const _DownloadProgress({required this.progress});

  final double? progress;

  @override
  Widget build(BuildContext context) {
    final value = progress;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value == null ? '正在下载 APK...' : '正在下载 ${(value * 100).round()}%'),
        const SizedBox(height: 8),
        LinearProgressIndicator(value: value),
      ],
    );
  }
}
