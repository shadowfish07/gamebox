import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/core/api/api_error.dart';
import 'package:gamebox/core/platform/game_launch_request.dart';
import 'package:gamebox/core/platform/game_launcher.dart';
import 'package:gamebox/features/gomoku/gomoku_models.dart';
import 'package:gamebox/features/gomoku/gomoku_repository.dart';
import 'package:gamebox/features/home/home_api.dart';
import 'package:gamebox/features/home/home_controller.dart';
import 'package:gamebox/features/home/home_page.dart';

void main() {
  const aliceId = '11111111-1111-4111-8111-111111111111';
  final now = DateTime.utc(2026, 8, 20, 12);

  testWidgets('idle catalog exposes stable game and opponent semantics', (
    tester,
  ) async {
    final fixture = _Fixture(now)..api.status = const GomokuIdleStatus();
    await tester.pumpWidget(_app(fixture.controller, aliceId));
    await _flushWidget(tester);

    expect(find.byKey(const Key('home-shell')), findsOneWidget);
    expect(find.text('你好，自己'), findsOneWidget);
    expect(find.byKey(const Key('game-gomoku')), findsOneWidget);
    expect(find.text('五子棋'), findsOneWidget);
    expect(find.byKey(const Key('choose-opponent')), findsOneWidget);
    expect(find.byKey(const Key('continue-match')), findsNothing);
    expect(
      tester.getSemantics(find.byKey(const Key('choose-opponent'))),
      matchesSemantics(
        label: 'choose-opponent',
        isButton: true,
        isEnabled: true,
        hasEnabledState: true,
        hasTapAction: true,
      ),
    );

    fixture.dispose();
  });

  testWidgets('active card shows opponent color revision and hides creation', (
    tester,
  ) async {
    final fixture = _Fixture(now)..api.status = _active(revision: 7);
    await tester.pumpWidget(_app(fixture.controller, aliceId));
    await _flushWidget(tester);

    expect(find.text('对手：小猫'), findsOneWidget);
    expect(find.text('你的颜色：黑方'), findsOneWidget);
    expect(find.text('当前步数：7'), findsOneWidget);
    expect(find.byKey(const Key('continue-match')), findsOneWidget);
    expect(find.byKey(const Key('choose-opponent')), findsNothing);
    expect(find.byKey(const Key('cancel-match')), findsNothing);
    expect(
      tester.getSemantics(find.byKey(const Key('continue-match'))),
      matchesSemantics(
        label: 'continue-match',
        isButton: true,
        isEnabled: true,
        hasEnabledState: true,
        hasTapAction: true,
      ),
    );

    fixture.dispose();
  });

  testWidgets('revision zero alone exposes the stable cancellation action', (
    tester,
  ) async {
    final fixture = _Fixture(now)..api.status = _active(revision: 0);
    await tester.pumpWidget(_app(fixture.controller, aliceId));
    await _flushWidget(tester);

    expect(find.byKey(const Key('cancel-match')), findsOneWidget);
    expect(find.text('取消未开始对局'), findsOneWidget);
    expect(
      tester.getSemantics(find.byKey(const Key('cancel-match'))),
      matchesSemantics(
        label: 'cancel-match',
        isButton: true,
        isEnabled: true,
        hasEnabledState: true,
        hasTapAction: true,
      ),
    );

    fixture.dispose();
  });

  testWidgets('continue double tap launches only once while pending', (
    tester,
  ) async {
    final launched = Completer<void>();
    final fixture = _Fixture(now)
      ..api.status = _active(revision: 3)
      ..launcher.onLaunch = (_) => launched.future;
    await tester.pumpWidget(_app(fixture.controller, aliceId));
    await _flushWidget(tester);

    await tester.tap(find.byKey(const Key('continue-match')));
    await tester.tap(find.byKey(const Key('continue-match')));
    await tester.pump();

    expect(fixture.api.ticketCalls, 1);
    expect(fixture.launcher.calls, 1);
    launched.complete();
    await _flushWidget(tester);
    fixture.dispose();
  });

  testWidgets('cancel failure displays the server-driven safe message', (
    tester,
  ) async {
    final fixture = _Fixture(now)
      ..api.status = _active(revision: 0)
      ..api.cancelError = const ApiError(
        code: 'match_not_cancellable',
        message: '对局无法取消',
      );
    await tester.pumpWidget(_app(fixture.controller, aliceId));
    await _flushWidget(tester);

    await tester.tap(find.byKey(const Key('cancel-match')));
    await _flushWidget(tester);

    expect(find.text('对局无法取消'), findsOneWidget);
    expect(find.byKey(const Key('cancel-match')), findsOneWidget);
    fixture.dispose();
  });

  testWidgets('idle selection uses standard Navigator to open opponents', (
    tester,
  ) async {
    final fixture = _Fixture(now)..api.status = const GomokuIdleStatus();
    await tester.pumpWidget(_app(fixture.controller, aliceId));
    await _flushWidget(tester);

    await tester.tap(find.byKey(const Key('choose-opponent')));
    await tester.pumpAndSettle();

    expect(find.text('选择对手'), findsOneWidget);
    expect(fixture.api.opponentCalls, 1);
    fixture.dispose();
  });

  testWidgets('initial Home failure is retryable instead of spinning forever', (
    tester,
  ) async {
    final fixture = _Fixture(now)
      ..api.statusError = const ApiError(
        code: 'network_error',
        message: '网络连接失败，请稍后重试',
      );
    await tester.pumpWidget(_app(fixture.controller, aliceId));
    await _flushWidget(tester);

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('网络连接失败，请稍后重试'), findsOneWidget);
    expect(find.byKey(const Key('retry-home')), findsOneWidget);

    fixture.api.statusError = null;
    await tester.tap(find.byKey(const Key('retry-home')));
    await _flushWidget(tester);
    expect(find.byKey(const Key('choose-opponent')), findsOneWidget);
    fixture.dispose();
  });
}

Widget _app(HomeController controller, String userId) => MaterialApp(
  theme: ThemeData(useMaterial3: true),
  home: HomePage(controller: controller, currentUserId: userId, nickname: '自己'),
);

Future<void> _flushWidget(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

GomokuActiveStatus _active({required int revision}) => GomokuActiveStatus(
  match: GomokuActiveMatch(
    id: '33333333-3333-4333-8333-333333333333',
    opponent: const GomokuOpponentIdentity(
      id: '22222222-2222-4222-8222-222222222222',
      nickname: '小猫',
    ),
    color: GomokuColor.black,
    revision: revision,
  ),
);

final class _Fixture {
  _Fixture(this.now) {
    controller = HomeController(
      repository: GomokuRepository(
        api: api,
        gameLauncher: launcher,
        apiBaseUri: Uri.parse('https://gamebox.test'),
        now: () => now,
      ),
      scheduler: _NoopScheduler(),
      now: () => now,
    );
  }

  final DateTime now;
  final _FakeHomeApi api = _FakeHomeApi();
  final _FakeLauncher launcher = _FakeLauncher();
  late final HomeController controller;

  void dispose() => controller.dispose();
}

final class _NoopScheduler implements HomePollScheduler {
  @override
  HomeScheduledCall schedulePeriodic(
    Duration period,
    void Function() callback,
  ) => _NoopCall();
}

final class _NoopCall implements HomeScheduledCall {
  @override
  void cancel() {}
}

final class _FakeLauncher implements GameLauncher {
  Future<void> Function(GameLaunchRequest request)? onLaunch;
  int calls = 0;

  @override
  Future<void> launch(GameLaunchRequest request) {
    calls += 1;
    return onLaunch?.call(request) ?? Future<void>.value();
  }

  @override
  Future<void> launchHostSmoke() =>
      Future<void>.error(StateError('unexpected host smoke'));
}

final class _FakeHomeApi implements HomeApi {
  GomokuStatus status = const GomokuIdleStatus();
  ApiError? statusError;
  ApiError? cancelError;
  int ticketCalls = 0;
  int opponentCalls = 0;

  @override
  Future<GomokuStatus> fetchStatus() async {
    final error = statusError;
    if (error != null) throw error;
    return status;
  }

  @override
  Future<List<GomokuOpponent>> fetchOpponents() async {
    opponentCalls += 1;
    return const [];
  }

  @override
  Future<GomokuLaunchTicket> createLaunchTicket(String matchId) async {
    ticketCalls += 1;
    return GomokuLaunchTicket(
      matchId: matchId,
      gameId: 'gomoku',
      launchTicket: 'launch-ticket',
      expiresAt: DateTime.utc(2026, 8, 20, 12, 1),
    );
  }

  @override
  Future<void> cancelMatch(String matchId) async {
    final error = cancelError;
    if (error != null) throw error;
    status = const GomokuIdleStatus();
  }

  @override
  Future<CreatedGomokuMatch> createMatch(String opponentId) =>
      Future<CreatedGomokuMatch>.error(StateError('unexpected create'));
}
