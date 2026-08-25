import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/app.dart';
import 'package:gamebox/core/api/api_client.dart';
import 'package:gamebox/core/auth/session.dart';
import 'package:gamebox/core/auth/token_store.dart';
import 'package:gamebox/core/lan/lan_models.dart';
import 'package:gamebox/core/platform/game_launch_request.dart';
import 'package:gamebox/core/platform/game_launcher.dart';
import 'package:gamebox/core/profile/app_profile.dart';
import 'package:gamebox/core/profile/app_profile_store.dart';
import 'package:gamebox/core/profile/nickname_rules.dart';
import 'package:gamebox/features/auth/auth_api.dart';
import 'package:gamebox/features/auth/session_controller.dart';
import 'package:gamebox/features/gomoku/gomoku_models.dart';
import 'package:gamebox/features/gomoku/gomoku_repository.dart';
import 'package:gamebox/features/home/home_api.dart';
import 'package:gamebox/features/home/home_controller.dart';
import 'package:gamebox/features/profile/profile_controller.dart';
import 'package:integration_test/integration_test.dart';

const _aliceId = '11111111-1111-4111-8111-111111111111';
const _bobId = '22222222-2222-4222-8222-222222222222';
const _matchId = '33333333-3333-4333-8333-333333333333';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('registration controls expose stable tappable identifiers', (
    tester,
  ) async {
    final fixture = _Fixture.unauthenticated();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.dispose();
    });

    await tester.pumpWidget(fixture.app());
    await _flush(tester);

    final nickname = find.bySemanticsIdentifier('local-nickname');
    expect(nickname, findsOneWidget);
    expect(
      tester.getSemantics(nickname),
      isSemantics(identifier: 'local-nickname', isTextField: true),
    );
    await tester.enterText(nickname, 'Alice');
    await tester.tap(find.bySemanticsIdentifier('save-nickname'));
    await _flush(tester);

    final invite = find.bySemanticsIdentifier('invite-code');
    final register = find.bySemanticsIdentifier('register');
    expect(invite, findsOneWidget);
    expect(register, findsOneWidget);
    expect(
      tester.getSemantics(invite),
      isSemantics(identifier: 'invite-code', isTextField: true),
    );
    expect(
      tester.getSemantics(register),
      isSemantics(identifier: 'register', isButton: true, hasTapAction: true),
    );

    await tester.enterText(invite, 'fixture-invite');
    await tester.tap(register);
    await _flush(tester);
    expect(fixture.auth.registerCalls, 1);
    expect(find.bySemanticsIdentifier('game-gomoku'), findsOneWidget);
  });

  testWidgets('idle catalog and opponent rows are identifier driven', (
    tester,
  ) async {
    final fixture = await _Fixture.authenticated(
      status: const GomokuIdleStatus(),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.dispose();
    });

    await tester.pumpWidget(fixture.app());
    await _flush(tester);
    final choose = find.bySemanticsIdentifier('choose-opponent');
    expect(find.bySemanticsIdentifier('game-gomoku'), findsOneWidget);
    expect(choose, findsOneWidget);
    expect(
      tester.getSemantics(choose),
      isSemantics(
        identifier: 'choose-opponent',
        isButton: true,
        hasTapAction: true,
      ),
    );

    await tester.tap(choose);
    await _flush(tester);
    final opponent = find.bySemanticsIdentifier('opponent-$_bobId');
    expect(opponent, findsOneWidget);
    expect(
      tester.getSemantics(opponent),
      isSemantics(
        identifier: 'opponent-$_bobId',
        isButton: true,
        hasTapAction: true,
      ),
    );

    await tester.tap(opponent);
    await _flush(tester);
    expect(fixture.homeApi.createCalls, 1);
    expect(fixture.launcher.calls, 1);
  });

  testWidgets(
    'active match exposes continue and zero-step cancel identifiers',
    (tester) async {
      final fixture = await _Fixture.authenticated(
        status: const GomokuActiveStatus(
          match: GomokuActiveMatch(
            id: _matchId,
            opponent: GomokuOpponentIdentity(id: _bobId, nickname: 'Bob'),
            color: GomokuColor.black,
            revision: 0,
          ),
        ),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        fixture.dispose();
      });

      await tester.pumpWidget(fixture.app());
      await _flush(tester);
      for (final identifier in const ['continue-match', 'cancel-match']) {
        final finder = find.bySemanticsIdentifier(identifier);
        expect(finder, findsOneWidget);
        expect(
          tester.getSemantics(finder),
          isSemantics(
            identifier: identifier,
            isButton: true,
            hasTapAction: true,
          ),
        );
      }

      await tester.tap(find.bySemanticsIdentifier('cancel-match'));
      await _flush(tester);
      expect(fixture.homeApi.cancelCalls, 1);
    },
  );
}

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
  await tester.pump(const Duration(milliseconds: 20));
}

final class _Fixture {
  _Fixture._({
    required this.auth,
    required this.tokenStore,
    required this.session,
    required this.homeApi,
    required this.launcher,
    required this.home,
    required this.profile,
  });

  factory _Fixture.unauthenticated() {
    final auth = _FakeAuthApi();
    final tokenStore = _MemoryTokenStore();
    final session = SessionController(authApi: auth, tokenStore: tokenStore);
    final homeApi = _FakeHomeApi(const GomokuIdleStatus());
    final launcher = _FakeLauncher();
    final home = HomeController(
      repository: GomokuRepository(
        api: homeApi,
        gameLauncher: launcher,
        apiBaseUri: Uri.parse('http://127.0.0.1:8080'),
      ),
    );
    final profile = ProfileController(
      store: _MemoryProfileStore(),
      nicknameRules: const _NicknameRules(),
    );
    return _Fixture._(
      auth: auth,
      tokenStore: tokenStore,
      session: session,
      homeApi: homeApi,
      launcher: launcher,
      home: home,
      profile: profile,
    );
  }

  static Future<_Fixture> authenticated({required GomokuStatus status}) async {
    final fixture = _Fixture.unauthenticated();
    fixture.homeApi.status = status;
    await fixture.profile.load();
    await fixture.profile.commitNickname('Alice');
    await fixture.session.restore();
    await fixture.session.register('fixture-invite', 'Alice');
    return fixture;
  }

  final _FakeAuthApi auth;
  final _MemoryTokenStore tokenStore;
  final SessionController session;
  final _FakeHomeApi homeApi;
  final _FakeLauncher launcher;
  final HomeController home;
  final ProfileController profile;

  Widget app() => GameboxApp(
    gameLauncher: launcher,
    sessionController: session,
    profileController: profile,
    homeController: home,
  );

  void dispose() {
    home.dispose();
    session.dispose();
    profile.dispose();
  }
}

final class _MemoryProfileStore implements AppProfileStore {
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
  var registerCalls = 0;

  @override
  Future<Session> register(String inviteCode, String nickname) async {
    registerCalls += 1;
    return _session(nickname);
  }

  @override
  Future<Session> refresh(String refreshToken) async => _session('Alice');

  @override
  Future<SessionUser> updateNickname(
    String nickname, {
    required AccessTokenProvider accessToken,
    required UnauthorizedHandler onUnauthorized,
  }) async => SessionUser(id: _aliceId, nickname: nickname);

  static Session _session(String nickname) {
    final now = DateTime.now().toUtc();
    return Session(
      user: SessionUser(id: _aliceId, nickname: nickname),
      accessToken: 'fixture-access-token',
      accessExpiresAt: now.add(const Duration(minutes: 15)),
      refreshToken: 'fixture-refresh-token',
      refreshExpiresAt: now.add(const Duration(days: 30)),
    );
  }
}

final class _MemoryTokenStore implements TokenStore {
  String? value;

  @override
  Future<void> deleteRefreshToken() async => value = null;

  @override
  Future<String?> readRefreshToken() async => value;

  @override
  Future<void> writeRefreshToken(String refreshToken) async {
    value = refreshToken;
  }
}

final class _FakeHomeApi implements HomeApi {
  @override
  Future<AuthoritativeGameResult> fetchResult(String matchId) =>
      throw UnimplementedError();
  _FakeHomeApi(this.status);

  GomokuStatus status;
  var createCalls = 0;
  var cancelCalls = 0;

  @override
  Future<void> cancelMatch(String matchId) async {
    cancelCalls += 1;
    status = const GomokuIdleStatus();
  }

  @override
  Future<CreatedGomokuMatch> createMatch(String opponentId) async {
    createCalls += 1;
    status = const GomokuActiveStatus(
      match: GomokuActiveMatch(
        id: _matchId,
        opponent: GomokuOpponentIdentity(id: _bobId, nickname: 'Bob'),
        color: GomokuColor.black,
        revision: 0,
      ),
    );
    return const CreatedGomokuMatch(id: _matchId, gameId: gomokuGameId);
  }

  @override
  Future<List<GomokuOpponent>> fetchOpponents() async => const [
    GomokuOpponent(
      id: _bobId,
      nickname: 'Bob',
      availability: OpponentAvailability.idle,
      presence: OpponentPresence.online,
    ),
  ];

  @override
  Future<GomokuStatus> fetchStatus() async => status;

  @override
  Future<GomokuLaunchTicket> createLaunchTicket(String matchId) async {
    return GomokuLaunchTicket(
      matchId: matchId,
      gameId: gomokuGameId,
      launchTicket: 'fixture-launch-ticket',
      expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 1)),
    );
  }
}

final class _FakeLauncher implements GameLauncher {
  var calls = 0;

  @override
  Future<void> launch(GameLaunchRequest request) async {
    calls += 1;
  }

  @override
  Future<void> launchHostSmoke() async {}
}
