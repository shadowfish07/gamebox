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
    expect(find.byKey(const Key('host-smoke.normal-canary')), findsNothing);
  });

  testWidgets('instrumentation nonce exposes a normal launch canary', (
    tester,
  ) async {
    final launcher = _FakeGameLauncher();
    await tester.pumpWidget(
      GameboxApp(
        gameLauncher: launcher,
        hostSmokeEnabled: true,
        instrumentationCanaryNonce: 'nonce_1234',
      ),
    );

    await tester.tap(find.byKey(const Key('host-smoke.normal-canary')));
    await tester.pump();

    expect(launcher.launchCalls, 1);
    expect(launcher.lastRequest?.gameId, 'gomoku');
    expect(
      launcher.lastRequest?.launchTicket,
      'gamebox-canary-ticket-nonce_1234',
    );

    await tester.tap(find.byKey(const Key('host-smoke.collision-canary')));
    await tester.pump();

    expect(launcher.launchCalls, 2);
    expect(launcher.lastRequest?.gameId, '--launch-ticket');
    expect(
      launcher.lastRequest?.launchTicket,
      'gamebox-canary-ticket-nonce_1234',
    );
  });

  testWidgets('host-smoke button exposes a stable Android semantics label', (
    tester,
  ) async {
    await tester.pumpWidget(
      GameboxApp(gameLauncher: _FakeGameLauncher(), hostSmokeEnabled: true),
    );

    expect(
      tester.getSemantics(find.byKey(const Key('host-smoke.launch'))),
      matchesSemantics(
        label: 'host-smoke.launch',
        isButton: true,
        isEnabled: true,
        hasEnabledState: true,
        hasTapAction: true,
      ),
    );
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
    expect(
      tester.getSemantics(find.text('无法启动宿主烟测，请重试')),
      matchesSemantics(label: 'host-smoke.error'),
    );
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
  int launchCalls = 0;
  int hostSmokeCalls = 0;
  Completer<void>? pendingSmoke;
  Object? smokeError;
  GameLaunchRequest? lastRequest;

  @override
  Future<void> launch(GameLaunchRequest request) async {
    launchCalls += 1;
    lastRequest = request;
  }

  @override
  Future<void> launchHostSmoke() {
    hostSmokeCalls += 1;
    if (smokeError != null) {
      return Future<void>.error(smokeError!);
    }
    return pendingSmoke?.future ?? Future<void>.value();
  }
}
