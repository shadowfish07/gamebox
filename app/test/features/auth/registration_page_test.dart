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
import 'package:gamebox/design_system/components/gamebox_pending_button.dart';
import 'package:gamebox/design_system/gamebox_theme.dart';
import 'package:gamebox/design_system/generated/gamebox_tokens.g.dart';
import 'package:gamebox/features/auth/auth_api.dart';
import 'package:gamebox/features/auth/registration_page.dart';
import 'package:gamebox/features/auth/session_controller.dart';

void main() {
  final now = DateTime.utc(2026, 8, 20, 12);

  testWidgets('GameboxApp follows system dark mode with the fixed scheme', (
    tester,
  ) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final fixture = await _RegistrationFixture.create(now);

    await tester.pumpWidget(
      GameboxApp(
        gameLauncher: _NoopGameLauncher(),
        sessionController: fixture.controller,
      ),
    );
    await tester.pump();

    final context = tester.element(find.byType(RegistrationPage));
    expect(Theme.of(context).brightness, Brightness.dark);
    expect(Theme.of(context).colorScheme, GameboxTokens.darkColorScheme);
  });

  for (final size in const [Size(360, 800), Size(412, 915)]) {
    testWidgets('uses the branded field-owned form at $size', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      final fixture = await _RegistrationFixture.create(now);
      await tester.pumpWidget(
        MaterialApp(
          theme: GameboxTheme.dark(),
          home: RegistrationPage(controller: fixture.controller),
        ),
      );

      expect(find.text('加入 Gamebox'), findsOneWidget);
      expect(find.text('输入邀请码，和朋友开始一局游戏'), findsOneWidget);
      expect(find.byIcon(Icons.sports_esports_outlined), findsOneWidget);
      expect(find.byType(GameboxPendingButton), findsOneWidget);
      expect(
        Theme.of(tester.element(find.byType(RegistrationPage))).brightness,
        Brightness.dark,
      );

      await tester.tap(find.byKey(const Key('register')));
      await tester.pump();
      expect(
        tester
            .widget<TextField>(
              find.descendant(
                of: find.byKey(const Key('invite-code')),
                matching: find.byType(TextField),
              ),
            )
            .decoration
            ?.errorText,
        '请输入邀请码',
      );

      await _enter(tester, const Key('invite-code'), 'invite-one');
      await _enter(tester, const Key('nickname'), '鱼');
      await tester.tap(find.byKey(const Key('register')));
      await tester.pump();
      expect(
        tester
            .widget<TextField>(
              find.descendant(
                of: find.byKey(const Key('nickname')),
                matching: find.byType(TextField),
              ),
            )
            .decoration
            ?.errorText,
        '昵称至少需要 2 个字符',
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final size in const [Size(360, 800), Size(412, 915)]) {
    testWidgets(
      'retains long valid input after a safe service failure at $size',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.reset);
        const invite = 'invite-code-with-long-safe-value-20260822';
        const nickname = 'LongNickname1234';
        const rawServerMessage = 'private-storage-provider-detail';
        const safeMessage = '无法安全保存登录信息，请申请新的邀请码';
        final fixture = await _RegistrationFixture.create(now)
          ..api.onRegister = (_, _) => Future<Session>.error(
            const ApiError(code: 'storage_error', message: rawServerMessage),
          );
        await tester.pumpWidget(
          MaterialApp(
            theme: GameboxTheme.light(),
            home: RegistrationPage(controller: fixture.controller),
          ),
        );
        await _enter(tester, const Key('invite-code'), invite);
        await _enter(tester, const Key('nickname'), nickname);

        await tester.tap(find.byKey(const Key('register')));
        await tester.pump();

        final errorText = find.text(safeMessage);
        final errorRegion = find.ancestor(
          of: errorText,
          matching: find.byType(SizedBox),
        );
        expect(errorText, findsOneWidget);
        expect(find.textContaining(rawServerMessage), findsNothing);
        expect(errorRegion, findsOneWidget);
        expect(
          tester.getSize(errorRegion).height,
          GameboxTokens.components.minimumTouchTarget,
        );
        expect(
          _field(tester, const Key('invite-code')).controller?.text,
          invite,
        );
        expect(
          _field(tester, const Key('nickname')).controller?.text,
          nickname,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'register button stays within the visible viewport when the keyboard is open',
    (tester) async {
      // Match the on-device E2E condition (1080x2400 @ DPR 3.5): the previous
      // layout put register as the last lazy ListView child, so opening the
      // keyboard shrank the viewport below the button and Android's a11y tree
      // (which only exposes viewport-visible nodes) lost it entirely.
      tester.view.devicePixelRatio = 3.5;
      tester.view.physicalSize = const Size(1080, 2400);
      addTearDown(tester.view.reset);
      final fixture = await _RegistrationFixture.create(now);
      await tester.pumpWidget(
        MaterialApp(home: RegistrationPage(controller: fixture.controller)),
      );
      await tester.pump();

      // Focus the nickname field, as the E2E harness does before tapping
      // register, then open the keyboard.
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('nickname')),
          matching: find.byType(TextField),
        ),
      );
      await tester.pump();
      tester.view.viewInsets = FakeViewPadding(bottom: 1050); // ~300 logical
      addTearDown(tester.view.resetViewInsets);
      await tester.pump();

      final register = find.byKey(const Key('register'));
      expect(
        register,
        findsOneWidget,
        reason: 'register must survive the keyboard shrinking the viewport',
      );
      final registerRect = tester.getRect(register);
      final logicalHeight = tester.view.physicalSize.height /
          tester.view.devicePixelRatio;
      final logicalInset = tester.view.viewInsets.bottom /
          tester.view.devicePixelRatio;
      expect(
        registerRect.bottom,
        lessThanOrEqualTo(logicalHeight - logicalInset),
        reason: 'register must stay tappable above the keyboard',
      );
    },
  );

  testWidgets('registration controls expose stable semantics labels', (
    tester,
  ) async {
    final fixture = await _RegistrationFixture.create(now);
    await tester.pumpWidget(
      MaterialApp(home: RegistrationPage(controller: fixture.controller)),
    );

    expect(
      tester.getSemantics(find.byKey(const Key('invite-code'))),
      matchesSemantics(label: 'invite-code', isTextField: true),
    );
    expect(
      tester.getSemantics(find.byKey(const Key('nickname'))),
      matchesSemantics(label: 'nickname', isTextField: true),
    );
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

  testWidgets('nickname shorter than two runes is rejected locally', (
    tester,
  ) async {
    final fixture = await _RegistrationFixture.create(now);
    await tester.pumpWidget(
      MaterialApp(home: RegistrationPage(controller: fixture.controller)),
    );
    await _enter(tester, const Key('invite-code'), 'invite-one');
    await _enter(tester, const Key('nickname'), '鱼');

    await tester.tap(find.byKey(const Key('register')));
    await tester.pump();

    expect(find.text('昵称至少需要 2 个字符'), findsOneWidget);
    expect(fixture.api.registerCalls, 0);
  });

  testWidgets('nickname longer than sixteen runes is rejected locally', (
    tester,
  ) async {
    final fixture = await _RegistrationFixture.create(now);
    await tester.pumpWidget(
      MaterialApp(home: RegistrationPage(controller: fixture.controller)),
    );
    await _enter(tester, const Key('invite-code'), 'invite-one');
    await _enter(tester, const Key('nickname'), List.filled(17, '鱼').join());

    await tester.tap(find.byKey(const Key('register')));
    await tester.pump();

    expect(find.text('昵称不能超过 16 个字符'), findsOneWidget);
    expect(fixture.api.registerCalls, 0);
  });

  testWidgets('submitting disables the button and prevents double submit', (
    tester,
  ) async {
    final pending = Completer<Session>();
    final fixture = await _RegistrationFixture.create(now)
      ..api.onRegister = (_, _) => pending.future;
    await tester.pumpWidget(
      MaterialApp(home: RegistrationPage(controller: fixture.controller)),
    );
    await _enter(tester, const Key('invite-code'), 'invite-one');
    await _enter(tester, const Key('nickname'), '小鱼');

    await tester.tap(find.byKey(const Key('register')));
    await tester.pump();

    expect(fixture.controller.status, SessionStatus.submitting);
    expect(find.byType(GameboxPendingButton), findsOneWidget);
    expect(find.text('正在注册'), findsOneWidget);
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
        MaterialApp(home: RegistrationPage(controller: fixture.controller)),
      );
      await _enter(tester, const Key('invite-code'), 'invite-one');
      await _enter(tester, const Key('nickname'), '小鱼');

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
      MaterialApp(home: RegistrationPage(controller: fixture.controller)),
    );
    await _enter(tester, const Key('invite-code'), 'invite-one');
    await _enter(tester, const Key('nickname'), '小鱼');

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
      ),
    );
    await tester.pump();
    await _enter(tester, const Key('invite-code'), 'invite-one');
    await _enter(tester, const Key('nickname'), '小鱼');

    await tester.tap(find.byKey(const Key('register')));
    await tester.pump();

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
      await tester.pumpWidget(
        GameboxApp(
          gameLauncher: _NoopGameLauncher(),
          sessionController: controller,
        ),
      );

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
    'credential cleanup immediately hides Home and registration until complete',
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
      await tester.pumpWidget(
        GameboxApp(
          gameLauncher: _NoopGameLauncher(),
          sessionController: controller,
        ),
      );
      expect(find.byKey(const Key('home-shell')), findsOneWidget);
      api.onRefresh = (_) => Future<Session>.error(
        const ApiError(code: 'unauthorized', message: '身份验证失败'),
      );

      final refresh = controller.refresh('access-token');
      await store.deleteStarted.future;
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('home-shell')), findsNothing);
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
    await tester.pumpWidget(
      GameboxApp(
        gameLauncher: _NoopGameLauncher(),
        sessionController: controller,
      ),
    );

    expect(find.byKey(const Key('retry-credential-cleanup')), findsOneWidget);
    expect(find.byKey(const Key('home-shell')), findsNothing);
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

TextField _field(WidgetTester tester, Key semanticsKey) =>
    tester.widget<TextField>(
      find.descendant(
        of: find.byKey(semanticsKey),
        matching: find.byType(TextField),
      ),
    );

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
  _RegistrationFixture(this.api, this.controller);

  static Future<_RegistrationFixture> create(DateTime now) async {
    final api = _FakeAuthApi();
    final controller = SessionController(
      authApi: api,
      tokenStore: _MemoryTokenStore(),
      now: () => now,
    );
    await controller.restore();
    return _RegistrationFixture(api, controller);
  }

  final _FakeAuthApi api;
  final SessionController controller;
}

final class _FakeAuthApi implements AuthApi {
  Future<Session> Function(String inviteCode, String nickname)? onRegister;
  Future<Session> Function(String refreshToken)? onRefresh;
  int registerCalls = 0;

  @override
  Future<Session> refresh(String refreshToken) =>
      onRefresh?.call(refreshToken) ??
      Future<Session>.error(StateError('unexpected refresh'));

  @override
  Future<Session> register(String inviteCode, String nickname) {
    registerCalls += 1;
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
