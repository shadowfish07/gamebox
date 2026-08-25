import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_release_updater/flutter_release_updater.dart';
import 'package:gamebox/features/update/update_action.dart';

void main() {
  testWidgets('routine update check does not open a modal dialog', (
    tester,
  ) async {
    final updater = _FakeReleaseUpdater(nextStatus: UpdateStatus.upToDate);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => IconButton(
              key: const Key('check-update'),
              onPressed: () {
                showUpdateDialog(context, updater);
              },
              icon: const Icon(Icons.system_update),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('check-update')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('当前已是最新版本'), findsOneWidget);
    updater.dispose();
  });

  testWidgets('recoverable update failure uses non-modal feedback', (
    tester,
  ) async {
    final updater = _FakeReleaseUpdater(
      nextStatus: UpdateStatus.failed,
      nextErrorMessage: '网络暂不可用',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => IconButton(
              key: const Key('check-update'),
              onPressed: () {
                showUpdateDialog(context, updater);
              },
              icon: const Icon(Icons.system_update),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('check-update')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('网络暂不可用'), findsOneWidget);
    updater.dispose();
  });

  testWidgets('available update opens the install decision dialog', (
    tester,
  ) async {
    final updater = _FakeReleaseUpdater(
      nextStatus: UpdateStatus.available,
      nextUpdate: _availableUpdate,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => IconButton(
              key: const Key('check-update'),
              onPressed: () {
                showUpdateDialog(context, updater);
              },
              icon: const Icon(Icons.system_update),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('check-update')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('新版本 v2.0.0'), findsOneWidget);
    expect(find.bySemanticsIdentifier('dismiss-update'), findsOneWidget);
    await tester.tap(find.bySemanticsIdentifier('dismiss-update'));
    await tester.pump();
    updater.dispose();
  });
}

final class _FakeReleaseUpdater extends ChangeNotifier
    implements ReleaseUpdater {
  _FakeReleaseUpdater({
    required this.nextStatus,
    this.nextErrorMessage = '',
    this.nextUpdate,
  });

  final UpdateStatus nextStatus;
  final String nextErrorMessage;
  final AppUpdate? nextUpdate;
  UpdateStatus _status = UpdateStatus.idle;
  AppUpdate? _availableUpdate;

  @override
  String installedVersion = '1.0.0';

  @override
  UpdateStatus get status => _status;

  @override
  AppUpdate? get availableUpdate => _availableUpdate;

  @override
  DateTime? lastCheckAt;

  @override
  String errorMessage = '';

  @override
  double? downloadProgress;

  @override
  bool get isBusy =>
      _status == UpdateStatus.checking || _status == UpdateStatus.downloading;

  @override
  Future<void> start() async {}

  @override
  Future<void> checkIfDue() async => checkNow();

  @override
  Future<void> checkNow() async {
    _status = UpdateStatus.checking;
    notifyListeners();
    _availableUpdate = nextUpdate;
    errorMessage = nextErrorMessage;
    _status = nextStatus;
    notifyListeners();
  }

  @override
  Future<void> downloadAndInstall() async {}
}

const _availableUpdate = AppUpdate(
  version: '2.0.0',
  title: 'Gamebox 2.0.0',
  releaseNotes: '修复更新流程',
  releaseUrl: 'https://example.com/release',
  apkUrl: 'https://example.com/gamebox.apk',
  apkName: 'gamebox.apk',
  sha256: '0000000000000000000000000000000000000000000000000000000000000000',
);
