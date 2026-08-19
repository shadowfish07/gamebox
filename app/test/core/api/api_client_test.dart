import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/core/api/api_client.dart';
import 'package:gamebox/core/api/api_error.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('API base URL uses the documented dart-define default', () {
    expect(apiBaseUrl, 'http://10.0.2.2:8080');
  });

  test('successful response must be a JSON object', () async {
    final client = ApiClient(
      httpClient: MockClient((_) async => http.Response('[]', 200)),
      baseUri: Uri.parse('https://gamebox.test'),
    );

    await expectLater(
      client.getJson('/v1/me'),
      throwsA(
        isA<ApiError>()
            .having((error) => error.code, 'code', 'invalid_response')
            .having((error) => error.message, 'message', isNotEmpty),
      ),
    );
  });

  test('successful JSON requires the declared JSON content type', () async {
    final client = ApiClient(
      httpClient: MockClient((_) async => http.Response('{"ok":true}', 200)),
      baseUri: Uri.parse('https://gamebox.test'),
    );

    await expectLater(
      client.getJson('/v1/me'),
      throwsA(
        isA<ApiError>().having(
          (error) => error.code,
          'code',
          'invalid_response',
        ),
      ),
    );
  });

  test('oversized JSON is rejected before decoding', () async {
    final client = ApiClient(
      httpClient: MockClient(
        (_) async => _jsonResponse(
          '{"value":"${List.filled(600 * 1024, 'x').join()}"}',
          200,
        ),
      ),
      baseUri: Uri.parse('https://gamebox.test'),
    );

    await expectLater(
      client.getJson('/v1/me'),
      throwsA(
        isA<ApiError>().having(
          (error) => error.code,
          'code',
          'invalid_response',
        ),
      ),
    );
  });

  test('error envelope retains no body, token, details, or status', () async {
    const secret = 'refresh-token-must-not-survive';
    final client = ApiClient(
      httpClient: MockClient(
        (_) async => _jsonResponse(
          jsonEncode({
            'error': {
              'code': 'invite_invalid',
              'message': '邀请码无效或已使用',
              'details': {'rawToken': secret},
            },
          }),
          422,
        ),
      ),
      baseUri: Uri.parse('https://gamebox.test'),
    );

    try {
      await client.postJson('/v1/auth/register', const {'inviteCode': secret});
      fail('expected ApiError');
    } on ApiError catch (error) {
      expect(error.code, 'invite_invalid');
      expect(error.message, '邀请码无效或已使用');
      expect(error.toString(), isNot(contains(secret)));
      expect(error.toString(), isNot(contains('422')));
    }
  });

  test('malformed error bodies become a bounded safe ApiError', () async {
    const secretBody = 'plaintext-secret-response-body';
    final client = ApiClient(
      httpClient: MockClient((_) async => http.Response(secretBody, 500)),
      baseUri: Uri.parse('https://gamebox.test'),
    );

    try {
      await client.getJson('/v1/me');
      fail('expected ApiError');
    } on ApiError catch (error) {
      expect(error.code, 'invalid_response');
      expect(error.toString(), isNot(contains(secretBody)));
    }
  });

  test(
    'authorized GET refreshes once and retries with the rotated token',
    () async {
      var accessToken = 'access-old';
      var calls = 0;
      var refreshCalls = 0;
      final client = ApiClient(
        httpClient: MockClient((request) async {
          calls += 1;
          if (calls == 1) {
            expect(request.headers['authorization'], 'Bearer access-old');
            return _jsonResponse(
              '{"error":{"code":"unauthorized","message":"身份验证失败","details":{}}}',
              401,
            );
          }
          expect(request.headers['authorization'], 'Bearer access-new');
          return _jsonResponse('{"user":{"nickname":"小鱼"}}', 200);
        }),
        baseUri: Uri.parse('https://gamebox.test'),
      );

      final result = await client.getJson(
        '/v1/me',
        accessToken: () => accessToken,
        onUnauthorized: () async {
          refreshCalls += 1;
          accessToken = 'access-new';
          return true;
        },
      );

      expect(result['user'], isA<Map<String, Object?>>());
      expect(calls, 2);
      expect(refreshCalls, 1);
    },
  );

  test('authorized POST invokes refresh but never replays its body', () async {
    var calls = 0;
    var refreshCalls = 0;
    final client = ApiClient(
      httpClient: MockClient((request) async {
        calls += 1;
        expect(request.body, '{"move":"secret-action"}');
        return _jsonResponse(
          '{"error":{"code":"unauthorized","message":"身份验证失败","details":{}}}',
          401,
        );
      }),
      baseUri: Uri.parse('https://gamebox.test'),
    );

    await expectLater(
      client.postJson(
        '/v1/matches/one/actions',
        const {'move': 'secret-action'},
        accessToken: () => 'access-old',
        onUnauthorized: () async {
          refreshCalls += 1;
          return true;
        },
      ),
      throwsA(
        isA<ApiError>().having((error) => error.code, 'code', 'unauthorized'),
      ),
    );
    expect(calls, 1);
    expect(refreshCalls, 1);
  });
}

http.Response _jsonResponse(String body, int status) {
  return http.Response(
    body,
    status,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}
