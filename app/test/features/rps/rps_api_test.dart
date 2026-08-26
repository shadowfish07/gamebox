import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/core/api/api_client.dart';
import 'package:gamebox/core/auth/session.dart';
import 'package:gamebox/core/auth/token_store.dart';
import 'package:gamebox/features/auth/auth_api.dart';
import 'package:gamebox/features/auth/session_controller.dart';
import 'package:gamebox/features/rps/rps_api.dart';
import 'package:gamebox/features/rps/rps_models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const opponentId = '22222222-2222-4222-8222-222222222222';
  const matchId = '33333333-3333-4333-8333-333333333333';
  final now = DateTime.utc(2026, 8, 25, 12);

  test('create sends the selected format as an exact stable payload', () async {
    final api = await _api(now, (request) async {
      expect(request.method, 'POST');
      expect(request.url.path, '/v1/games/rps/matches');
      expect(request.headers['authorization'], 'Bearer access-token');
      expect(jsonDecode(request.body), {
        'opponentId': opponentId,
        'format': 'best_of_three',
      });
      return _json({
        'match': {
          'id': matchId,
          'gameId': 'rps',
          'state': 'active',
          'format': 'best_of_three',
        },
      }, status: 201);
    });

    final created = await api.createMatch(opponentId, RpsFormat.bestOfThree);

    expect(created.id, matchId);
    expect(created.format, RpsFormat.bestOfThree);
  });

  test(
    'active status exposes the persisted format to either participant',
    () async {
      final api = await _api(
        now,
        (_) async => _json({
          'state': 'active',
          'match': {
            'id': matchId,
            'opponent': {'id': opponentId, 'nickname': '小猫'},
            'color': 'white',
            'revision': 0,
            'format': 'single_round',
          },
        }),
      );

      final status = await api.fetchStatus() as RpsActiveStatus;

      expect(status.match.format, RpsFormat.singleRound);
      expect(status.match.opponent.nickname, '小猫');
    },
  );

  test('format parser rejects omitted and unknown formats', () {
    final base = <String, Object?>{
      'id': matchId,
      'opponent': {'id': opponentId, 'nickname': '小猫'},
      'color': 'black',
      'revision': 0,
    };
    expect(() => RpsActiveMatch.fromJson(base), throwsFormatException);
    expect(
      () => RpsActiveMatch.fromJson({...base, 'format': 'best_of_five'}),
      throwsFormatException,
    );
  });

  test(
    'launch ticket rejects whitespace credentials and out-of-range time',
    () {
      final base = <String, Object?>{
        'matchId': matchId,
        'gameId': rpsGameId,
        'launchTicket': 'ticket',
        'expiresAt': now.millisecondsSinceEpoch,
      };
      expect(
        () => RpsLaunchTicket.fromEnvelope({
          ...base,
          'launchTicket': 'bad ticket',
        }),
        throwsFormatException,
      );
      expect(
        () => RpsLaunchTicket.fromEnvelope({...base, 'expiresAt': 1 << 63}),
        throwsFormatException,
      );
    },
  );
}

Future<HttpRpsApi> _api(
  DateTime now,
  Future<http.Response> Function(http.Request request) handler,
) async {
  final session = SessionController(
    authApi: _AuthApi(now),
    tokenStore: _TokenStore(),
    now: () => now,
  );
  await session.restore();
  return HttpRpsApi(
    ApiClient(
      baseUri: Uri.parse('https://gamebox.test'),
      httpClient: MockClient(handler),
    ),
    session,
  );
}

final class _AuthApi implements AuthApi {
  const _AuthApi(this.now);

  final DateTime now;

  @override
  Future<Session> refresh(String refreshToken) async => Session(
    user: const SessionUser(
      id: '11111111-1111-4111-8111-111111111111',
      nickname: '自己',
    ),
    accessToken: 'access-token',
    accessExpiresAt: now.add(const Duration(minutes: 15)),
    refreshToken: 'refresh-next',
    refreshExpiresAt: now.add(const Duration(days: 30)),
  );

  @override
  Future<Session> register(String inviteCode, String nickname) =>
      Future.error(StateError('unexpected register'));
}

final class _TokenStore implements TokenStore {
  String? value = 'refresh-token';

  @override
  Future<void> deleteRefreshToken() async => value = null;

  @override
  Future<String?> readRefreshToken() async => value;

  @override
  Future<void> writeRefreshToken(String refreshToken) async =>
      value = refreshToken;
}

http.Response _json(Object body, {int status = 200}) => http.Response(
  jsonEncode(body),
  status,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);
