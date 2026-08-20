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
import 'package:gamebox/features/home/opponent_page.dart';

void main() {
  const aliceId = '11111111-1111-4111-8111-111111111111';
  const bobId = '22222222-2222-4222-8222-222222222222';
  const carolId = '44444444-4444-4444-8444-444444444444';
  final now = DateTime.utc(2026, 8, 20, 12);

  testWidgets('excludes self and presents busy/offline rows accurately', (
    tester,
  ) async {
    final fixture = _Fixture(now)
      ..api.opponents = const [
        GomokuOpponent(
          id: aliceId,
          nickname: '自己',
          availability: OpponentAvailability.idle,
          presence: OpponentPresence.online,
        ),
        GomokuOpponent(
          id: bobId,
          nickname: '小猫',
          availability: OpponentAvailability.busy,
          presence: OpponentPresence.online,
        ),
        GomokuOpponent(
          id: carolId,
          nickname: '小鸟',
          availability: OpponentAvailability.idle,
          presence: OpponentPresence.offline,
        ),
      ];
    await tester.pumpWidget(_app(fixture.controller, aliceId));
    await _flushWidget(tester);

    expect(find.text('自己'), findsNothing);
    expect(find.byKey(const Key('opponent-$aliceId')), findsNothing);
    expect(find.text('小猫'), findsOneWidget);
    expect(find.text('游戏中'), findsOneWidget);
    expect(find.text('离线 · 可邀请'), findsOneWidget);
    expect(
      tester.getSemantics(find.byKey(const Key('opponent-$bobId'))),
      containsSemantics(
        identifier: 'opponent-$bobId',
        label: '小猫\n游戏中',
        isButton: true,
        isEnabled: false,
        hasEnabledState: true,
      ),
    );
    expect(
      tester.getSemantics(find.byKey(const Key('opponent-$carolId'))),
      containsSemantics(
        identifier: 'opponent-$carolId',
        label: '小鸟\n离线 · 可邀请',
        isButton: true,
        isEnabled: true,
        hasEnabledState: true,
        hasTapAction: true,
      ),
    );
    fixture.dispose();
  });

  testWidgets('double tap issues one create and shows row loading', (
    tester,
  ) async {
    final pending = Completer<CreatedGomokuMatch>();
    final fixture = _Fixture(now)
      ..api.opponents = const [
        GomokuOpponent(
          id: carolId,
          nickname: '小鸟',
          availability: OpponentAvailability.idle,
          presence: OpponentPresence.offline,
        ),
      ]
      ..api.onCreate = (_) => pending.future;
    await tester.pumpWidget(_app(fixture.controller, aliceId));
    await _flushWidget(tester);

    await tester.tap(find.byKey(const Key('opponent-$carolId')));
    await tester.tap(find.byKey(const Key('opponent-$carolId')));
    await tester.pump();

    expect(fixture.api.createCalls, 1);
    expect(
      find.descendant(
        of: find.byKey(const Key('opponent-$carolId')),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    final loadingSemantics = tester.getSemantics(
      find.byKey(const Key('opponent-$carolId')),
    );
    expect(loadingSemantics.label, contains('小鸟'));
    expect(loadingSemantics.label, contains('离线 · 可邀请'));
    expect(
      loadingSemantics,
      containsSemantics(
        identifier: 'opponent-$carolId',
        isButton: true,
        isEnabled: false,
        hasEnabledState: true,
      ),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete(
      const CreatedGomokuMatch(
        id: '33333333-3333-4333-8333-333333333333',
        gameId: 'gomoku',
      ),
    );
    await _flushWidget(tester);
    fixture.dispose();
  });

  testWidgets(
    'opponent_busy refreshes rows and displays a safe Chinese error',
    (tester) async {
      final fixture = _Fixture(now)
        ..api.opponents = const [
          GomokuOpponent(
            id: carolId,
            nickname: '小鸟',
            availability: OpponentAvailability.idle,
            presence: OpponentPresence.offline,
          ),
        ]
        ..api.onCreate = (_) async {
          throw const ApiError(code: 'opponent_busy', message: '对手已进入其他对局');
        }
        ..api.afterCreateFailureOpponents = const [
          GomokuOpponent(
            id: carolId,
            nickname: '小鸟',
            availability: OpponentAvailability.busy,
            presence: OpponentPresence.offline,
          ),
        ];
      await tester.pumpWidget(_navigatorApp(fixture.controller, aliceId));
      await tester.tap(find.byKey(const Key('open-opponents')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('opponent-$carolId')));
      await _flushWidget(tester);
      await _flushWidget(tester);

      expect(fixture.api.createCalls, 1);
      expect(fixture.api.opponentCalls, 2);
      expect(find.text('对手已进入其他对局'), findsOneWidget);
      expect(find.text('游戏中'), findsOneWidget);
      expect(
        tester.getSemantics(find.byKey(const Key('opponent-error'))),
        containsSemantics(
          identifier: 'opponent-error',
          label: '对手已进入其他对局',
          isLiveRegion: true,
        ),
      );
      expect(
        tester.getSemantics(find.byKey(const Key('opponent-$carolId'))),
        containsSemantics(
          identifier: 'opponent-$carolId',
          label: '小鸟\n游戏中',
          isButton: true,
          isEnabled: false,
          hasEnabledState: true,
        ),
      );
      fixture.dispose();
    },
  );

  testWidgets('late opponent response cannot notify an unmounted page', (
    tester,
  ) async {
    final pending = Completer<List<GomokuOpponent>>();
    final fixture = _Fixture(now)..api.onOpponents = () => pending.future;
    await tester.pumpWidget(_app(fixture.controller, aliceId));
    await tester.pump();

    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete(const []);
    await _flushWidget(tester);

    expect(tester.takeException(), isNull);
    fixture.dispose();
  });

  testWidgets(
    'retry clears the old error, shows progress, and is single flight',
    (tester) async {
      final retry = Completer<List<GomokuOpponent>>();
      var request = 0;
      final fixture = _Fixture(now)
        ..api.onOpponents = () {
          request += 1;
          if (request == 1) {
            return Future<List<GomokuOpponent>>.error(
              const ApiError(code: 'network_error', message: '网络连接失败，请稍后重试'),
            );
          }
          return retry.future;
        };
      await tester.pumpWidget(_app(fixture.controller, aliceId));
      await _flushWidget(tester);

      expect(find.text('网络连接失败，请稍后重试'), findsOneWidget);
      final retryButton = find.text('重试');
      await tester.tap(retryButton);
      await tester.tap(retryButton);
      await tester.pump();

      expect(fixture.api.opponentCalls, 2);
      expect(find.text('网络连接失败，请稍后重试'), findsNothing);
      expect(find.byKey(const Key('opponent-loading')), findsOneWidget);
      expect(find.text('重试'), findsNothing);

      retry.complete(const [
        GomokuOpponent(
          id: carolId,
          nickname: '小鸟',
          availability: OpponentAvailability.idle,
          presence: OpponentPresence.online,
        ),
      ]);
      await _flushWidget(tester);

      expect(find.byKey(const Key('opponent-loading')), findsNothing);
      expect(find.text('网络连接失败，请稍后重试'), findsNothing);
      expect(find.text('小鸟'), findsOneWidget);
      fixture.dispose();
    },
  );

  testWidgets(
    'successful create leaves the opponent route even if refetch fails',
    (tester) async {
      final fixture = _Fixture(now)
        ..api.opponents = const [
          GomokuOpponent(
            id: carolId,
            nickname: '小鸟',
            availability: OpponentAvailability.idle,
            presence: OpponentPresence.online,
          ),
        ]
        ..api.onCreate = (_) async {
          return const CreatedGomokuMatch(
            id: '33333333-3333-4333-8333-333333333333',
            gameId: 'gomoku',
          );
        }
        ..api.onTicket = (matchId) async {
          return GomokuLaunchTicket(
            matchId: matchId,
            gameId: 'gomoku',
            launchTicket: 'launch-ticket',
            expiresAt: now.add(const Duration(minutes: 1)),
          );
        }
        ..api.statusError = const ApiError(
          code: 'network_error',
          message: '网络连接失败，请稍后重试',
        );
      await tester.pumpWidget(_navigatorApp(fixture.controller, aliceId));
      await tester.tap(find.byKey(const Key('open-opponents')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('opponent-$carolId')));
      await tester.pumpAndSettle();

      expect(find.text('选择对手'), findsNothing);
      expect(fixture.api.createCalls, 1);
      fixture.dispose();
    },
  );
}

Widget _app(HomeController controller, String userId) => MaterialApp(
  theme: ThemeData(useMaterial3: true),
  home: OpponentPage(controller: controller, currentUserId: userId),
);

Widget _navigatorApp(HomeController controller, String userId) => MaterialApp(
  theme: ThemeData(useMaterial3: true),
  home: Builder(
    builder: (context) => Scaffold(
      body: FilledButton(
        key: const Key('open-opponents'),
        onPressed: () => Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) =>
                OpponentPage(controller: controller, currentUserId: userId),
          ),
        ),
        child: const Text('打开'),
      ),
    ),
  ),
);

Future<void> _flushWidget(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

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
  @override
  Future<void> launch(GameLaunchRequest request) async {}

  @override
  Future<void> launchHostSmoke() async {}
}

final class _FakeHomeApi implements HomeApi {
  List<GomokuOpponent> opponents = const [];
  List<GomokuOpponent>? afterCreateFailureOpponents;
  Future<List<GomokuOpponent>> Function()? onOpponents;
  Future<CreatedGomokuMatch> Function(String opponentId)? onCreate;
  Future<GomokuLaunchTicket> Function(String matchId)? onTicket;
  ApiError? statusError;
  int opponentCalls = 0;
  int createCalls = 0;

  @override
  Future<List<GomokuOpponent>> fetchOpponents() {
    opponentCalls += 1;
    final custom = onOpponents;
    if (custom != null) return custom();
    if (createCalls > 0 && afterCreateFailureOpponents != null) {
      return Future.value(afterCreateFailureOpponents);
    }
    return Future.value(opponents);
  }

  @override
  Future<CreatedGomokuMatch> createMatch(String opponentId) {
    createCalls += 1;
    return onCreate?.call(opponentId) ??
        Future<CreatedGomokuMatch>.error(StateError('unexpected create'));
  }

  @override
  Future<GomokuStatus> fetchStatus() async {
    final error = statusError;
    if (error != null) throw error;
    return const GomokuIdleStatus();
  }

  @override
  Future<void> cancelMatch(String matchId) =>
      Future<void>.error(StateError('unexpected cancel'));

  @override
  Future<GomokuLaunchTicket> createLaunchTicket(String matchId) =>
      onTicket?.call(matchId) ??
      Future<GomokuLaunchTicket>.error(StateError('unexpected ticket'));
}
