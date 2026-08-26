import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/core/api/api_client.dart';
import 'package:gamebox/core/api/api_error.dart';
import 'package:gamebox/core/auth/session.dart';
import 'package:gamebox/core/auth/token_store.dart';
import 'package:gamebox/features/auth/auth_api.dart';
import 'package:gamebox/features/auth/session_controller.dart';
import 'package:gamebox/features/gomoku/gomoku_models.dart';
import 'package:gamebox/features/home/game_catalog.dart';
import 'package:gamebox/features/home/home_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const aliceId = '11111111-1111-4111-8111-111111111111';
  const bobId = '22222222-2222-4222-8222-222222222222';
  const matchId = '33333333-3333-4333-8333-333333333333';
  final now = DateTime.utc(2026, 8, 20, 12);

  test('catalog exposes immutable gomoku and rps descriptors', () {
    expect(gameCatalog, hasLength(2));
    expect(
      gameCatalog.first,
      const GameDescriptor(id: 'gomoku', title: '五子棋', playerCount: 2),
    );
    expect(
      gameCatalog.last,
      const GameDescriptor(id: 'rps', title: '石头剪刀布', playerCount: 2),
    );
    expect(
      () => gameCatalog.add(
        const GameDescriptor(id: 'other', title: '其他', playerCount: 2),
      ),
      throwsUnsupportedError,
    );
  });

  test('status decodes the exact idle and active unions', () async {
    var calls = 0;
    final fixture = await _ApiFixture.create(now, (request) async {
      calls += 1;
      expect(request.method, 'GET');
      expect(request.url.path, '/v1/games/gomoku/status');
      expect(request.headers['authorization'], 'Bearer access-one');
      if (calls == 1) return _json({'state': 'idle'});
      return _json({
        'state': 'active',
        'match': {
          'id': matchId,
          'opponent': {'id': bobId, 'nickname': '小猫'},
          'color': 'black',
          'revision': 17,
        },
      });
    });

    expect(await fixture.api.fetchStatus(), isA<GomokuIdleStatus>());
    final active = await fixture.api.fetchStatus() as GomokuActiveStatus;
    expect(active.match.id, matchId);
    expect(active.match.opponent.id, bobId);
    expect(active.match.opponent.nickname, '小猫');
    expect(active.match.color, GomokuColor.black);
    expect(active.match.revision, 17);
  });

  test('status rejects non-exact and invalid active envelopes', () async {
    final validMatch = <String, Object?>{
      'id': matchId,
      'opponent': {'id': bobId, 'nickname': '小猫'},
      'color': 'white',
      'revision': 0,
    };
    final invalid = <String, Map<String, Object?>>{
      'idle extra': {'state': 'idle', 'match': null},
      'unknown state': {'state': 'finished'},
      'active missing match': {'state': 'active'},
      'active extra': {'state': 'active', 'match': validMatch, 'extra': true},
      'match extra': {
        'state': 'active',
        'match': {...validMatch, 'extra': true},
      },
      'zero id': {
        'state': 'active',
        'match': {...validMatch, 'id': '00000000-0000-0000-0000-000000000000'},
      },
      'wrong color': {
        'state': 'active',
        'match': {...validMatch, 'color': 'red'},
      },
      'negative revision': {
        'state': 'active',
        'match': {...validMatch, 'revision': -1},
      },
      'opponent extra': {
        'state': 'active',
        'match': {
          ...validMatch,
          'opponent': {'id': bobId, 'nickname': '小猫', 'extra': true},
        },
      },
    };

    for (final entry in invalid.entries) {
      final fixture = await _ApiFixture.create(
        now,
        (_) async => _json(entry.value),
      );
      await expectLater(
        fixture.api.fetchStatus(),
        throwsA(
          isA<ApiError>().having(
            (error) => error.code,
            entry.key,
            'invalid_response',
          ),
        ),
      );
    }
  });

  test('opponents decode exact availability and presence values', () async {
    final fixture = await _ApiFixture.create(now, (request) async {
      expect(request.method, 'GET');
      expect(request.url.path, '/v1/games/gomoku/opponents');
      return _json({
        'opponents': [
          {
            'id': aliceId,
            'nickname': '自己',
            'availability': 'idle',
            'presence': 'online',
          },
          {
            'id': bobId,
            'nickname': '小猫',
            'availability': 'busy',
            'presence': 'offline',
          },
        ],
      });
    });

    final opponents = await fixture.api.fetchOpponents();

    expect(opponents, hasLength(2));
    expect(opponents.first.availability, OpponentAvailability.idle);
    expect(opponents.first.presence, OpponentPresence.online);
    expect(opponents.last.availability, OpponentAvailability.busy);
    expect(opponents.last.presence, OpponentPresence.offline);
    expect(() => opponents.clear(), throwsUnsupportedError);
  });

  test('opponents reject every non-exact enum or object shape', () async {
    final base = <String, Object?>{
      'id': bobId,
      'nickname': '小猫',
      'availability': 'idle',
      'presence': 'offline',
    };
    final invalid = <String, Object?>{
      'root extra': {
        'opponents': [base],
        'extra': true,
      },
      'not a list': {'opponents': base},
      'row extra': {
        'opponents': [
          {...base, 'extra': true},
        ],
      },
      'availability': {
        'opponents': [
          {...base, 'availability': 'available'},
        ],
      },
      'presence': {
        'opponents': [
          {...base, 'presence': 'away'},
        ],
      },
      'nickname': {
        'opponents': [
          {...base, 'nickname': ' x '},
        ],
      },
    };
    for (final entry in invalid.entries) {
      final fixture = await _ApiFixture.create(
        now,
        (_) async => _json(entry.value!),
      );
      await expectLater(
        fixture.api.fetchOpponents(),
        throwsA(
          isA<ApiError>().having(
            (error) => error.code,
            entry.key,
            'invalid_response',
          ),
        ),
      );
    }
  });

  test('create match sends exact input and decodes its typed result', () async {
    final fixture = await _ApiFixture.create(now, (request) async {
      expect(request.method, 'POST');
      expect(request.url.path, '/v1/games/gomoku/matches');
      expect(jsonDecode(request.body), {'opponentId': bobId});
      return _json({
        'match': {'id': matchId, 'gameId': 'gomoku', 'state': 'active'},
      }, status: 201);
    });

    final created = await fixture.api.createMatch(bobId);

    expect(created.id, matchId);
    expect(created.gameId, 'gomoku');
  });

  test(
    'launch ticket uses exact endpoint and redacts its credential',
    () async {
      const secret = 'launch-ticket-secret';
      final expiresAt = now.add(const Duration(minutes: 1));
      final fixture = await _ApiFixture.create(now, (request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/v1/matches/$matchId/launch-ticket');
        expect(jsonDecode(request.body), isEmpty);
        return _json({
          'matchId': matchId,
          'gameId': 'gomoku',
          'launchTicket': secret,
          'expiresAt': expiresAt.millisecondsSinceEpoch,
        }, status: 201);
      });

      final ticket = await fixture.api.createLaunchTicket(matchId);

      expect(ticket.matchId, matchId);
      expect(ticket.gameId, 'gomoku');
      expect(ticket.launchTicket, secret);
      expect(ticket.expiresAt, expiresAt);
      expect(ticket.toString(), contains('<redacted>'));
      expect(ticket.toString(), isNot(contains(secret)));
    },
  );

  test('create and ticket responses require exact stable contracts', () async {
    final cases = <String, Map<String, Object?>>{
      'create game': {
        'match': {'id': matchId, 'gameId': 'chess', 'state': 'active'},
      },
      'create state': {
        'match': {'id': matchId, 'gameId': 'gomoku', 'state': 'idle'},
      },
      'create extra': {
        'match': {
          'id': matchId,
          'gameId': 'gomoku',
          'state': 'active',
          'extra': true,
        },
      },
      'ticket match': {
        'matchId': bobId,
        'gameId': 'gomoku',
        'launchTicket': 'ticket',
        'expiresAt': now.millisecondsSinceEpoch,
      },
      'ticket game': {
        'matchId': matchId,
        'gameId': 'chess',
        'launchTicket': 'ticket',
        'expiresAt': now.millisecondsSinceEpoch,
      },
      'ticket timestamp': {
        'matchId': matchId,
        'gameId': 'gomoku',
        'launchTicket': 'ticket',
        'expiresAt': 0,
      },
      'ticket credential': {
        'matchId': matchId,
        'gameId': 'gomoku',
        'launchTicket': 'ticket with space',
        'expiresAt': now.millisecondsSinceEpoch,
      },
    };
    for (final entry in cases.entries) {
      final isTicket = entry.key.startsWith('ticket');
      final fixture = await _ApiFixture.create(
        now,
        (_) async => _json(entry.value, status: 201),
      );
      await expectLater(
        isTicket
            ? fixture.api.createLaunchTicket(matchId)
            : fixture.api.createMatch(bobId),
        throwsA(
          isA<ApiError>().having(
            (error) => error.code,
            entry.key,
            'invalid_response',
          ),
        ),
      );
    }
  });

  test('cancel sends an empty DELETE and accepts only empty 204', () async {
    final fixture = await _ApiFixture.create(now, (request) async {
      expect(request.method, 'DELETE');
      expect(request.url.path, '/v1/matches/$matchId');
      expect(request.body, isEmpty);
      return http.Response('', 204);
    });

    await fixture.api.cancelMatch(matchId);
  });

  test('safe GET 401 rotates through Task 17 and retries once', () async {
    var calls = 0;
    final fixture = await _ApiFixture.create(
      now,
      (request) async {
        calls += 1;
        if (calls == 1) {
          expect(request.headers['authorization'], 'Bearer access-one');
          return _error('unauthorized', '身份验证失败', 401);
        }
        expect(request.headers['authorization'], 'Bearer access-two');
        return _json({'state': 'idle'});
      },
      refresh: (refreshToken) async => refreshToken == 'refresh-zero'
          ? _session(
              now,
              accessToken: 'access-one',
              refreshToken: 'refresh-one',
            )
          : _session(
              now,
              accessToken: 'access-two',
              refreshToken: 'refresh-two',
            ),
    );

    expect(await fixture.api.fetchStatus(), isA<GomokuIdleStatus>());
    expect(calls, 2);
    expect(fixture.auth.refreshCalls, 2); // restore plus 401 rotation
  });
}

final class _ApiFixture {
  const _ApiFixture(this.api, this.auth);

  static Future<_ApiFixture> create(
    DateTime now,
    Future<http.Response> Function(http.Request request) handler, {
    Future<Session> Function(String refreshToken)? refresh,
  }) async {
    final auth = _FakeAuthApi(
      refresh ??
          (_) async => _session(
            now,
            accessToken: 'access-one',
            refreshToken: 'refresh-one',
          ),
    );
    final session = SessionController(
      authApi: auth,
      tokenStore: _MemoryTokenStore('refresh-zero'),
      now: () => now,
    );
    await session.restore();
    final client = ApiClient(
      baseUri: Uri.parse('https://gamebox.test'),
      httpClient: MockClient(handler),
    );
    return _ApiFixture(HttpHomeApi(client, session), auth);
  }

  final HttpHomeApi api;
  final _FakeAuthApi auth;
}

final class _FakeAuthApi implements AuthApi {
  _FakeAuthApi(this.onRefresh);

  final Future<Session> Function(String refreshToken) onRefresh;
  int refreshCalls = 0;

  @override
  Future<Session> refresh(String refreshToken) {
    refreshCalls += 1;
    return onRefresh(refreshToken);
  }

  @override
  Future<Session> register(String inviteCode, String nickname) =>
      Future<Session>.error(StateError('unexpected register'));
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

Session _session(
  DateTime now, {
  required String accessToken,
  required String refreshToken,
}) => Session(
  user: const SessionUser(
    id: '11111111-1111-4111-8111-111111111111',
    nickname: '自己',
  ),
  accessToken: accessToken,
  accessExpiresAt: now.add(const Duration(minutes: 15)),
  refreshToken: refreshToken,
  refreshExpiresAt: now.add(const Duration(days: 30)),
);

http.Response _json(Object body, {int status = 200}) => http.Response(
  jsonEncode(body),
  status,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

http.Response _error(String code, String message, int status) => _json({
  'error': {'code': code, 'message': message, 'details': <String, Object?>{}},
}, status: status);
