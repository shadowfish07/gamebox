import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/app.dart';
import 'package:gamebox/core/api/api_error.dart';
import 'package:gamebox/core/auth/session.dart';
import 'package:gamebox/core/auth/token_store.dart';
import 'package:gamebox/core/platform/game_launch_request.dart';
import 'package:gamebox/core/platform/game_launcher.dart';
import 'package:gamebox/core/profile/app_profile.dart';
import 'package:gamebox/core/profile/app_profile_store.dart';
import 'package:gamebox/core/profile/nickname_rules.dart';
import 'package:gamebox/features/auth/auth_api.dart';
import 'package:gamebox/features/auth/registration_page.dart';
import 'package:gamebox/features/auth/session_controller.dart';
import 'package:gamebox/features/profile/profile_controller.dart';

void main() {
  final now = DateTime.utc(2026, 8, 20, 12);

  testWidgets('registration controls expose stable semantics labels', (
    tester,
  ) async {
    final fixture = await _RegistrationFixture.create(now);
    await tester.pumpWidget(
      MaterialApp(
        home: RegistrationPage(
          controller: fixture.controller,
          nickname: '小鱼',
          onEditNickname: () {},
        ),
      ),
    );

    expect(
      tester.getSemantics(find.byKey(const Key('invite-code'))),
      matchesSemantics(label: 'invite-code', isTextField: true),
    );
    expect(find.byKey(const Key('nickname')), findsNothing);
    expect(find.text('小鱼'), findsOneWidget);
    expect(find.byKey(const Key('edit-nickname')), findsOneWidget);
    expect(
      tester.getSemantics(find.byKey(const Key('register'))),
      matchesSemantics(
        label: 'register',
        isButton: true,
        isEnabled: true,
        hasEnabledState: true,
        hasTapAction: true,
      ),
    );
  });

  testWidgets('submitting disables the button and prevents double submit', (
    tester,
  ) async {
    final pending = Completer<Session>();
    final fixture = await _RegistrationFixture.create(now)
      ..api.onRegister = (_, _) => pending.future;
    await tester.pumpWidget(
      MaterialApp(
        home: RegistrationPage(
          controller: fixture.controller,
          nickname: '小鱼',
          onEditNickname: () {},
        ),
      ),
    );
    await _enter(tester, const Key('invite-code'), 'invite-one');

    await tester.tap(find.byKey(const Key('register')));
    await tester.pump();

    expect(fixture.controller.status, SessionStatus.submitting);
    expect(
      tester.getSemantics(find.byKey(const Key('register'))),
      matchesSemantics(
        label: 'register',
        isButton: true,
        isEnabled: false,
        hasEnabledState: true,
      ),
    );
    await tester.tap(find.byKey(const Key('register')), warnIfMissed: false);
    await tester.pump();
    expect(fixture.api.registerCalls, 1);

    pending.complete(_session(now));
    await tester.pump();
  });

  for (final testCase in const [
    (
      code: 'invite_invalid',
      serverMessage: 'server invite detail',
      expected: '邀请码无效或已使用',
    ),
    (
      code: 'nickname_taken',
      serverMessage: 'server nickname detail',
      expected: '昵称已被使用',
    ),
  ]) {
    testWidgets('${testCase.code} uses a stable Chinese error', (tester) async {
      final fixture = await _RegistrationFixture.create(now)
        ..api.onRegister = (_, _) => Future<Session>.error(
          ApiError(code: testCase.code, message: testCase.serverMessage),
        );
      await tester.pumpWidget(
        MaterialApp(
          home: RegistrationPage(
            controller: fixture.controller,
            nickname: '小鱼',
            onEditNickname: () {},
          ),
        ),
      );
      await _enter(tester, const Key('invite-code'), 'invite-one');

      await tester.tap(find.byKey(const Key('register')));
      await tester.pump();

      expect(find.text(testCase.expected), findsOneWidget);
      expect(find.text(testCase.serverMessage), findsNothing);
    });
  }

  testWidgets('unknown registration errors never expose server diagnostics', (
    tester,
  ) async {
    const secret = 'raw-server-token-and-database-detail';
    final fixture = await _RegistrationFixture.create(now)
      ..api.onRegister = (_, _) => Future<Session>.error(
        const ApiError(code: 'future_error', message: secret),
      );
    await tester.pumpWidget(
      MaterialApp(
        home: RegistrationPage(
          controller: fixture.controller,
          nickname: '小鱼',
          onEditNickname: () {},
        ),
      ),
    );
    await _enter(tester, const Key('invite-code'), 'invite-one');

    await tester.tap(find.byKey(const Key('register')));
    await tester.pump();

    expect(find.text('注册失败，请稍后重试'), findsOneWidget);
    expect(find.textContaining(secret), findsNothing);
  });

  testWidgets('successful registration enters the Home shell', (tester) async {
    final fixture = await _RegistrationFixture.create(now)
      ..api.onRegister = (_, _) async => _session(now);
    await tester.pumpWidget(
      GameboxApp(
        gameLauncher: _NoopGameLauncher(),
        sessionController: fixture.controller,
        profileController: fixture.profile,
      ),
    );
    await tester.pump();
    await _enter(tester, const Key('invite-code'), 'invite-one');

    await tester.tap(find.byKey(const Key('register')));
    await tester.pump();

    expect(fixture.api.lastInviteCode, 'invite-one');
    expect(fixture.api.lastNickname, '小鱼');
    expect(find.byKey(const Key('home-shell')), findsOneWidget);
    expect(find.text('你好，小鱼'), findsOneWidget);
  });

  testWidgets(
    'temporary auto-login failure offers retry instead of registration',
    (tester) async {
      final now = DateTime.utc(2026, 8, 20, 12);
      final api = _FakeAuthApi()
        ..onRefresh = (_) => Future<Session>.error(
          const ApiError(
            code: 'network_error',
            message: 'temporary safe failure',
          ),
        );
      final store = _MemoryTokenStore('refresh-preserved');
      final controller = SessionController(
        authApi: api,
        tokenStore: store,
        now: () => now,
      );
      await controller.restore();
      final profile = await _readyProfile();
      await tester.pumpWidget(
        GameboxApp(
          gameLauncher: _NoopGameLauncher(),
          sessionController: controller,
          profileController: profile,
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('invite-code')), findsNothing);
      expect(find.byKey(const Key('register')), findsNothing);
      expect(find.byKey(const Key('retry-session')), findsOneWidget);
      api.onRefresh = (_) async => _session(now);

      await tester.tap(find.byKey(const Key('retry-session')));
      await tester.pump();

      expect(find.byKey(const Key('home-shell')), findsOneWidget);
    },
  );

  testWidgets(
    'credential cleanup stays inside Home and hides registration until complete',
    (tester) async {
      final api = _FakeAuthApi()..onRefresh = (_) async => _session(now);
      final deletion = Completer<void>();
      final store = _MemoryTokenStore('refresh-old')
        ..onDelete = () => deletion.future;
      final controller = SessionController(
        authApi: api,
        tokenStore: store,
        now: () => now,
      );
      await controller.restore();
      final profile = await _readyProfile();
      await tester.pumpWidget(
        GameboxApp(
          gameLauncher: _NoopGameLauncher(),
          sessionController: controller,
          profileController: profile,
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('home-shell')), findsOneWidget);
      api.onRefresh = (_) => Future<Session>.error(
        const ApiError(code: 'unauthorized', message: '身份验证失败'),
      );

      final refresh = controller.refresh('access-token');
      await store.deleteStarted.future;
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('home-shell')), findsOneWidget);
      expect(
        find.byKey(const Key('credential-cleanup-pending')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('invite-code')), findsNothing);
      expect(find.byKey(const Key('register')), findsNothing);
      expect(find.byKey(const Key('retry-session')), findsNothing);
      await tester.pump();
      expect(tester.takeException(), isNull);

      deletion.complete();
      await refresh;
      await tester.pump();

      expect(find.byKey(const Key('credential-cleanup-pending')), findsNothing);
      expect(find.byKey(const Key('invite-code')), findsOneWidget);
      expect(find.byKey(const Key('register')), findsOneWidget);
    },
  );

  testWidgets('failed credential cleanup exposes only its safe retry', (
    tester,
  ) async {
    final api = _FakeAuthApi()..onRefresh = (_) async => _session(now);
    final store = _MemoryTokenStore('refresh-old');
    final controller = SessionController(
      authApi: api,
      tokenStore: store,
      now: () => now,
    );
    await controller.restore();
    store.deleteError = PlatformException(
      code: 'unavailable',
      message: 'private-platform-detail',
    );
    api.onRefresh = (_) => Future<Session>.error(
      const ApiError(code: 'unauthorized', message: '身份验证失败'),
    );
    await controller.refresh('access-token');
    final profile = await _readyProfile();
    await tester.pumpWidget(
      GameboxApp(
        gameLauncher: _NoopGameLauncher(),
        sessionController: controller,
        profileController: profile,
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('retry-credential-cleanup')), findsOneWidget);
    expect(find.byKey(const Key('home-shell')), findsOneWidget);
    expect(find.byKey(const Key('register')), findsNothing);
    expect(find.textContaining('private-platform-detail'), findsNothing);

    final deletion = Completer<void>();
    store.deleteError = null;
    store.onDelete = () => deletion.future;
    store.deleteStarted = Completer<void>();
    await tester.tap(find.byKey(const Key('retry-credential-cleanup')));
    await store.deleteStarted.future;
    await tester.pump();

    expect(find.byKey(const Key('credential-cleanup-pending')), findsOneWidget);
    expect(find.byKey(const Key('register')), findsNothing);

    deletion.complete();
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('invite-code')), findsOneWidget);
    expect(find.byKey(const Key('register')), findsOneWidget);
  });
}

Future<void> _enter(WidgetTester tester, Key semanticsKey, String value) async {
  final field = find.descendant(
    of: find.byKey(semanticsKey),
    matching: find.byType(TextField),
  );
  await tester.enterText(field, value);
}

Session _session(DateTime now) => Session(
  user: const SessionUser(
    id: '11111111-1111-4111-8111-111111111111',
    nickname: '小鱼',
  ),
  accessToken: 'access-token',
  accessExpiresAt: now.add(const Duration(minutes: 15)),
  refreshToken: 'refresh-token',
  refreshExpiresAt: now.add(const Duration(days: 30)),
);

final class _RegistrationFixture {
  _RegistrationFixture(this.api, this.controller, this.profile);

  static Future<_RegistrationFixture> create(DateTime now) async {
    final api = _FakeAuthApi();
    final controller = SessionController(
      authApi: api,
      tokenStore: _MemoryTokenStore(),
      now: () => now,
    );
    await controller.restore();
    return _RegistrationFixture(api, controller, await _readyProfile());
  }

  final _FakeAuthApi api;
  final SessionController controller;
  final ProfileController profile;
}

Future<ProfileController> _readyProfile() async {
  final controller = ProfileController(
    store: _MemoryProfileStore(
      const AppProfile(
        schemaVersion: 1,
        nickname: '小鱼',
        syncState: ProfileSyncState.pending,
      ),
    ),
    nicknameRules: const _NicknameRules(),
  );
  await controller.load();
  return controller;
}

final class _MemoryProfileStore implements AppProfileStore {
  _MemoryProfileStore(this.value);

  AppProfile? value;

  @override
  Future<AppProfile?> read() async => value;

  @override
  Future<void> write(AppProfile profile) async => value = profile;
}

final class _NicknameRules implements NicknameRules {
  const _NicknameRules();

  @override
  Future<String> normalize(String raw) async => raw.trim();
}

final class _FakeAuthApi implements AuthApi {
  Future<Session> Function(String inviteCode, String nickname)? onRegister;
  Future<Session> Function(String refreshToken)? onRefresh;
  int registerCalls = 0;
  String? lastInviteCode;
  String? lastNickname;

  @override
  Future<Session> refresh(String refreshToken) =>
      onRefresh?.call(refreshToken) ??
      Future<Session>.error(StateError('unexpected refresh'));

  @override
  Future<Session> register(String inviteCode, String nickname) {
    registerCalls += 1;
    lastInviteCode = inviteCode;
    lastNickname = nickname;
    return onRegister?.call(inviteCode, nickname) ??
        Future<Session>.error(StateError('unexpected registration'));
  }
}

final class _MemoryTokenStore implements TokenStore {
  _MemoryTokenStore([this.value]);

  String? value;
  Object? deleteError;
  Future<void> Function()? onDelete;
  Completer<void> deleteStarted = Completer<void>();

  @override
  Future<void> deleteRefreshToken() async {
    if (!deleteStarted.isCompleted) {
      deleteStarted.complete();
    }
    await onDelete?.call();
    if (deleteError != null) {
      throw deleteError!;
    }
    value = null;
  }

  @override
  Future<String?> readRefreshToken() async => value;

  @override
  Future<void> writeRefreshToken(String refreshToken) async {
    value = refreshToken;
  }
}

final class _NoopGameLauncher implements GameLauncher {
  @override
  Future<void> launch(GameLaunchRequest request) async {}

  @override
  Future<void> launchHostSmoke() async {}
}
