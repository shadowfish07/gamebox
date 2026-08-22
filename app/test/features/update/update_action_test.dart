import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/core/platform/apk_installer.dart';
import 'package:gamebox/design_system/gamebox_theme.dart';
import 'package:gamebox/features/update/app_update.dart';
import 'package:gamebox/features/update/github_release_service.dart';
import 'package:gamebox/features/update/update_action.dart';
import 'package:gamebox/features/update/update_controller.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'opens immediately with an explicit checking state',
    (tester) async {
      final check = Completer<UpdateCheckResult>();
      final fixture = await _UpdateFixture.create(
        tester,
        release: (_) => check.future,
      );
      addTearDown(() => fixture.dispose(tester));
      addTearDown(() {
        if (!check.isCompleted) check.complete(const UpdateCheckResult());
      });

      late BuildContext hostContext;
      await tester.pumpWidget(
        MaterialApp(
          theme: GameboxTheme.light(),
          home: Builder(
            builder: (context) {
              hostContext = context;
              return const Scaffold();
            },
          ),
        ),
      );
      var dismissed = false;
      final dialogFuture = showUpdateDialog(
        hostContext,
        fixture.controller,
      ).whenComplete(() => dismissed = true);
      await tester.pump();
      try {
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.text('正在检查更新...'), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsWidgets);
        expect(dismissed, isFalse);

        await tester.tap(find.widgetWithText(TextButton, '关闭'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await dialogFuture;

        expect(dismissed, isTrue);
        expect(find.byType(AlertDialog), findsNothing);
        expect(fixture.controller.status, UpdateStatus.checking);
        expect(check.isCompleted, isFalse);
        expect(tester.takeException(), isNull);
      } finally {
        if (!dismissed && Navigator.of(hostContext).canPop()) {
          Navigator.of(hostContext).pop();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
        }
        await dialogFuture.timeout(const Duration(seconds: 1));
        if (!check.isCompleted) check.complete(const UpdateCheckResult());
        await _pumpUntil(
          tester,
          () => fixture.controller.status == UpdateStatus.upToDate,
        );
      }
    },
    timeout: const Timeout(Duration(seconds: 10)),
  );

  testWidgets('shows the up-to-date state after a real check', (tester) async {
    final fixture = await _UpdateFixture.create(
      tester,
      release: (_) async => const UpdateCheckResult(),
    );
    addTearDown(() => fixture.dispose(tester));
    await fixture.controller.checkNow();

    await _openDialog(tester, fixture.controller);

    expect(find.text('当前已是最新版本'), findsOneWidget);
    expect(find.byKey(const Key('update-state-region')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final size in const [Size(360, 800), Size(412, 915)]) {
    testWidgets('keeps one install action and scrolls long notes at $size', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      final bytes = [1, 2, 3, 4];
      final fixture = await _UpdateFixture.create(
        tester,
        release: (_) async => UpdateCheckResult(
          update: _update(
            bytes,
            releaseNotes: List.filled(30, '本版修复对局恢复并改善手机窄屏下的长文案展示。').join('\n'),
          ),
        ),
      );
      addTearDown(() => fixture.dispose(tester));
      await fixture.controller.checkNow();

      await _openDialog(tester, fixture.controller, dark: true);

      final dialog = find.byType(AlertDialog);
      final filledButtons = find.descendant(
        of: dialog,
        matching: find.byWidgetPredicate((widget) => widget is FilledButton),
      );
      expect(find.text('更新已准备好下载'), findsOneWidget);
      expect(filledButtons, findsOneWidget);
      expect(find.byKey(const Key('install-update')), findsOneWidget);
      expect(find.text('下载并安装'), findsOneWidget);
      final scrollable = find.descendant(
        of: dialog,
        matching: find.byType(Scrollable),
      );
      expect(
        tester.state<ScrollableState>(scrollable).position.maxScrollExtent,
        greaterThan(0),
      );
      expect(Theme.of(tester.element(dialog)).brightness, Brightness.dark);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('shows textual progress while a download is pending', (
    tester,
  ) async {
    final bytes = [1, 2, 3, 4];
    final download = Completer<http.Response>();
    final fixture = await _UpdateFixture.create(
      tester,
      release: (_) async => UpdateCheckResult(update: _update(bytes)),
      downloadClient: MockClient((_) => download.future),
      installer: _FakeInstaller(InstallLaunchResult.started),
    );
    addTearDown(() => fixture.dispose(tester));
    addTearDown(() {
      if (!download.isCompleted) {
        download.complete(http.Response.bytes(bytes, 200));
      }
    });
    await fixture.controller.checkNow();
    await _openDialog(tester, fixture.controller);

    final installButton = tester.widget<FilledButton>(
      find.byKey(const Key('install-update')),
    );
    expect(installButton.onPressed, isNotNull);
    installButton.onPressed!();
    await tester.pump();

    expect(find.text('正在下载 0%'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('下载并安装'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows feedback after the installer opens', (tester) async {
    final bytes = [1, 2, 3, 4];
    final fixture = await _UpdateFixture.create(
      tester,
      release: (_) async => UpdateCheckResult(update: _update(bytes)),
      downloadClient: MockClient((_) async => http.Response.bytes(bytes, 200)),
      installer: _FakeInstaller(InstallLaunchResult.started),
    );
    addTearDown(() => fixture.dispose(tester));
    await fixture.controller.checkNow();
    await tester.runAsync(fixture.controller.downloadAndInstall);

    await _openDialog(tester, fixture.controller);

    expect(fixture.controller.status, UpdateStatus.installerOpened);
    expect(find.text('系统安装器已打开，请确认安装。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps one continuation action when permission is required', (
    tester,
  ) async {
    final bytes = [1, 2, 3, 4];
    final installer = _FakeInstaller(InstallLaunchResult.permissionRequired);
    final fixture = await _UpdateFixture.create(
      tester,
      release: (_) async => UpdateCheckResult(update: _update(bytes)),
      downloadClient: MockClient((_) async => http.Response.bytes(bytes, 200)),
      installer: installer,
    );
    addTearDown(() => fixture.dispose(tester));
    await fixture.controller.checkNow();
    await _openDialog(tester, fixture.controller);

    final installButton = tester.widget<FilledButton>(
      find.byKey(const Key('install-update')),
    );
    expect(installButton.onPressed, isNotNull);
    await tester.runAsync(fixture.controller.downloadAndInstall);
    await tester.pump();
    expect(fixture.controller.status, UpdateStatus.permissionRequired);
    expect(installer.calls, 1);

    expect(find.text('请在系统设置中允许 Gamebox 安装未知应用，返回后点“继续安装”。'), findsOneWidget);
    expect(find.byKey(const Key('install-update')), findsOneWidget);
    expect(find.text('继续安装'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byWidgetPredicate((widget) => widget is FilledButton),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('继续安装'));
    await _pumpUntil(tester, () => installer.calls == 2);

    expect(installer.calls, 2);
    expect(installer.paths.toSet(), hasLength(1));
    expect(fixture.controller.status, UpdateStatus.permissionRequired);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps failed feedback in the stable state region', (
    tester,
  ) async {
    var shouldFail = true;
    final fixture = await _UpdateFixture.create(
      tester,
      release: (_) async {
        if (shouldFail) {
          throw const UpdateCheckException('暂时无法检查更新');
        }
        return const UpdateCheckResult();
      },
    );
    addTearDown(() => fixture.dispose(tester));
    await fixture.controller.checkNow();

    await _openDialog(tester, fixture.controller);

    final region = find.byKey(const Key('update-state-region'));
    expect(region, findsOneWidget);
    expect(
      find.descendant(of: region, matching: find.text('暂时无法检查更新')),
      findsOneWidget,
    );
    expect(find.text('重新检查'), findsOneWidget);

    expect(fixture.releaseService.calls, 1);
    shouldFail = false;
    await tester.tap(find.text('重新检查'));
    await _pumpUntil(
      tester,
      () => fixture.controller.status == UpdateStatus.upToDate,
    );

    expect(fixture.releaseService.calls, 2);
    expect(find.text('当前已是最新版本'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _openDialog(
  WidgetTester tester,
  UpdateController controller, {
  bool dark = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: GameboxTheme.light(),
      darkTheme: GameboxTheme.dark(),
      themeMode: dark ? ThemeMode.dark : ThemeMode.light,
      home: Scaffold(
        appBar: AppBar(actions: [UpdateActionButton(controller: controller)]),
      ),
    ),
  );
  await tester.tap(find.bySemanticsIdentifier('app-update'));
  await tester.pump();
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt += 1) {
    if (condition()) {
      await tester.pump();
      return;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
    await tester.pump();
  }
  throw TestFailure('Condition did not become true after 100 finite pumps.');
}

AppUpdate _update(List<int> bytes, {String releaseNotes = '本版更新说明'}) =>
    AppUpdate(
      version: '1.1.0',
      title: 'Gamebox 1.1.0',
      releaseNotes: releaseNotes,
      releaseUrl: 'https://example.com/releases/v1.1.0',
      apkUrl: 'https://example.com/gamebox.apk',
      apkName: 'gamebox-v1.1.0.apk',
      sha256: sha256.convert(bytes).toString(),
    );

final class _UpdateFixture {
  _UpdateFixture(this.controller, this.directory, this.releaseService);

  static Future<_UpdateFixture> create(
    WidgetTester tester, {
    required Future<UpdateCheckResult> Function(String version) release,
    http.Client? downloadClient,
    ApkInstaller? installer,
  }) async => (await tester.runAsync(() async {
    SharedPreferences.setMockInitialValues({});
    final directory = await Directory.systemTemp.createTemp(
      'gamebox-update-action-test.',
    );
    final releaseService = _FakeReleaseService(release);
    final controller = UpdateController(
      installedVersion: '1.0.0',
      releaseService: releaseService,
      installer: installer ?? _FakeInstaller(InstallLaunchResult.started),
      downloadClient:
          downloadClient ?? MockClient((_) async => http.Response('', 500)),
      preferences: await SharedPreferences.getInstance(),
      updateDirectory: directory,
      now: () => DateTime.utc(2026, 8, 22, 12),
    );
    return _UpdateFixture(controller, directory, releaseService);
  }))!;

  final UpdateController controller;
  final Directory directory;
  final _FakeReleaseService releaseService;

  Future<void> dispose(WidgetTester tester) async {
    controller.dispose();
    await tester.runAsync(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
  }
}

final class _FakeReleaseService implements ReleaseService {
  _FakeReleaseService(this.release);

  final Future<UpdateCheckResult> Function(String version) release;
  int calls = 0;

  @override
  Future<UpdateCheckResult> checkForUpdate({required String currentVersion}) {
    calls += 1;
    return release(currentVersion);
  }
}

final class _FakeInstaller implements ApkInstaller {
  _FakeInstaller(this.result);

  final InstallLaunchResult result;
  final paths = <String>[];

  int get calls => paths.length;

  @override
  Future<InstallLaunchResult> launchInstaller(String apkPath) async {
    paths.add(apkPath);
    return result;
  }
}
