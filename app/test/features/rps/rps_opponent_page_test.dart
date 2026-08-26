import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/core/api/api_error.dart';
import 'package:gamebox/core/platform/game_launch_request.dart';
import 'package:gamebox/core/platform/game_launcher.dart';
import 'package:gamebox/design_system/gamebox_theme.dart';
import 'package:gamebox/features/gomoku/gomoku_models.dart';
import 'package:gamebox/features/rps/rps_api.dart';
import 'package:gamebox/features/rps/rps_controller.dart';
import 'package:gamebox/features/rps/rps_models.dart';
import 'package:gamebox/features/rps/rps_opponent_page.dart';
import 'package:gamebox/features/rps/rps_repository.dart';

void main() {
  const userId = '11111111-1111-4111-8111-111111111111';
  const opponentId = '22222222-2222-4222-8222-222222222222';
  final now = DateTime.utc(2026, 8, 25, 12);

  testWidgets('defaults to one round and forwards a changed best-of-three', (
    tester,
  ) async {
    final api = _FakeRpsApi(now);
    final controller = RpsController(
      repository: RpsRepository(
        api: api,
        gameLauncher: _Launcher(),
        apiBaseUri: Uri.parse('https://gamebox.test'),
        now: () => now,
      ),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: GameboxTheme.light(),
        home: RpsOpponentPage(controller: controller, currentUserId: userId),
      ),
    );
    await tester.pump();
    await tester.pump();

    final selector = tester.widget<SegmentedButton<RpsFormat>>(
      find.byKey(const Key('rps-format-selector')),
    );
    expect(selector.selected, {RpsFormat.singleRound});
    expect(find.text('一局定胜负'), findsOneWidget);
    expect(find.text('三局两胜'), findsOneWidget);

    await tester.tap(find.text('三局两胜'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('rps-opponent-$opponentId')));
    await tester.pump();
    await tester.pump();

    expect(api.createdOpponent, opponentId);
    expect(api.createdFormat, RpsFormat.bestOfThree);
  });

  testWidgets('opponent_busy refreshes the opponent availability', (
    tester,
  ) async {
    final api = _FakeRpsApi(now)
      ..createError = const ApiError(
        code: 'opponent_busy',
        message: '对手已进入其他对局',
      );
    final controller = RpsController(
      repository: RpsRepository(
        api: api,
        gameLauncher: _Launcher(),
        apiBaseUri: Uri.parse('https://gamebox.test'),
        now: () => now,
      ),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: GameboxTheme.light(),
        home: RpsOpponentPage(controller: controller, currentUserId: userId),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('rps-opponent-$opponentId')));
    await tester.pumpAndSettle();

    expect(api.opponentCalls, 2);
    expect(find.text('对手已进入其他对局'), findsOneWidget);
    expect(find.text('在线 · 游戏中'), findsOneWidget);
  });

  test(
    'creating state is visible in the first mutation notification',
    () async {
      final pending = Completer<CreatedRpsMatch>();
      final api = _FakeRpsApi(now)..pendingCreate = pending;
      final controller = RpsController(
        repository: RpsRepository(
          api: api,
          gameLauncher: _Launcher(),
          apiBaseUri: Uri.parse('https://gamebox.test'),
          now: () => now,
        ),
      );
      addTearDown(controller.dispose);
      final creatingStates = <bool>[];
      controller.addListener(() => creatingStates.add(controller.isCreating));

      final result = controller.createAndOpen(
        opponentId,
        RpsFormat.singleRound,
      );
      await Future<void>.delayed(Duration.zero);

      expect(creatingStates, isNotEmpty);
      expect(creatingStates.first, isTrue);
      pending.complete(
        const CreatedRpsMatch(
          id: '33333333-3333-4333-8333-333333333333',
          format: RpsFormat.singleRound,
        ),
      );
      expect(await result, isNull);
    },
  );
}

final class _FakeRpsApi implements RpsApi {
  _FakeRpsApi(this.now);

  final DateTime now;
  String? createdOpponent;
  RpsFormat? createdFormat;
  ApiError? createError;
  Completer<CreatedRpsMatch>? pendingCreate;
  var opponentCalls = 0;

  @override
  Future<List<GomokuOpponent>> fetchOpponents() async {
    opponentCalls++;
    return [
      GomokuOpponent(
        id: '22222222-2222-4222-8222-222222222222',
        nickname: '小猫',
        availability: opponentCalls > 1 && createError != null
            ? OpponentAvailability.busy
            : OpponentAvailability.idle,
        presence: OpponentPresence.online,
      ),
    ];
  }

  @override
  Future<CreatedRpsMatch> createMatch(
    String opponentId,
    RpsFormat format,
  ) async {
    createdOpponent = opponentId;
    createdFormat = format;
    if (createError case final error?) throw error;
    if (pendingCreate case final pending?) return pending.future;
    return CreatedRpsMatch(
      id: '33333333-3333-4333-8333-333333333333',
      format: format,
    );
  }

  @override
  Future<RpsLaunchTicket> createLaunchTicket(String matchId) async =>
      RpsLaunchTicket(
        matchId: matchId,
        launchTicket: 'ticket',
        expiresAt: now.add(const Duration(minutes: 1)),
      );

  @override
  Future<RpsStatus> fetchStatus() async => const RpsIdleStatus();

  @override
  Future<void> cancelMatch(String matchId) async {}
}

final class _Launcher implements GameLauncher {
  @override
  Future<void> launch(GameLaunchRequest request) async {}

  @override
  Future<void> launchHostSmoke() async {}
}
