import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/core/platform/apk_installer.dart';
import 'package:gamebox/features/update/app_update.dart';
import 'package:gamebox/features/update/github_release_service.dart';
import 'package:gamebox/features/update/update_controller.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'checks once, downloads a verified APK, and opens the installer',
    () async {
      SharedPreferences.setMockInitialValues({});
      final directory = await Directory.systemTemp.createTemp(
        'gamebox-update-test.',
      );
      final bytes = List<int>.generate(128, (index) => index);
      final installer = _FakeInstaller(InstallLaunchResult.started);
      final releaseService = _FakeReleaseService(
        UpdateCheckResult(update: _update(sha256.convert(bytes).toString())),
      );
      final controller = UpdateController(
        installedVersion: '1.0.0',
        releaseService: releaseService,
        installer: installer,
        downloadClient: MockClient((request) async {
          expect(
            request.url,
            Uri.parse('https://downloads.example/gamebox.apk'),
          );
          return http.Response.bytes(bytes, 200);
        }),
        preferences: await SharedPreferences.getInstance(),
        updateDirectory: directory,
        now: () => DateTime.utc(2026, 8, 21, 12),
      );
      addTearDown(() async {
        controller.dispose();
        await directory.delete(recursive: true);
      });

      await controller.start();
      await controller.downloadAndInstall();

      expect(releaseService.calls, 1);
      expect(controller.status, UpdateStatus.installerOpened);
      expect(controller.downloadProgress, 1);
      expect(installer.paths, hasLength(1));
      final installed = File(installer.paths.single);
      expect(installed.path, endsWith('gamebox-v1.1.0-android.apk'));
      expect(await installed.readAsBytes(), bytes);
    },
  );

  test('does not recheck within the six-hour cache interval', () async {
    final now = DateTime.utc(2026, 8, 21, 12);
    SharedPreferences.setMockInitialValues({
      'update.lastCheckAt': now
          .subtract(const Duration(hours: 2))
          .toIso8601String(),
    });
    final directory = await Directory.systemTemp.createTemp(
      'gamebox-update-cache-test.',
    );
    final service = _FakeReleaseService(const UpdateCheckResult());
    final controller = UpdateController(
      installedVersion: '1.0.0',
      releaseService: service,
      installer: _FakeInstaller(InstallLaunchResult.started),
      downloadClient: MockClient((_) async => http.Response('', 500)),
      preferences: await SharedPreferences.getInstance(),
      updateDirectory: directory,
      now: () => now,
    );
    addTearDown(() async {
      controller.dispose();
      await directory.delete(recursive: true);
    });

    await controller.start();

    expect(service.calls, 0);
  });

  test(
    'drops a cached update that is not newer than the installed app',
    () async {
      final now = DateTime.utc(2026, 8, 21, 12);
      final checksum = List.filled(64, 'a').join();
      SharedPreferences.setMockInitialValues({
        'update.lastCheckAt': now.toIso8601String(),
        'update.available':
            '{"version":"1.1.0","title":"old","releaseNotes":"",'
            '"releaseUrl":"https://example.com/release",'
            '"apkUrl":"https://example.com/app.apk",'
            '"apkName":"gamebox.apk","sha256":"$checksum"}',
      });
      final directory = await Directory.systemTemp.createTemp(
        'gamebox-update-stale-cache-test.',
      );
      final preferences = await SharedPreferences.getInstance();
      final controller = UpdateController(
        installedVersion: '1.1.0',
        releaseService: _FakeReleaseService(const UpdateCheckResult()),
        installer: _FakeInstaller(InstallLaunchResult.started),
        downloadClient: MockClient((_) async => http.Response('', 500)),
        preferences: preferences,
        updateDirectory: directory,
        now: () => now,
      );
      addTearDown(() async {
        controller.dispose();
        await directory.delete(recursive: true);
      });

      await controller.start();

      expect(controller.availableUpdate, isNull);
      expect(controller.status, UpdateStatus.idle);
      expect(preferences.getString('update.available'), isNull);
    },
  );

  test('deletes a corrupt download and never opens the installer', () async {
    SharedPreferences.setMockInitialValues({});
    final directory = await Directory.systemTemp.createTemp(
      'gamebox-update-corrupt-test.',
    );
    final installer = _FakeInstaller(InstallLaunchResult.started);
    final controller = UpdateController(
      installedVersion: '1.0.0',
      releaseService: _FakeReleaseService(
        UpdateCheckResult(update: _update(List.filled(64, '0').join())),
      ),
      installer: installer,
      downloadClient: MockClient(
        (_) async => http.Response.bytes([1, 2, 3], 200),
      ),
      preferences: await SharedPreferences.getInstance(),
      updateDirectory: directory,
    );
    addTearDown(() async {
      controller.dispose();
      await directory.delete(recursive: true);
    });

    await controller.start();
    await controller.downloadAndInstall();

    expect(controller.status, UpdateStatus.failed);
    expect(controller.errorMessage, contains('校验失败'));
    expect(installer.paths, isEmpty);
    expect(directory.listSync(), isEmpty);
  });

  test(
    'preserves the verified APK while unknown-source permission is granted',
    () async {
      SharedPreferences.setMockInitialValues({});
      final directory = await Directory.systemTemp.createTemp(
        'gamebox-update-permission-test.',
      );
      final bytes = [1, 2, 3, 4];
      final installer = _FakeInstaller(InstallLaunchResult.permissionRequired);
      final controller = UpdateController(
        installedVersion: '1.0.0',
        releaseService: _FakeReleaseService(
          UpdateCheckResult(update: _update(sha256.convert(bytes).toString())),
        ),
        installer: installer,
        downloadClient: MockClient(
          (_) async => http.Response.bytes(bytes, 200),
        ),
        preferences: await SharedPreferences.getInstance(),
        updateDirectory: directory,
      );
      addTearDown(() async {
        controller.dispose();
        await directory.delete(recursive: true);
      });

      await controller.start();
      await controller.downloadAndInstall();
      await controller.downloadAndInstall();

      expect(controller.status, UpdateStatus.permissionRequired);
      expect(installer.paths, hasLength(2));
      expect(installer.paths[0], installer.paths[1]);
    },
  );
}

AppUpdate _update(String checksum) => AppUpdate(
  version: '1.1.0',
  title: 'Gamebox 1.1.0',
  releaseNotes: 'Release notes',
  releaseUrl: 'https://github.com/shadowfish07/gamebox/releases/tag/v1.1.0',
  apkUrl: 'https://downloads.example/gamebox.apk',
  apkName: 'gamebox-v1.1.0-android.apk',
  sha256: checksum,
);

final class _FakeReleaseService implements ReleaseService {
  _FakeReleaseService(this.result);

  final UpdateCheckResult result;
  int calls = 0;

  @override
  Future<UpdateCheckResult> checkForUpdate({
    required String currentVersion,
  }) async {
    calls += 1;
    return result;
  }
}

final class _FakeInstaller implements ApkInstaller {
  _FakeInstaller(this.result);

  final InstallLaunchResult result;
  final paths = <String>[];

  @override
  Future<InstallLaunchResult> launchInstaller(String apkPath) async {
    paths.add(apkPath);
    return result;
  }
}
