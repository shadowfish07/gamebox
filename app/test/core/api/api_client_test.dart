import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

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

  test('error envelopes require exact canonical keys', () async {
    final cases = {
      'unknown root':
          '{"error":{"code":"unauthorized","message":"失败","details":{}},"extra":1}',
      'unknown error key':
          '{"error":{"code":"unauthorized","message":"失败","details":{},"extra":1}}',
      'missing details': '{"error":{"code":"unauthorized","message":"失败"}}',
      'escaped root alias':
          r'{"err\u006fr":{"code":"unauthorized","message":"失败","details":{}}}',
    };
    for (final entry in cases.entries) {
      final client = ApiClient(
        baseUri: Uri.parse('https://gamebox.test'),
        httpClient: MockClient((_) async => _jsonResponse(entry.value, 401)),
      );
      await expectLater(
        client.getJson('/error'),
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
        onUnauthorized: (failedToken) async {
          expect(failedToken, 'access-old');
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
        onUnauthorized: (failedToken) async {
          expect(failedToken, 'access-old');
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

  test(
    'strict JSON rejects malformed UTF-8 and adversarial lexical forms',
    () async {
      final cases = <String, Uint8List>{
        'malformed UTF-8': Uint8List.fromList([
          0x7b,
          0x22,
          0x78,
          0x22,
          0x3a,
          0x22,
          0xc3,
          0x28,
          0x22,
          0x7d,
        ]),
        'duplicate nested key': utf8.encode('{"outer":{"value":1,"value":2}}'),
        'escaped key alias': utf8.encode(r'{"val\u0075e":1}'),
        'unpaired high surrogate': utf8.encode(r'{"value":"\uD800"}'),
        'unpaired low surrogate': utf8.encode(r'{"value":"\uDC00"}'),
        'unsafe integer': utf8.encode('{"value":9007199254740992}'),
        'unbounded integer': utf8.encode(
          '{"value":${List.filled(100, '9').join()}}',
        ),
        'unbounded key': utf8.encode('{"${List.filled(65, 'k').join()}":true}'),
        'fractional number': utf8.encode('{"value":1.5}'),
        'depth overflow': utf8.encode(_deepObject(33)),
      };

      for (final entry in cases.entries) {
        final client = ApiClient(
          baseUri: Uri.parse('https://gamebox.test'),
          httpClient: MockClient(
            (_) async => http.Response.bytes(
              entry.value,
              200,
              headers: const {
                'content-type': 'application/json; charset=utf-8',
              },
            ),
          ),
        );
        await expectLater(
          client.getJson('/strict'),
          throwsA(
            isA<ApiError>().having(
              (error) => error.code,
              entry.key,
              'invalid_response',
            ),
          ),
        );
      }
    },
  );

  test('content type rejects non-UTF-8 charset', () async {
    final client = ApiClient(
      baseUri: Uri.parse('https://gamebox.test'),
      httpClient: MockClient(
        (_) async => http.Response(
          '{"ok":true}',
          200,
          headers: const {'content-type': 'application/json; charset=latin1'},
        ),
      ),
    );
    await expectLater(
      client.getJson('/strict'),
      throwsA(
        isA<ApiError>().having(
          (error) => error.code,
          'code',
          'invalid_response',
        ),
      ),
    );
  });

  test('strict JSON accepts an absent charset and paired surrogate', () async {
    final client = ApiClient(
      baseUri: Uri.parse('https://gamebox.test'),
      httpClient: MockClient(
        (_) async => http.Response(
          r'{"value":"\uD83D\uDE00"}',
          200,
          headers: const {'content-type': 'application/json'},
        ),
      ),
    );

    expect(await client.getJson('/strict'), {'value': '😀'});
  });

  test('redirects are disabled and every 3xx is invalid_response', () async {
    late http.BaseRequest captured;
    final client = ApiClient(
      baseUri: Uri.parse('https://gamebox.test'),
      httpClient: _SendingClient((request) async {
        captured = request;
        return _streamedJson(
          '{"ok":true}',
          301,
          headers: const {'location': 'https://attacker.test/steal'},
        );
      }),
    );

    await expectLater(
      client.getJson('/redirect', accessToken: () => 'access-secret'),
      throwsA(
        isA<ApiError>().having(
          (error) => error.code,
          'code',
          'invalid_response',
        ),
      ),
    );
    expect(captured.followRedirects, isFalse);
    expect(captured.maxRedirects, 0);
  });

  test(
    'send timeout completes abort trigger without a lingering request',
    () async {
      final aborted = Completer<void>();
      final never = Completer<http.StreamedResponse>();
      final client = ApiClient(
        baseUri: Uri.parse('https://gamebox.test'),
        timeout: const Duration(milliseconds: 10),
        httpClient: _SendingClient((request) {
          final abortable = request as http.AbortableRequest;
          abortable.abortTrigger!.then((_) {
            if (!aborted.isCompleted) aborted.complete();
            if (!never.isCompleted) {
              never.completeError(http.RequestAbortedException(request.url));
            }
          });
          return never.future;
        }),
      );

      await expectLater(
        client.getJson('/timeout'),
        throwsA(
          isA<ApiError>().having((error) => error.code, 'code', 'timeout'),
        ),
      );
      await aborted.future.timeout(const Duration(seconds: 1));
    },
  );

  test(
    'body timeout aborts and cancels the active stream subscription',
    () async {
      final aborted = Completer<void>();
      final cancelled = Completer<void>();
      late StreamController<List<int>> body;
      body = StreamController<List<int>>(
        onCancel: () {
          if (!cancelled.isCompleted) cancelled.complete();
        },
      );
      final client = ApiClient(
        baseUri: Uri.parse('https://gamebox.test'),
        timeout: const Duration(milliseconds: 10),
        httpClient: _SendingClient((request) async {
          final abortable = request as http.AbortableRequest;
          abortable.abortTrigger!.then((_) {
            if (!aborted.isCompleted) aborted.complete();
          });
          return http.StreamedResponse(
            body.stream,
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
      );

      await expectLater(
        client.getJson('/body-timeout'),
        throwsA(
          isA<ApiError>().having((error) => error.code, 'code', 'timeout'),
        ),
      );
      await aborted.future.timeout(const Duration(seconds: 1));
      await cancelled.future.timeout(const Duration(seconds: 1));
    },
  );

  test('unknown midstream failures become a bounded network error', () async {
    const secret = 'secret-midstream-diagnostic';
    final client = ApiClient(
      baseUri: Uri.parse('https://gamebox.test'),
      httpClient: _SendingClient(
        (_) async => http.StreamedResponse(
          Stream<List<int>>.error(StateError(secret)),
          200,
          headers: const {'content-type': 'application/json'},
        ),
      ),
    );

    try {
      await client.getJson('/midstream');
      fail('expected ApiError');
    } on ApiError catch (error) {
      expect(error.code, 'network_error');
      expect(error.toString(), isNot(contains(secret)));
    }
  });

  for (final declared in [true, false]) {
    test(
      '${declared ? 'declared' : 'streamed'} oversized response aborts and cancels',
      () async {
        final aborted = Completer<void>();
        final cancelled = Completer<void>();
        late StreamController<List<int>> body;
        body = StreamController<List<int>>(
          sync: true,
          onListen: () {
            if (!declared) {
              body.add(Uint8List(300 * 1024));
              body.add(Uint8List(300 * 1024));
            }
          },
          onCancel: () {
            if (!cancelled.isCompleted) cancelled.complete();
          },
        );
        final client = ApiClient(
          baseUri: Uri.parse('https://gamebox.test'),
          httpClient: _SendingClient((request) async {
            final abortable = request as http.AbortableRequest;
            abortable.abortTrigger!.then((_) {
              if (!aborted.isCompleted) aborted.complete();
            });
            return http.StreamedResponse(
              body.stream,
              200,
              contentLength: declared ? 600 * 1024 : null,
              headers: const {'content-type': 'application/json'},
            );
          }),
        );

        await expectLater(
          client.getJson('/oversized'),
          throwsA(
            isA<ApiError>().having(
              (error) => error.code,
              'code',
              'invalid_response',
            ),
          ),
        );
        await aborted.future.timeout(const Duration(seconds: 1));
        await cancelled.future.timeout(const Duration(seconds: 1));
      },
    );
  }

  test('many delayed T0 GET 401s share one rotation and retry with T1', () async {
    var accessToken = 'T0';
    var refreshCalls = 0;
    Future<bool>? inFlight;
    const requestCount = 12;
    var oldRequests = 0;
    final allOldStarted = Completer<void>();
    final releaseOld = Completer<void>();
    final client = ApiClient(
      baseUri: Uri.parse('https://gamebox.test'),
      httpClient: MockClient((request) async {
        final used = request.headers['authorization'];
        if (used == 'Bearer T0') {
          oldRequests += 1;
          if (oldRequests == requestCount) allOldStarted.complete();
          await releaseOld.future;
          return _jsonResponse(
            '{"error":{"code":"unauthorized","message":"身份验证失败","details":{}}}',
            401,
          );
        }
        expect(used, 'Bearer T1');
        return _jsonResponse('{"ok":true}', 200);
      }),
    );
    Future<bool> coordinate(String failedToken) {
      if (failedToken != accessToken) return Future<bool>.value(true);
      final existing = inFlight;
      if (existing != null) return existing;
      final operation = Future<bool>.microtask(() {
        refreshCalls += 1;
        accessToken = 'T1';
        return true;
      });
      inFlight = operation;
      operation.whenComplete(() => inFlight = null);
      return operation;
    }

    final requests = List.generate(
      requestCount,
      (_) => client.getJson(
        '/delayed',
        accessToken: () => accessToken,
        onUnauthorized: coordinate,
      ),
    );
    await allOldStarted.future;
    releaseOld.complete();
    final responses = await Future.wait(requests);

    expect(responses, everyElement(containsPair('ok', true)));
    expect(refreshCalls, 1);
  });

  test('delayed old-token POST neither refreshes nor replays', () async {
    var accessToken = 'T0';
    var calls = 0;
    var refreshCalls = 0;
    final started = Completer<void>();
    final release = Completer<void>();
    final client = ApiClient(
      baseUri: Uri.parse('https://gamebox.test'),
      httpClient: MockClient((request) async {
        calls += 1;
        expect(request.headers['authorization'], 'Bearer T0');
        started.complete();
        await release.future;
        return _jsonResponse(
          '{"error":{"code":"unauthorized","message":"身份验证失败","details":{}}}',
          401,
        );
      }),
    );
    final request = client.postJson(
      '/action',
      const {'value': 1},
      accessToken: () => accessToken,
      onUnauthorized: (failedToken) async {
        expect(failedToken, 'T0');
        if (failedToken != accessToken) return true;
        refreshCalls += 1;
        return true;
      },
    );
    await started.future;
    accessToken = 'T1';
    release.complete();

    await expectLater(
      request,
      throwsA(
        isA<ApiError>().having((error) => error.code, 'code', 'unauthorized'),
      ),
    );
    expect(refreshCalls, 0);
    expect(calls, 1);
  });

  test(
    'retry 401 does not trigger a second refresh or a third request',
    () async {
      var accessToken = 'T1';
      var refreshCalls = 0;
      var calls = 0;
      final client = ApiClient(
        baseUri: Uri.parse('https://gamebox.test'),
        httpClient: MockClient((_) async {
          calls += 1;
          return _jsonResponse(
            '{"error":{"code":"unauthorized","message":"身份验证失败","details":{}}}',
            401,
          );
        }),
      );

      await expectLater(
        client.getJson(
          '/limited',
          accessToken: () => accessToken,
          onUnauthorized: (failedToken) async {
            expect(failedToken, 'T1');
            refreshCalls += 1;
            accessToken = 'T2';
            return true;
          },
        ),
        throwsA(
          isA<ApiError>().having((error) => error.code, 'code', 'unauthorized'),
        ),
      );
      expect(refreshCalls, 1);
      expect(calls, 2);
    },
  );
}

http.Response _jsonResponse(String body, int status) {
  return http.Response(
    body,
    status,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

final class _SendingClient extends http.BaseClient {
  _SendingClient(this._send);

  final Future<http.StreamedResponse> Function(http.BaseRequest request) _send;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _send(request);
}

http.StreamedResponse _streamedJson(
  String body,
  int status, {
  Map<String, String> headers = const {},
}) {
  return http.StreamedResponse(
    Stream.value(utf8.encode(body)),
    status,
    headers: {'content-type': 'application/json; charset=utf-8', ...headers},
  );
}

String _deepObject(int depth) {
  return '${List.filled(depth, '{"value":').join()}0'
      '${List.filled(depth, '}').join()}';
}
