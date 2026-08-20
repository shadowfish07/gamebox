import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/app.dart';
import 'package:gamebox/core/api/api_error.dart';
import 'package:gamebox/core/auth/session.dart';
import 'package:gamebox/core/auth/token_store.dart';
import 'package:gamebox/core/platform/game_launch_request.dart';
import 'package:gamebox/core/platform/game_launcher.dart';
import 'package:gamebox/features/auth/auth_api.dart';
import 'package:gamebox/features/auth/session_controller.dart';
import 'package:gamebox/features/gomoku/gomoku_models.dart';
import 'package:gamebox/features/gomoku/gomoku_repository.dart';
import 'package:gamebox/features/home/home_api.dart';
import 'package:gamebox/features/home/home_controller.dart';

void main() {
  final now = DateTime.utc(2026, 8, 20, 12);

  testWidgets('authenticated app mounts the injected playable Home flow', (
    tester,
  ) async {
    final fixture = await _Fixture.create(now);

    await tester.pumpWidget(
      GameboxApp(
        gameLauncher: fixture.launcher,
        sessionController: fixture.session,
        homeController: fixture.home,
      ),
    );
    await _flush(tester);

    expect(find.byKey(const Key('home-shell')), findsOneWidget);
    expect(find.byKey(const Key('game-gomoku')), findsOneWidget);
    expect(find.byKey(const Key('choose-opponent')), findsOneWidget);
    expect(fixture.api.statusCalls, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    fixture.dispose();
  });

  testWidgets('pause stops polling and resume refreshes Home immediately', (
    tester,
  ) async {
    final fixture = await _Fixture.create(now);
    await tester.pumpWidget(
      GameboxApp(
        gameLauncher: fixture.launcher,
        sessionController: fixture.session,
        homeController: fixture.home,
      ),
    );
    await _flush(tester);
    expect(fixture.api.statusCalls, 1);
    expect(fixture.scheduler.active, isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await _flush(tester);
    expect(fixture.scheduler.active, isFalse);
    fixture.scheduler.fireAllIncludingCancelled();
    await _flush(tester);
    expect(fixture.api.statusCalls, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _flush(tester);
    expect(fixture.api.statusCalls, 2);
    expect(fixture.scheduler.active, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    fixture.dispose();
  });

  testWidgets(
    'injected Home pauses on logout and resumes once on each reauthentication',
    (tester) async {
      final fixture = await _Fixture.create(now);
      await tester.pumpWidget(
        GameboxApp(
          gameLauncher: fixture.launcher,
          sessionController: fixture.session,
          homeController: fixture.home,
        ),
      );
      await _flush(tester);
      expect(fixture.api.statusCalls, 1);
      expect(fixture.scheduler.activeCount, 1);

      for (var cycle = 0; cycle < 2; cycle += 1) {
        fixture.authApi.rejectRefresh = true;
        expect(await fixture.session.refresh(), isFalse);
        await _flush(tester);

        expect(find.byKey(const Key('home-shell')), findsNothing);
        expect(fixture.scheduler.activeCount, 0);
        final callsWhileLoggedOut = fixture.api.statusCalls;
        fixture.scheduler.fireAllIncludingCancelled();
        await _flush(tester);
        expect(fixture.api.statusCalls, callsWhileLoggedOut);

        fixture.authApi.rejectRefresh = false;
        expect(await fixture.session.register('invite', '自己'), isNull);
        await _flush(tester);

        expect(find.byKey(const Key('home-shell')), findsOneWidget);
        expect(fixture.api.statusCalls, callsWhileLoggedOut + 1);
        expect(fixture.scheduler.activeCount, 1);
      }

      expect(fixture.scheduler.calls.length, 3);
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.dispose();
    },
  );
}

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

final class _Fixture {
  _Fixture({
    required this.session,
    required this.home,
    required this.api,
    required this.scheduler,
    required this.launcher,
    required this.authApi,
  });

  static Future<_Fixture> create(DateTime now) async {
    final authApi = _FakeAuthApi(now);
    final session = SessionController(
      authApi: authApi,
      tokenStore: _MemoryTokenStore('refresh-zero'),
      now: () => now,
    );
    await session.restore();
    final api = _FakeHomeApi();
    final scheduler = _FakeScheduler();
    final launcher = _FakeLauncher();
    final home = HomeController(
      repository: GomokuRepository(
        api: api,
        gameLauncher: launcher,
        apiBaseUri: Uri.parse('https://gamebox.test'),
        now: () => now,
      ),
      scheduler: scheduler,
      now: () => now,
    );
    return _Fixture(
      session: session,
      home: home,
      api: api,
      scheduler: scheduler,
      launcher: launcher,
      authApi: authApi,
    );
  }

  final SessionController session;
  final HomeController home;
  final _FakeHomeApi api;
  final _FakeScheduler scheduler;
  final _FakeLauncher launcher;
  final _FakeAuthApi authApi;

  void dispose() {
    home.dispose();
    session.dispose();
  }
}

final class _FakeScheduler implements HomePollScheduler {
  final List<_FakeCall> calls = [];

  bool get active => calls.any((call) => !call.cancelled);
  int get activeCount => calls.where((call) => !call.cancelled).length;

  @override
  HomeScheduledCall schedulePeriodic(
    Duration period,
    void Function() callback,
  ) {
    final call = _FakeCall(callback);
    calls.add(call);
    return call;
  }

  void fireAllIncludingCancelled() {
    for (final call in List<_FakeCall>.of(calls)) {
      call.callback();
    }
  }
}

final class _FakeCall implements HomeScheduledCall {
  _FakeCall(this.callback);

  final void Function() callback;
  bool cancelled = false;

  @override
  void cancel() => cancelled = true;
}

final class _FakeLauncher implements GameLauncher {
  @override
  Future<void> launch(GameLaunchRequest request) async {}

  @override
  Future<void> launchHostSmoke() async {}
}

final class _FakeHomeApi implements HomeApi {
  int statusCalls = 0;

  @override
  Future<GomokuStatus> fetchStatus() async {
    statusCalls += 1;
    return const GomokuIdleStatus();
  }

  @override
  Future<List<GomokuOpponent>> fetchOpponents() async => const [];

  @override
  Future<void> cancelMatch(String matchId) async {}

  @override
  Future<CreatedGomokuMatch> createMatch(String opponentId) =>
      Future<CreatedGomokuMatch>.error(StateError('unexpected create'));

  @override
  Future<GomokuLaunchTicket> createLaunchTicket(String matchId) =>
      Future<GomokuLaunchTicket>.error(StateError('unexpected ticket'));
}

final class _FakeAuthApi implements AuthApi {
  _FakeAuthApi(this.now);

  final DateTime now;
  bool rejectRefresh = false;

  @override
  Future<Session> refresh(String refreshToken) async {
    if (rejectRefresh) {
      throw const ApiError(code: 'unauthorized', message: '登录已失效');
    }
    return _session();
  }

  @override
  Future<Session> register(String inviteCode, String nickname) async =>
      _session();

  Session _session() => Session(
    user: const SessionUser(
      id: '11111111-1111-4111-8111-111111111111',
      nickname: '自己',
    ),
    accessToken: 'access-token',
    accessExpiresAt: now.add(const Duration(minutes: 15)),
    refreshToken: 'refresh-token',
    refreshExpiresAt: now.add(const Duration(days: 30)),
  );
}

final class _MemoryTokenStore implements TokenStore {
  _MemoryTokenStore(this.value);

  String? value;

  @override
  Future<void> deleteRefreshToken() async => value = null;

  @override
  Future<String?> readRefreshToken() async => value;

  @override
  Future<void> writeRefreshToken(String refreshToken) async =>
      value = refreshToken;
}
