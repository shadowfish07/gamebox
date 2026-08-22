import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_release_updater/flutter_release_updater.dart';
import 'package:flutter_test/flutter_test.dart';
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
        'flutter-updater-test.',
      );
      final bytes = List<int>.generate(128, (index) => index);
      final installer = _FakeInstaller(InstallLaunchResult.started);
      final service = _FakeReleaseService(
        UpdateCheckResult(update: _update(sha256.convert(bytes).toString())),
      );
      final controller = await _controller(
        service: service,
        installer: installer,
        directory: directory,
        client: MockClient((request) async {
          expect(request.url, Uri.parse('https://downloads.example/app.apk'));
          expect(request.headers['User-Agent'], 'Example-update-download');
          return http.Response.bytes(bytes, 200);
        }),
        now: () => DateTime.utc(2026, 8, 21, 12),
      );
      addTearDown(() async {
        controller.dispose();
        await directory.delete(recursive: true);
      });

      await controller.start();
      await controller.downloadAndInstall();

      expect(service.calls, 1);
      expect(controller.status, UpdateStatus.installerOpened);
      expect(controller.downloadProgress, 1);
      expect(installer.paths, hasLength(1));
      final installed = File(installer.paths.single);
      expect(installed.path, endsWith('example-v1.1.0.apk'));
      expect(await installed.readAsBytes(), bytes);
    },
  );

  test('does not recheck within the configured cache interval', () async {
    final now = DateTime.utc(2026, 8, 21, 12);
    SharedPreferences.setMockInitialValues({
      'example.update.lastCheckAt': now
          .subtract(const Duration(hours: 2))
          .toIso8601String(),
    });
    final directory = await Directory.systemTemp.createTemp(
      'flutter-updater-cache-test.',
    );
    final service = _FakeReleaseService(const UpdateCheckResult());
    final controller = await _controller(
      service: service,
      installer: _FakeInstaller(InstallLaunchResult.started),
      directory: directory,
      client: MockClient((_) async => http.Response('', 500)),
      now: () => now,
    );
    addTearDown(() async {
      controller.dispose();
      await directory.delete(recursive: true);
    });

    await controller.start();

    expect(service.calls, 0);
    expect(controller.status, UpdateStatus.idle);
  });

  test('drops a cached update that is not newer', () async {
    final now = DateTime.utc(2026, 8, 21, 12);
    final checksum = List.filled(64, 'a').join();
    SharedPreferences.setMockInitialValues({
      'example.update.lastCheckAt': now.toIso8601String(),
      'example.update.available':
          '{"version":"1.1.0","title":"old","releaseNotes":"",'
          '"releaseUrl":"https://example.com/release",'
          '"apkUrl":"https://example.com/app.apk",'
          '"apkName":"example.apk","sha256":"$checksum"}',
    });
    final directory = await Directory.systemTemp.createTemp(
      'flutter-updater-stale-test.',
    );
    final preferences = await SharedPreferences.getInstance();
    final controller = await _controller(
      service: _FakeReleaseService(const UpdateCheckResult()),
      installer: _FakeInstaller(InstallLaunchResult.started),
      directory: directory,
      client: MockClient((_) async => http.Response('', 500)),
      preferences: preferences,
      installedVersion: '1.1.0',
      now: () => now,
    );
    addTearDown(() async {
      controller.dispose();
      await directory.delete(recursive: true);
    });

    await controller.start();
    await Future<void>.delayed(Duration.zero);

    expect(controller.availableUpdate, isNull);
    expect(preferences.getString('example.update.available'), isNull);
  });

  test('deletes a corrupt download and never opens the installer', () async {
    SharedPreferences.setMockInitialValues({});
    final directory = await Directory.systemTemp.createTemp(
      'flutter-updater-corrupt-test.',
    );
    final installer = _FakeInstaller(InstallLaunchResult.started);
    final controller = await _controller(
      service: _FakeReleaseService(
        UpdateCheckResult(update: _update(List.filled(64, '0').join())),
      ),
      installer: installer,
      directory: directory,
      client: MockClient((_) async => http.Response.bytes([1, 2, 3], 200)),
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

  test('preserves the verified APK while permission is granted', () async {
    SharedPreferences.setMockInitialValues({});
    final directory = await Directory.systemTemp.createTemp(
      'flutter-updater-permission-test.',
    );
    final bytes = [1, 2, 3, 4];
    final installer = _FakeInstaller(InstallLaunchResult.permissionRequired);
    final controller = await _controller(
      service: _FakeReleaseService(
        UpdateCheckResult(update: _update(sha256.convert(bytes).toString())),
      ),
      installer: installer,
      directory: directory,
      client: MockClient((_) async => http.Response.bytes(bytes, 200)),
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
  });

  test('does not impose an APK content-length limit', () async {
    SharedPreferences.setMockInitialValues({});
    final directory = await Directory.systemTemp.createTemp(
      'flutter-updater-unlimited-test.',
    );
    final bytes = [1, 2, 3, 4];
    final installer = _FakeInstaller(InstallLaunchResult.started);
    final controller = await _controller(
      service: _FakeReleaseService(
        UpdateCheckResult(update: _update(sha256.convert(bytes).toString())),
      ),
      installer: installer,
      directory: directory,
      client: _StreamClient(
        (request) async => http.StreamedResponse(
          http.ByteStream.fromBytes(bytes),
          200,
          contentLength: 1024 * 1024 * 1024,
        ),
      ),
    );
    addTearDown(() async {
      controller.dispose();
      await directory.delete(recursive: true);
    });

    await controller.start();
    await controller.downloadAndInstall();

    expect(controller.status, UpdateStatus.installerOpened);
    expect(controller.downloadProgress, 1);
    expect(installer.paths, hasLength(1));
    expect(await File(installer.paths.single).readAsBytes(), bytes);
  });
}

Future<UpdateController> _controller({
  required ReleaseService service,
  required ApkInstaller installer,
  required Directory directory,
  required http.Client client,
  SharedPreferences? preferences,
  String installedVersion = '1.0.0',
  DateTime Function()? now,
}) async => UpdateController(
  installedVersion: installedVersion,
  releaseService: service,
  installer: installer,
  downloadClient: client,
  preferences: preferences ?? await SharedPreferences.getInstance(),
  updateDirectory: directory,
  cacheKeyPrefix: 'example.update',
  downloadUserAgent: 'Example-update-download',
  now: now,
);

AppUpdate _update(String checksum) => AppUpdate(
  version: '1.1.0',
  title: 'Example 1.1.0',
  releaseNotes: 'Release notes',
  releaseUrl: 'https://github.com/owner/repo/releases/tag/v1.1.0',
  apkUrl: 'https://downloads.example/app.apk',
  apkName: 'example-v1.1.0.apk',
  sha256: checksum,
);

final class _FakeReleaseService extends ReleaseService {
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

final class _StreamClient extends http.BaseClient {
  _StreamClient(this._send);

  final Future<http.StreamedResponse> Function(http.BaseRequest request) _send;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _send(request);
}
