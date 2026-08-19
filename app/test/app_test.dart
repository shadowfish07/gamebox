import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/app.dart';
import 'package:gamebox/core/platform/game_launch_request.dart';
import 'package:gamebox/core/platform/game_launcher.dart';

void main() {
  testWidgets(
    'default host-smoke setting keeps the unauthenticated holding UI',
    (tester) async {
      await tester.pumpWidget(GameboxApp(gameLauncher: _FakeGameLauncher()));

      expect(find.text('身份功能将在 Phase 3 接入'), findsOneWidget);
      expect(find.byKey(const Key('host-smoke.launch')), findsNothing);
    },
  );

  testWidgets('explicit host-smoke override renders one stable launch button', (
    tester,
  ) async {
    await tester.pumpWidget(
      GameboxApp(gameLauncher: _FakeGameLauncher(), hostSmokeEnabled: true),
    );

    expect(find.byKey(const Key('host-smoke.launch')), findsOneWidget);
    expect(find.text('身份功能将在 Phase 3 接入'), findsNothing);
  });

  testWidgets(
    'host-smoke tap invokes the injected launcher once while pending',
    (tester) async {
      final launcher = _FakeGameLauncher()..pendingSmoke = Completer<void>();
      await tester.pumpWidget(
        GameboxApp(gameLauncher: launcher, hostSmokeEnabled: true),
      );

      await tester.tap(find.byKey(const Key('host-smoke.launch')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('host-smoke.launch')));
      await tester.pump();

      expect(launcher.hostSmokeCalls, 1);
      launcher.pendingSmoke!.complete();
      await tester.pump();
    },
  );

  testWidgets('host-smoke platform failure is visible and retryable', (
    tester,
  ) async {
    final launcher = _FakeGameLauncher()
      ..smokeError = const GameLaunchException('unavailable');
    await tester.pumpWidget(
      GameboxApp(gameLauncher: launcher, hostSmokeEnabled: true),
    );

    await tester.tap(find.byKey(const Key('host-smoke.launch')));
    await tester.pump();

    expect(find.text('无法启动宿主烟测，请重试'), findsOneWidget);
    expect(find.byKey(const Key('host-smoke.launch')), findsOneWidget);
    await tester.tap(find.byKey(const Key('host-smoke.launch')));
    await tester.pump();
    expect(launcher.hostSmokeCalls, 2);
  });

  testWidgets('unexpected host-smoke errors are reported instead of retried', (
    tester,
  ) async {
    final launcher = _FakeGameLauncher()..smokeError = StateError('unexpected');
    await tester.pumpWidget(
      GameboxApp(gameLauncher: launcher, hostSmokeEnabled: true),
    );

    await tester.tap(find.byKey(const Key('host-smoke.launch')));
    await tester.pump();

    expect(tester.takeException(), isA<StateError>());
    expect(find.text('无法启动宿主烟测，请重试'), findsNothing);
  });
}

class _FakeGameLauncher implements GameLauncher {
  int hostSmokeCalls = 0;
  Completer<void>? pendingSmoke;
  Object? smokeError;

  @override
  Future<void> launch(GameLaunchRequest request) async {}

  @override
  Future<void> launchHostSmoke() {
    hostSmokeCalls += 1;
    if (smokeError != null) {
      return Future<void>.error(smokeError!);
    }
    return pendingSmoke?.future ?? Future<void>.value();
  }
}
