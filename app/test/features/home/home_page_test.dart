import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/core/api/api_error.dart';
import 'package:gamebox/core/platform/game_launch_request.dart';
import 'package:gamebox/core/platform/game_launcher.dart';
import 'package:gamebox/design_system/components/gamebox_async_panel.dart';
import 'package:gamebox/design_system/components/gamebox_page_body.dart';
import 'package:gamebox/design_system/components/gamebox_pending_button.dart';
import 'package:gamebox/design_system/gamebox_theme.dart';
import 'package:gamebox/features/gomoku/gomoku_models.dart';
import 'package:gamebox/features/gomoku/gomoku_repository.dart';
import 'package:gamebox/features/history/match_history_api.dart';
import 'package:gamebox/features/history/match_history_models.dart';
import 'package:gamebox/features/home/home_api.dart';
import 'package:gamebox/features/home/home_controller.dart';
import 'package:gamebox/features/home/home_page.dart';
import 'package:gamebox/features/rps/rps_api.dart';
import 'package:gamebox/features/rps/rps_controller.dart';
import 'package:gamebox/features/rps/rps_models.dart';
import 'package:gamebox/features/rps/rps_repository.dart';

void main() {
  const aliceId = '11111111-1111-4111-8111-111111111111';
  const carolId = '44444444-4444-4444-8444-444444444444';
  final now = DateTime.utc(2026, 8, 20, 12);

  testWidgets(
    'idle catalog preserves stable game and opponent automation ids',
    (tester) async {
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
        find.byKey(const Key('choose-opponent')).evaluate().single.widget,
        isA<GameboxPendingButton>(),
      );
      expect(find.bySemanticsIdentifier('choose-opponent'), findsOneWidget);
      expect(
        tester.getSemantics(find.bySemanticsIdentifier('choose-opponent')),
        isSemantics(
          identifier: 'choose-opponent',
          isButton: true,
          hasTapAction: true,
        ),
      );
      final gameSemantics = tester.getSemantics(
        find.byKey(const Key('game-gomoku')),
      );
      expect(
        gameSemantics,
        isSemantics(
          identifier: 'game-gomoku',
          label: '五子棋\n2 人 · 回合制',
          isHeader: true,
        ),
      );
      expect(
        tester
            .widget<FilledButton>(
              find.descendant(
                of: find.byKey(const Key('choose-opponent')),
                matching: find.byType(FilledButton),
              ),
            )
            .onPressed,
        isNotNull,
      );

      fixture.dispose();
    },
  );

  testWidgets('Chinese checkers card uses dedicated direct-play actions', (
    tester,
  ) async {
    final gomoku = _Fixture(now)..api.status = const GomokuIdleStatus();
    final chineseCheckers = _Fixture(now)
      ..api.status = const GomokuIdleStatus();
    await tester.pumpWidget(
      _app(
        gomoku.controller,
        aliceId,
        chineseCheckersController: chineseCheckers.controller,
      ),
    );
    await _flushWidget(tester);

    expect(find.byKey(const Key('game-chinese-checkers')), findsOneWidget);
    expect(find.text('跳棋'), findsOneWidget);
    expect(find.text('2 人 · 连跳竞速'), findsOneWidget);
    expect(
      find.bySemanticsIdentifier('chinese-checkers-choose-opponent'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsIdentifier('open-chinese-checkers-history'),
      findsOneWidget,
    );
    expect(
      tester.getSemantics(find.byKey(const Key('game-chinese-checkers'))),
      isSemantics(
        identifier: 'game-chinese-checkers',
        label: '跳棋\n2 人 · 连跳竞速',
        isHeader: true,
      ),
    );

    gomoku.dispose();
    chineseCheckers.dispose();
  });

  testWidgets('Chinese checkers active card preserves dedicated action ids', (
    tester,
  ) async {
    final gomoku = _Fixture(now)..api.status = const GomokuIdleStatus();
    final chineseCheckers = _Fixture(now)..api.status = _active(revision: 0);
    await tester.pumpWidget(
      _app(
        gomoku.controller,
        aliceId,
        chineseCheckersController: chineseCheckers.controller,
      ),
    );
    await _flushWidget(tester);
    await _flushWidget(tester);

    expect(find.text('你的顺序：先手'), findsOneWidget);
    expect(
      find.bySemanticsIdentifier('chinese-checkers-continue-match'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsIdentifier('chinese-checkers-cancel-match'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsIdentifier('open-chinese-checkers-history'),
      findsOneWidget,
    );

    gomoku.dispose();
    chineseCheckers.dispose();
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
      find.byKey(const Key('continue-match')).evaluate().single.widget,
      isA<GameboxPendingButton>(),
    );
    expect(find.bySemanticsIdentifier('continue-match'), findsOneWidget);
    expect(
      tester.getSemantics(find.bySemanticsIdentifier('continue-match')),
      isSemantics(
        identifier: 'continue-match',
        isButton: true,
        hasTapAction: true,
      ),
    );
    expect(
      tester
          .widget<FilledButton>(
            find.descendant(
              of: find.byKey(const Key('continue-match')),
              matching: find.byType(FilledButton),
            ),
          )
          .onPressed,
      isNotNull,
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
      isSemantics(
        identifier: 'cancel-match',
        label: '取消未开始对局',
        isButton: true,
        isEnabled: true,
        hasEnabledState: true,
        hasTapAction: true,
      ),
    );

    await tester.tap(find.byKey(const Key('cancel-match')));
    await tester.pumpAndSettle();

    expect(find.text('取消这局尚未开始的对局？'), findsOneWidget);
    expect(find.text('取消后，双方将返回空闲状态。'), findsOneWidget);
    expect(find.bySemanticsIdentifier('dismiss-cancel-match'), findsOneWidget);
    expect(find.bySemanticsIdentifier('confirm-cancel-match'), findsOneWidget);
    expect(fixture.api.cancelCalls, 0);

    await tester.tap(find.bySemanticsIdentifier('dismiss-cancel-match'));
    await tester.pumpAndSettle();
    expect(find.text('取消这局尚未开始的对局？'), findsNothing);
    expect(fixture.api.cancelCalls, 0);

    await tester.tap(find.byKey(const Key('cancel-match')));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsIdentifier('confirm-cancel-match'));
    await _flushWidget(tester);
    expect(fixture.api.cancelCalls, 1);

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

  testWidgets('launch pending disables both active match actions', (
    tester,
  ) async {
    final launched = Completer<void>();
    final fixture = _Fixture(now)
      ..api.status = _active(revision: 0)
      ..launcher.onLaunch = (_) => launched.future;
    await tester.pumpWidget(_app(fixture.controller, aliceId));
    await _flushWidget(tester);

    await tester.tap(find.byKey(const Key('continue-match')));
    await tester.pump();

    expect(
      tester
          .widget<FilledButton>(
            find.descendant(
              of: find.byKey(const Key('continue-match')),
              matching: find.byType(FilledButton),
            ),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(
            find.descendant(
              of: find.byKey(const Key('cancel-match')),
              matching: find.byType(TextButton),
            ),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(
      find.byKey(const Key('cancel-match')),
      warnIfMissed: false,
    );
    expect(fixture.api.cancelCalls, 0);

    launched.complete();
    await _flushWidget(tester);
    fixture.dispose();
  });

  testWidgets('cancel pending disables both active match actions', (
    tester,
  ) async {
    final cancelled = Completer<void>();
    addTearDown(() {
      if (!cancelled.isCompleted) cancelled.complete();
    });
    final fixture = _Fixture(now)..api.status = _active(revision: 0);
    fixture.api.onCancel = (_) async {
      await cancelled.future;
      fixture.api.status = const GomokuIdleStatus();
    };
    await tester.pumpWidget(_app(fixture.controller, aliceId));
    await _flushWidget(tester);

    await tester.tap(find.byKey(const Key('cancel-match')));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsIdentifier('confirm-cancel-match'));
    await tester.pump();

    expect(
      tester
          .widget<FilledButton>(
            find.descendant(
              of: find.byKey(const Key('continue-match')),
              matching: find.byType(FilledButton),
            ),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(
            find.descendant(
              of: find.byKey(const Key('cancel-match')),
              matching: find.byType(TextButton),
            ),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(
      find.byKey(const Key('continue-match')),
      warnIfMissed: false,
    );
    expect(fixture.api.ticketCalls, 0);

    cancelled.complete();
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
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsIdentifier('confirm-cancel-match'));
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

  testWidgets('idle creation stays disabled after its opponent route pops', (
    tester,
  ) async {
    final created = Completer<CreatedGomokuMatch>();
    final fixture = _Fixture(now)
      ..api.status = const GomokuIdleStatus()
      ..api.opponents = const [
        GomokuOpponent(
          id: carolId,
          nickname: '小鸟',
          availability: OpponentAvailability.idle,
          presence: OpponentPresence.online,
        ),
      ]
      ..api.onCreate = (_) => created.future;
    await tester.pumpWidget(_app(fixture.controller, aliceId));
    await _flushWidget(tester);

    await tester.tap(find.byKey(const Key('choose-opponent')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('opponent-$carolId')));
    await tester.pump();
    expect(fixture.api.createCalls, 1);

    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const Key('home-shell')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('choose-opponent')),
        matching: find.text('正在创建对局'),
      ),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.descendant(
              of: find.byKey(const Key('choose-opponent')),
              matching: find.byType(FilledButton),
            ),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(
      find.byKey(const Key('choose-opponent')),
      warnIfMissed: false,
    );
    expect(fixture.api.opponentCalls, 1);

    fixture.api.status = _active(revision: 0);
    created.complete(
      const CreatedGomokuMatch(
        id: '33333333-3333-4333-8333-333333333333',
        gameId: 'gomoku',
      ),
    );
    await tester.pumpAndSettle();
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
    await tester.pumpWidget(
      _app(fixture.controller, aliceId, historyApi: fixture.historyApi),
    );
    await _flushWidget(tester);

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(GameboxAsyncPanel), findsOneWidget);
    expect(find.text('网络连接失败，请稍后重试'), findsOneWidget);
    expect(find.byKey(const Key('retry-home')), findsOneWidget);
    expect(find.bySemanticsIdentifier('retry-home'), findsOneWidget);
    expect(find.byKey(const Key('open-match-history')), findsOneWidget);
    expect(find.bySemanticsIdentifier('open-match-history'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.descendant(
              of: find.byKey(const Key('retry-home')),
              matching: find.byType(FilledButton),
            ),
          )
          .onPressed,
      isNotNull,
    );

    await tester.tap(find.byKey(const Key('open-match-history')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('match-history-page')), findsOneWidget);
    expect(fixture.historyApi.games, [MatchHistoryGame.gomoku]);
    await tester.tap(find.byKey(const Key('match-history-back')));
    await tester.pumpAndSettle();

    fixture.api.statusError = null;
    await tester.tap(find.byKey(const Key('retry-home')));
    await _flushWidget(tester);
    expect(find.byKey(const Key('choose-opponent')), findsOneWidget);
    fixture.dispose();
  });

  testWidgets('RPS history remains reachable when its status request fails', (
    tester,
  ) async {
    final fixture = _Fixture(now)..api.status = const GomokuIdleStatus();
    final rpsController = RpsController(
      repository: RpsRepository(
        api: const _FakeRpsApi(
          statusError: ApiError(code: 'network_error', message: '石头剪刀布状态加载失败'),
        ),
        gameLauncher: fixture.launcher,
        apiBaseUri: Uri.parse('https://gamebox.test'),
        now: () => now,
      ),
    );
    await tester.pumpWidget(
      _app(
        fixture.controller,
        aliceId,
        historyApi: fixture.historyApi,
        rpsController: rpsController,
      ),
    );
    await _flushWidget(tester);
    await tester.ensureVisible(find.byKey(const Key('open-rps-history')));
    await tester.pumpAndSettle();

    expect(find.text('石头剪刀布状态加载失败'), findsOneWidget);
    expect(find.bySemanticsIdentifier('retry-rps-home'), findsOneWidget);
    expect(find.bySemanticsIdentifier('open-rps-history'), findsOneWidget);
    await tester.tap(find.byKey(const Key('open-rps-history')));
    await tester.pumpAndSettle();
    expect(find.text('石头剪刀布战绩'), findsOneWidget);
    expect(fixture.historyApi.games, [MatchHistoryGame.rps]);

    rpsController.dispose();
    fixture.dispose();
  });

  testWidgets(
    'Chinese checkers history remains reachable when its status request fails',
    (tester) async {
      final gomoku = _Fixture(now)..api.status = const GomokuIdleStatus();
      final chineseCheckers = _Fixture(now)
        ..api.statusError = const ApiError(
          code: 'network_error',
          message: '跳棋状态加载失败',
        );
      await tester.pumpWidget(
        _app(
          gomoku.controller,
          aliceId,
          historyApi: gomoku.historyApi,
          chineseCheckersController: chineseCheckers.controller,
        ),
      );
      await _flushWidget(tester);
      await tester.ensureVisible(
        find.byKey(const Key('open-chinese-checkers-history')),
      );
      await tester.pumpAndSettle();

      expect(find.text('跳棋状态加载失败'), findsOneWidget);
      expect(
        find.bySemanticsIdentifier('chinese-checkers-retry-home'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('open-chinese-checkers-history')));
      await tester.pumpAndSettle();
      expect(find.text('跳棋战绩'), findsOneWidget);
      expect(gomoku.historyApi.games, [MatchHistoryGame.chineseCheckers]);

      gomoku.dispose();
      chineseCheckers.dispose();
    },
  );

  testWidgets(
    'game cards open their own history and visible back preserves Home',
    (tester) async {
      final fixture = _Fixture(now)..api.status = const GomokuIdleStatus();
      final rpsController = RpsController(
        repository: RpsRepository(
          api: _FakeRpsApi(revision: 0),
          gameLauncher: fixture.launcher,
          apiBaseUri: Uri.parse('https://gamebox.test'),
          now: () => now,
        ),
      );
      await tester.pumpWidget(
        _app(
          fixture.controller,
          aliceId,
          historyApi: fixture.historyApi,
          rpsController: rpsController,
        ),
      );
      await _flushWidget(tester);
      final statusCalls = fixture.api.statusCalls;

      expect(find.bySemanticsIdentifier('open-match-history'), findsOneWidget);
      expect(find.bySemanticsIdentifier('open-gomoku-history'), findsNothing);
      expect(find.byKey(const Key('open-match-history')), findsOneWidget);
      expect(find.bySemanticsIdentifier('open-rps-history'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('open-match-history')),
          matching: find.byType(OutlinedButton),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('open-match-history')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('match-history-page')), findsOneWidget);
      expect(find.text('五子棋战绩'), findsOneWidget);
      expect(find.text('石头剪刀布战绩'), findsNothing);
      expect(fixture.historyApi.games, [MatchHistoryGame.gomoku]);

      await tester.tap(find.byKey(const Key('match-history-back')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('home-shell')), findsOneWidget);
      expect(
        tester.widget<HomePage>(find.byType(HomePage)).controller,
        same(fixture.controller),
      );
      expect(fixture.api.statusCalls, statusCalls);

      await tester.ensureVisible(find.byKey(const Key('open-rps-history')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('open-rps-history')));
      await tester.pumpAndSettle();
      expect(find.text('石头剪刀布战绩'), findsOneWidget);
      expect(find.text('五子棋战绩'), findsNothing);
      expect(fixture.historyApi.games, [
        MatchHistoryGame.gomoku,
        MatchHistoryGame.rps,
      ]);
      rpsController.dispose();
      fixture.dispose();
    },
  );

  testWidgets('system back returns to the same Home instance', (tester) async {
    final fixture = _Fixture(now)..api.status = const GomokuIdleStatus();
    final rpsController = RpsController(
      repository: RpsRepository(
        api: _FakeRpsApi(revision: 0),
        gameLauncher: fixture.launcher,
        apiBaseUri: Uri.parse('https://gamebox.test'),
        now: () => now,
      ),
    );
    await tester.pumpWidget(
      _app(
        fixture.controller,
        aliceId,
        historyApi: fixture.historyApi,
        rpsController: rpsController,
      ),
    );
    await _flushWidget(tester);
    final statusCalls = fixture.api.statusCalls;

    await tester.ensureVisible(find.byKey(const Key('open-rps-history')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('open-rps-history')));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('home-shell')), findsOneWidget);
    expect(
      tester.widget<HomePage>(find.byType(HomePage)).controller,
      same(fixture.controller),
    );
    expect(fixture.api.statusCalls, statusCalls);
    rpsController.dispose();
    fixture.dispose();
  });

  testWidgets('invited RPS player sees the persisted best-of-three format', (
    tester,
  ) async {
    final fixture = _Fixture(now);
    final rpsController = RpsController(
      repository: RpsRepository(
        api: _FakeRpsApi(revision: 5),
        gameLauncher: fixture.launcher,
        apiBaseUri: Uri.parse('https://gamebox.test'),
        now: () => now,
      ),
    );
    await tester.pumpWidget(
      _app(fixture.controller, aliceId, rpsController: rpsController),
    );
    await _flushWidget(tester);

    expect(find.text('赛制：三局两胜'), findsOneWidget);
    expect(find.text('当前轮次：第 3 轮'), findsOneWidget);
    expect(find.textContaining('当前事件'), findsNothing);
    expect(
      find.bySemanticsIdentifier('rps-active-format-best_of_three'),
      findsOneWidget,
    );

    rpsController.dispose();
    fixture.dispose();
  });

  for (final configuration in const [
    (size: Size(360, 800), status: 'idle', nickname: '一位名字很长但仍需要正常换行的玩家'),
    (size: Size(412, 915), status: 'active', nickname: '另一位名字很长的玩家'),
  ]) {
    testWidgets('lays out dark ${configuration.status} Home at '
        '${configuration.size}', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = configuration.size;
      addTearDown(tester.view.reset);
      final fixture = _Fixture(now)
        ..api.status = configuration.status == 'idle'
            ? const GomokuIdleStatus()
            : _active(revision: 0);

      await tester.pumpWidget(
        _app(
          fixture.controller,
          aliceId,
          nickname: configuration.nickname,
          dark: true,
        ),
      );
      await _flushWidget(tester);

      final home = find.byType(HomePage);
      expect(find.byType(GameboxPageBody), findsOneWidget);
      expect(find.text('五子棋'), findsOneWidget);
      expect(find.text('2 人 · 回合制'), findsOneWidget);
      expect(find.byType(GameboxPendingButton), findsOneWidget);
      expect(Theme.of(tester.element(home)).brightness, Brightness.dark);
      expect(tester.takeException(), isNull);
      fixture.dispose();
    });
  }

  testWidgets('320dp Home stacks per-game actions at 200% text scale', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final fixture = _Fixture(now)..api.status = const GomokuIdleStatus();
    final rpsController = RpsController(
      repository: RpsRepository(
        api: const _FakeRpsApi(isIdle: true),
        gameLauncher: fixture.launcher,
        apiBaseUri: Uri.parse('https://gamebox.test'),
        now: () => now,
      ),
    );

    await tester.pumpWidget(
      _app(fixture.controller, aliceId, rpsController: rpsController),
    );
    await _flushWidget(tester);
    await tester.ensureVisible(find.byKey(const Key('open-rps-history')));
    await tester.pumpAndSettle();

    expect(find.text('选择赛制和对手'), findsOneWidget);
    expect(find.bySemanticsIdentifier('open-match-history'), findsOneWidget);
    expect(find.bySemanticsIdentifier('open-rps-history'), findsOneWidget);
    final primaryBounds = tester.getRect(
      find.byKey(const Key('rps-choose-opponent')),
    );
    final historyBounds = tester.getRect(
      find.byKey(const Key('open-rps-history')),
    );
    expect(historyBounds.top, greaterThanOrEqualTo(primaryBounds.bottom));
    expect(tester.takeException(), isNull);

    rpsController.dispose();
    fixture.dispose();
  });
}

Widget _app(
  HomeController controller,
  String userId, {
  String nickname = '自己',
  bool dark = false,
  MatchHistoryApi? historyApi,
  RpsController? rpsController,
  HomeController? chineseCheckersController,
}) => MaterialApp(
  theme: GameboxTheme.light(),
  darkTheme: GameboxTheme.dark(),
  themeMode: dark ? ThemeMode.dark : ThemeMode.light,
  home: HomePage(
    controller: controller,
    currentUserId: userId,
    nickname: nickname,
    historyApi: historyApi ?? _FakeMatchHistoryApi(),
    rpsController: rpsController,
    chineseCheckersController: chineseCheckersController,
  ),
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
  final _FakeMatchHistoryApi historyApi = _FakeMatchHistoryApi();
  late final HomeController controller;

  void dispose() => controller.dispose();
}

final class _FakeMatchHistoryApi implements MatchHistoryApi {
  int calls = 0;
  final games = <MatchHistoryGame>[];

  @override
  Future<MatchHistoryPageData> fetchPage({
    MatchHistoryGame game = MatchHistoryGame.gomoku,
    String? cursor,
    int limit = 20,
  }) async {
    calls += 1;
    games.add(game);
    return const MatchHistoryPageData(
      statistics: MatchHistoryStatistics(
        validMatches: 0,
        wins: 0,
        losses: 0,
        draws: 0,
        winRate: 0,
      ),
      matches: [],
      nextCursor: null,
    );
  }
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
  List<GomokuOpponent> opponents = const [];
  ApiError? statusError;
  ApiError? cancelError;
  Future<void> Function(String matchId)? onCancel;
  Future<CreatedGomokuMatch> Function(String opponentId)? onCreate;
  int ticketCalls = 0;
  int opponentCalls = 0;
  int cancelCalls = 0;
  int createCalls = 0;
  int statusCalls = 0;

  @override
  Future<GomokuStatus> fetchStatus() async {
    statusCalls += 1;
    final error = statusError;
    if (error != null) throw error;
    return status;
  }

  @override
  Future<List<GomokuOpponent>> fetchOpponents() async {
    opponentCalls += 1;
    return opponents;
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
    cancelCalls += 1;
    final custom = onCancel;
    if (custom != null) {
      await custom(matchId);
      return;
    }
    final error = cancelError;
    if (error != null) throw error;
    status = const GomokuIdleStatus();
  }

  @override
  Future<CreatedGomokuMatch> createMatch(String opponentId) {
    createCalls += 1;
    return onCreate?.call(opponentId) ??
        Future<CreatedGomokuMatch>.error(StateError('unexpected create'));
  }
}

final class _FakeRpsApi implements RpsApi {
  const _FakeRpsApi({this.revision = 0, this.isIdle = false, this.statusError});

  final int revision;
  final bool isIdle;
  final ApiError? statusError;

  @override
  Future<RpsStatus> fetchStatus() async {
    if (statusError case final error?) throw error;
    return isIdle
        ? const RpsIdleStatus()
        : RpsActiveStatus(
            match: RpsActiveMatch(
              id: '33333333-3333-4333-8333-333333333333',
              opponent: GomokuOpponentIdentity(
                id: '22222222-2222-4222-8222-222222222222',
                nickname: '小猫',
              ),
              revision: revision,
              format: RpsFormat.bestOfThree,
            ),
          );
  }

  @override
  Future<void> cancelMatch(String matchId) async {}

  @override
  Future<CreatedRpsMatch> createMatch(String opponentId, RpsFormat format) =>
      Future.error(StateError('unexpected create'));

  @override
  Future<RpsLaunchTicket> createLaunchTicket(String matchId) =>
      Future.error(StateError('unexpected ticket'));

  @override
  Future<List<GomokuOpponent>> fetchOpponents() async => const [];
}
