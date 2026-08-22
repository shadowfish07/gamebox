import 'package:flutter/services.dart';

enum InstallLaunchResult { started, permissionRequired }

abstract interface class ApkInstaller {
  Future<InstallLaunchResult> launchInstaller(String apkPath);
}

final class ApkInstallException implements Exception {
  const ApkInstallException(this.code);

  final String code;

  @override
  String toString() => 'ApkInstallException($code)';
}

final class MethodChannelApkInstaller implements ApkInstaller {
  MethodChannelApkInstaller({MethodChannel? channel})
    : _channel = channel ?? _defaultChannel;

  static const _defaultChannel = MethodChannel(
    'me.zqydev.flutter_release_updater/app_updater',
  );

  final MethodChannel _channel;

  @override
  Future<InstallLaunchResult> launchInstaller(String apkPath) async {
    try {
      final value = await _channel.invokeMethod<String>('installApk', {
        'path': apkPath,
      });
      return switch (value) {
        'started' => InstallLaunchResult.started,
        'permission_required' => InstallLaunchResult.permissionRequired,
        _ => throw const ApkInstallException('invalid_response'),
      };
    } on PlatformException catch (error) {
      throw ApkInstallException(error.code);
    } on MissingPluginException {
      throw const ApkInstallException('missing_plugin');
    }
  }
}
