import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/core/api/api_client.dart';
import 'package:gamebox/core/api/api_error.dart';
import 'package:gamebox/core/auth/session.dart';
import 'package:gamebox/core/auth/token_store.dart';
import 'package:gamebox/features/auth/auth_api.dart';
import 'package:gamebox/features/auth/session_controller.dart';
import 'package:gamebox/features/history/match_history_api.dart';
import 'package:gamebox/features/history/match_history_models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const matchId = '11111111-1111-4111-8111-111111111111';
  final now = DateTime.utc(2026, 8, 25, 12);

  test(
    'fetches the first page through the exact authenticated endpoint',
    () async {
      final fixture = await _ApiFixture.create(now, (request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/v1/games/gomoku/history');
        expect(request.url.query, 'limit=20');
        expect(request.headers['authorization'], 'Bearer access-one');
        return _json(_validEnvelope());
      });

      final page = await fixture.api.fetchPage();

      expect(page, isA<MatchHistoryPageData>());
      expect(page.matches.single.id, matchId);
    },
  );

  test(
    'round trips opaque cursor characters through the query parameter',
    () async {
      const cursor = 'cursor+/= ?&%汉字';
      final fixture = await _ApiFixture.create(now, (request) async {
        expect(request.url.queryParametersAll, {
          'limit': ['50'],
          'cursor': [cursor],
        });
        return _json(_validEnvelope(nextCursor: cursor));
      });

      final page = await fixture.api.fetchPage(cursor: cursor, limit: 50);

      expect(page.nextCursor, cursor);
    },
  );

  test(
    'retries the authenticated GET once after the session refreshes',
    () async {
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
          return _json(_validEnvelope());
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

      await fixture.api.fetchPage();

      expect(calls, 2);
      expect(fixture.auth.refreshCalls, 2); // restore plus 401 rotation
    },
  );

  test('normalizes an invalid history envelope to invalid_response', () async {
    final fixture = await _ApiFixture.create(
      now,
      (_) async => _json({
        ..._validEnvelope(),
        'matches': [
          {..._match(), 'id': 'invalid'},
        ],
      }),
    );

    await expectLater(
      fixture.api.fetchPage(),
      throwsA(
        isA<ApiError>().having(
          (error) => error.code,
          'code',
          'invalid_response',
        ),
      ),
    );
  });

  test(
    'decodes a fractional win rate through the HTTP client boundary',
    () async {
      final fixture = await _ApiFixture.create(
        now,
        (_) async => _json({
          'statistics': {
            'validMatches': 8,
            'wins': 5,
            'losses': 2,
            'draws': 1,
            'winRate': 0.625,
          },
          'matches': [_match()],
          'nextCursor': null,
        }),
      );

      final page = await fixture.api.fetchPage();

      expect(page.statistics.winRate, 0.625);
    },
  );

  test(
    'decodes an exponent win rate through the HTTP client boundary',
    () async {
      final fixture = await _ApiFixture.create(
        now,
        (_) async => http.Response(
          '{"statistics":{"validMatches":8,"wins":5,"losses":2,"draws":1,"winRate":6.25e-1},'
          '"matches":[{"id":"11111111-1111-4111-8111-111111111111",'
          '"outcome":"win","opponentNickname":"棋手","color":"black",'
          '"finishedAt":1787659200000,"moveCount":42}],"nextCursor":null}',
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        ),
      );

      final page = await fixture.api.fetchPage();

      expect(page.statistics.winRate, 0.625);
    },
  );
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
    return _ApiFixture(HttpMatchHistoryApi(client, session), auth);
  }

  final HttpMatchHistoryApi api;
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
    id: '22222222-2222-4222-8222-222222222222',
    nickname: '自己',
  ),
  accessToken: accessToken,
  accessExpiresAt: now.add(const Duration(minutes: 15)),
  refreshToken: refreshToken,
  refreshExpiresAt: now.add(const Duration(days: 30)),
);

Map<String, Object?> _validEnvelope({String? nextCursor}) => {
  'statistics': {
    'validMatches': 1,
    'wins': 1,
    'losses': 0,
    'draws': 0,
    'winRate': 1,
  },
  'matches': [_match()],
  'nextCursor': nextCursor,
};

Map<String, Object?> _match() => {
  'id': '11111111-1111-4111-8111-111111111111',
  'outcome': 'win',
  'opponentNickname': '棋手',
  'color': 'black',
  'finishedAt': DateTime.utc(2026, 8, 25, 12).millisecondsSinceEpoch,
  'moveCount': 42,
};

http.Response _json(Object body, {int status = 200}) => http.Response(
  jsonEncode(body),
  status,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

http.Response _error(String code, String message, int status) => _json({
  'error': {'code': code, 'message': message, 'details': <String, Object?>{}},
}, status: status);
