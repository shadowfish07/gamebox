import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/core/api/api_client.dart';
import 'package:gamebox/core/api/api_error.dart';
import 'package:gamebox/core/auth/token_store.dart';
import 'package:gamebox/features/auth/auth_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'register matches the server contract and decodes its session',
    () async {
      final client = ApiClient(
        baseUri: Uri.parse('https://gamebox.test'),
        httpClient: MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.url.path, '/v1/auth/register');
          expect(jsonDecode(request.body), {
            'inviteCode': 'invite-one',
            'nickname': '小鱼',
          });
          expect(request.headers['authorization'], isNull);
          return _sessionResponse(status: 201);
        }),
      );

      final session = await HttpAuthApi(client).register('invite-one', '小鱼');

      expect(session.user.nickname, '小鱼');
      expect(session.accessToken, 'access-token');
      expect(session.refreshToken, 'refresh-token');
    },
  );

  test(
    'refresh sends only the refresh credential to the exact endpoint',
    () async {
      final client = ApiClient(
        baseUri: Uri.parse('https://gamebox.test'),
        httpClient: MockClient((request) async {
          expect(request.url.path, '/v1/auth/refresh');
          expect(jsonDecode(request.body), {'refreshToken': 'refresh-old'});
          expect(request.headers['authorization'], isNull);
          return _sessionResponse(refreshToken: 'refresh-new');
        }),
      );

      final session = await HttpAuthApi(client).refresh('refresh-old');

      expect(session.refreshToken, 'refresh-new');
    },
  );

  test(
    'malformed session becomes a safe error and diagnostics redact tokens',
    () async {
      const secret = 'secret-response-token';
      final client = ApiClient(
        baseUri: Uri.parse('https://gamebox.test'),
        httpClient: MockClient(
          (_) async => _sessionResponse(accessToken: '$secret with-space'),
        ),
      );

      try {
        await HttpAuthApi(client).refresh('refresh-old');
        fail('expected ApiError');
      } on ApiError catch (error) {
        expect(error.code, 'invalid_response');
        expect(error.toString(), isNot(contains(secret)));
      }

      final valid = await HttpAuthApi(
        ApiClient(
          baseUri: Uri.parse('https://gamebox.test'),
          httpClient: MockClient((_) async => _sessionResponse()),
        ),
      ).refresh('refresh-old');
      expect(valid.toString(), contains('credentials: <redacted>'));
      expect(valid.toString(), isNot(contains(valid.accessToken)));
      expect(valid.toString(), isNot(contains(valid.refreshToken)));
    },
  );

  test('secure storage refresh key is stable', () {
    expect(SecureTokenStore.refreshTokenKey, 'gamebox.refresh_token.v1');
  });
}

http.Response _sessionResponse({
  String accessToken = 'access-token',
  String refreshToken = 'refresh-token',
  int status = 200,
}) {
  return http.Response(
    jsonEncode({
      'session': {
        'user': {
          'id': '11111111-1111-4111-8111-111111111111',
          'nickname': '小鱼',
        },
        'accessToken': accessToken,
        'accessExpiresAt': DateTime.utc(
          2026,
          8,
          20,
          12,
          15,
        ).millisecondsSinceEpoch,
        'refreshToken': refreshToken,
        'refreshExpiresAt': DateTime.utc(
          2026,
          9,
          19,
          12,
        ).millisecondsSinceEpoch,
      },
    }),
    status,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}
