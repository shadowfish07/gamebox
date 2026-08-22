import 'package:flutter/services.dart';
import 'package:flutter_release_updater/flutter_release_updater.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(
    'me.zqydev.flutter_release_updater/app_updater',
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('passes the private APK path to the Android installer bridge', () async {
    MethodCall? recorded;
    messenger.setMockMethodCallHandler(channel, (call) async {
      recorded = call;
      return 'started';
    });

    final result = await MethodChannelApkInstaller().launchInstaller(
      '/private/app/files/updates/example.apk',
    );

    expect(result, InstallLaunchResult.started);
    expect(recorded?.method, 'installApk');
    expect(recorded?.arguments, {
      'path': '/private/app/files/updates/example.apk',
    });
  });

  test('reports when Android requires unknown-source access', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => 'permission_required',
    );

    expect(
      await MethodChannelApkInstaller().launchInstaller('/private/update.apk'),
      InstallLaunchResult.permissionRequired,
    );
  });

  test('maps platform failures without exposing platform messages', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(
        code: 'invalid_apk',
        message: '/private/sensitive/path.apk',
      );
    });

    await expectLater(
      MethodChannelApkInstaller().launchInstaller('/private/update.apk'),
      throwsA(
        isA<ApkInstallException>().having(
          (error) => error.code,
          'code',
          'invalid_apk',
        ),
      ),
    );
  });
}
