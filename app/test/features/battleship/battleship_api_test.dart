import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:gamebox/core/api/api_client.dart';
import 'package:gamebox/core/api/api_error.dart';
import 'package:gamebox/features/battleship/battleship_api.dart';

import 'battleship_test.dart' show state, user, matchId;

void main() {
  test(
    'native API authenticates requests and preserves exact action identity',
    () async {
      final calls = <http.Request>[];
      final client = ApiClient(
        baseUri: Uri.parse('http://sea.test'),
        httpClient: MockClient((r) async {
          calls.add(r);
          return http.Response(
            jsonEncode(state()),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      final api = HttpBattleshipApi(
        client,
        userId: user,
        accessToken: () => 'test-token',
        onUnauthorized: (_) async => false,
      );
      final action = <String, Object?>{
        'actionId': matchId,
        'revision': 0,
        'kind': 'fire',
        'ships': [],
        'cell': 3,
      };
      await api.act(matchId, action);
      expect(calls.single.url.path, '/v1/battleship/matches/$matchId/actions');
      expect(calls.single.headers['Authorization'], 'Bearer test-token');
      expect(jsonDecode(calls.single.body), action);
      client.close();
    },
  );
  test('bad snapshots and noncanonical cursors are safe errors', () async {
    final client = ApiClient(
      httpClient: MockClient(
        (r) async => http.Response(
          jsonEncode({'matches': [], 'nextCursor': '../other'}),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
    final api = HttpBattleshipApi(
      client,
      userId: user,
      accessToken: () => 'test-token',
      onUnauthorized: (_) async => false,
    );
    await expectLater(
      api.matches(),
      throwsA(
        isA<ApiError>().having((e) => e.code, 'code', 'invalid_response'),
      ),
    );
    client.close();
  });
}
