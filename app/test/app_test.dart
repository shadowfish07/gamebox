import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/app.dart';
import 'package:gamebox/core/auth/session.dart';
import 'package:gamebox/core/auth/token_store.dart';
import 'package:gamebox/core/platform/game_launch_request.dart';
import 'package:gamebox/core/platform/game_launcher.dart';
import 'package:gamebox/core/profile/app_profile.dart';
import 'package:gamebox/core/profile/app_profile_store.dart';
import 'package:gamebox/core/profile/nickname_rules.dart';
import 'package:gamebox/features/auth/auth_api.dart';
import 'package:gamebox/features/auth/session_controller.dart';
import 'package:gamebox/features/profile/profile_controller.dart';

void main() {
  testWidgets('first launch nickname setup does not wait for public restore', (
    tester,
  ) async {
    final refreshRead = Completer<String?>();
    final controller = SessionController(
      authApi: _UnusedAuthApi(),
      tokenStore: _PendingTokenStore(refreshRead),
    );
    final profile = ProfileController(
      store: _MemoryProfileStore(),
      nicknameRules: const _FixtureNicknameRules(),
    );
    await tester.pumpWidget(
      GameboxApp(
        gameLauncher: _FakeGameLauncher(),
        sessionController: controller,
        profileController: profile,
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('local-nickname')), findsOneWidget);
    expect(controller.status, SessionStatus.restoring);
    expect(find.byKey(const Key('host-smoke.launch')), findsNothing);
    refreshRead.complete(null);
    await tester.pump();
  });

  testWidgets('local commit reaches home while public restore stays pending', (
    tester,
  ) async {
    final refreshRead = Completer<String?>();
    final session = SessionController(
      authApi: _UnusedAuthApi(),
      tokenStore: _PendingTokenStore(refreshRead),
    );
    final profile = ProfileController(
      store: _MemoryProfileStore(),
      nicknameRules: const _FixtureNicknameRules(),
    );
    await tester.pumpWidget(
      GameboxApp(
        gameLauncher: _FakeGameLauncher(),
        sessionController: session,
        profileController: profile,
      ),
    );
    await tester.pump();
    await tester.enterText(find.byType(TextField), '本地玩家');
    await tester.tap(find.byKey(const Key('save-nickname')));
    await tester.pump();

    expect(find.byKey(const Key('home-shell')), findsOneWidget);
    expect(
      tester.getSemantics(find.byKey(const Key('home-shell'))).label,
      'home-shell',
    );
    expect(find.text('你好，本地玩家'), findsOneWidget);
    expect(find.byKey(const Key('public-session-restoring')), findsOneWidget);
    refreshRead.complete(null);
    await tester.pump();
  });

  testWidgets('successful old session migrates before showing setup', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 8, 24, 12);
    final session = SessionController(
      authApi: _RestoredAuthApi(now),
      tokenStore: _ValueTokenStore('refresh-old'),
      now: () => now,
    );
    final profile = ProfileController(
      store: _MemoryProfileStore(),
      nicknameRules: const _FixtureNicknameRules(),
    );

    await tester.pumpWidget(
      GameboxApp(
        gameLauncher: _FakeGameLauncher(),
        sessionController: session,
        profileController: profile,
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('nickname-page')), findsNothing);
    expect(find.byKey(const Key('home-shell')), findsOneWidget);
    expect(find.text('你好，旧公服玩家'), findsOneWidget);
    expect(profile.profile?.syncState, ProfileSyncState.synced);
  });

  testWidgets('corrupt profile blocks migration and offers profile retry', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 8, 24, 12);
    final session = SessionController(
      authApi: _RestoredAuthApi(now),
      tokenStore: _ValueTokenStore('refresh-old'),
      now: () => now,
    );
    final store = _MemoryProfileStore()
      ..readError = const ProfileLoadFailure.corrupt();
    final profile = ProfileController(
      store: store,
      nicknameRules: const _FixtureNicknameRules(),
    );

    await tester.pumpWidget(
      GameboxApp(
        gameLauncher: _FakeGameLauncher(),
        sessionController: session,
        profileController: profile,
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('profile-load-retry')), findsOneWidget);
    expect(find.byKey(const Key('nickname-page')), findsNothing);
    expect(store.writes, isEmpty);
  });

  testWidgets(
    'editing an existing profile keeps its route through atomic save',
    (tester) async {
      final session = SessionController(
        authApi: _UnusedAuthApi(),
        tokenStore: _ValueTokenStore(null),
      );
      final store = _MemoryProfileStore()
        ..value = const AppProfile(
          schemaVersion: 1,
          nickname: '旧昵称',
          syncState: ProfileSyncState.pending,
        );
      final profile = ProfileController(
        store: store,
        nicknameRules: const _FixtureNicknameRules(),
      );
      await tester.pumpWidget(
        GameboxApp(
          gameLauncher: _FakeGameLauncher(),
          sessionController: session,
          profileController: profile,
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(profile.status, ProfileStatus.ready);
      expect(find.byKey(const Key('home-shell')), findsOneWidget);
      await tester.tap(find.byKey(const Key('edit-local-nickname')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('nickname-page')), findsOneWidget);
      final writeBarrier = Completer<void>();
      store.writeBarrier = writeBarrier;
      await tester.enterText(find.byType(TextField), '新昵称');

      await tester.tap(find.byKey(const Key('save-nickname')));
      await tester.pump();

      expect(profile.status, ProfileStatus.saving);
      expect(find.byKey(const Key('nickname-page')), findsOneWidget);
      expect(find.text('编辑昵称'), findsOneWidget);

      writeBarrier.complete();
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('nickname-page')), findsNothing);
      expect(find.byKey(const Key('home-shell')), findsOneWidget);
      expect(find.text('你好，新昵称'), findsOneWidget);
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

final class _UnusedAuthApi implements AuthApi {
  @override
  Future<Session> refresh(String refreshToken) =>
      Future<Session>.error(StateError('unexpected refresh'));

  @override
  Future<Session> register(String inviteCode, String nickname) =>
      Future<Session>.error(StateError('unexpected registration'));
}

final class _PendingTokenStore implements TokenStore {
  _PendingTokenStore(this.read);

  final Completer<String?> read;

  @override
  Future<void> deleteRefreshToken() async {}

  @override
  Future<String?> readRefreshToken() => read.future;

  @override
  Future<void> writeRefreshToken(String refreshToken) async {}
}

final class _ValueTokenStore implements TokenStore {
  _ValueTokenStore(this.value);

  String? value;

  @override
  Future<void> deleteRefreshToken() async => value = null;

  @override
  Future<String?> readRefreshToken() async => value;

  @override
  Future<void> writeRefreshToken(String refreshToken) async =>
      value = refreshToken;
}

final class _RestoredAuthApi implements AuthApi {
  _RestoredAuthApi(this.now);

  final DateTime now;

  @override
  Future<Session> refresh(String refreshToken) async => Session(
    user: const SessionUser(
      id: '11111111-1111-4111-8111-111111111111',
      nickname: '旧公服玩家',
    ),
    accessToken: 'access-new',
    accessExpiresAt: now.add(const Duration(minutes: 15)),
    refreshToken: 'refresh-new',
    refreshExpiresAt: now.add(const Duration(days: 30)),
  );

  @override
  Future<Session> register(String inviteCode, String nickname) =>
      Future<Session>.error(StateError('unexpected registration'));
}

final class _MemoryProfileStore implements AppProfileStore {
  AppProfile? value;
  Object? readError;
  Completer<void>? writeBarrier;
  final writes = <AppProfile>[];

  @override
  Future<AppProfile?> read() async {
    if (readError case final error?) throw error;
    return value;
  }

  @override
  Future<void> write(AppProfile profile) async {
    writes.add(profile);
    await writeBarrier?.future;
    value = profile;
  }
}

final class _FixtureNicknameRules implements NicknameRules {
  const _FixtureNicknameRules();

  @override
  Future<String> normalize(String raw) async => raw.trim();
}
