import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/core/lan/lan_api.dart';
import 'package:gamebox/core/lan/lan_models.dart';
import 'package:gamebox/core/lan/lan_qr_payload.dart';
import 'package:gamebox/core/lan/private_ipv4.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const room = '11111111-1111-4111-8111-111111111111';
  const player = '22222222-2222-4222-8222-222222222222';
  const attempt = '33333333-3333-4333-8333-333333333333';
  const key = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
  const token = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBAA';
  final endpoint = LanEndpoint(
    host: PrivateIpv4.parse('10.0.2.2'),
    port: 50000,
  );
  final qr = LanJoinQr(
    roomId: room,
    endpoint: endpoint,
    roomKey: key,
    expiresAt: DateTime.fromMillisecondsSinceEpoch(2000000000000, isUtc: true),
  );
  final candidate = LanJoinCandidate(
    roomId: room,
    joinAttemptId: attempt,
    candidateResumeToken: token,
    endpoint: endpoint,
  );

  test('join sends exact isolated JSON without public authorization', () async {
    late http.Request captured;
    final api = LanApi(
      client: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'schemaVersion': 1,
            'matchId': room,
            'gameId': 'gomoku',
            'playerId': player,
            'launchTicket': key,
            'expiresAt': 1900000000000,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final receipt = await api.join(qr, candidate, '玩家甲');
    expect(receipt.playerId, player);
    expect(
      captured.url.toString(),
      'http://10.0.2.2:50000/lan/v1/rooms/$room/join',
    );
    expect(captured.headers, isNot(contains('authorization')));
    expect(jsonDecode(captured.body), {
      'roomId': room,
      'nickname': '玩家甲',
      'joinAttemptId': attempt,
      'candidateResumeToken': token,
      'roomKey': key,
    });
  });

  test('uses the embedded LAN router prefix for HTTP and WebSocket', () {
    expect(
      endpoint.resolve('/lan/v1/rooms/$room/result').toString(),
      'http://10.0.2.2:50000/lan/v1/rooms/$room/result',
    );
    expect(endpoint.webSocketUri.toString(), 'ws://10.0.2.2:50000/lan/v1/ws');
  });

  test('rejects redirects and preserves authoritative error codes', () async {
    final redirectApi = LanApi(
      client: MockClient((_) async => http.Response('', 302)),
    );
    expect(
      () => redirectApi.join(qr, candidate, '玩家甲'),
      throwsA(
        isA<LanException>().having((e) => e.code, 'code', 'redirect_rejected'),
      ),
    );
    final rejectedApi = LanApi(
      client: MockClient(
        (_) async => http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'error': {
                'code': 'room_locked',
                'message': '房间已锁定',
                'details': <String, Object?>{},
              },
            }),
          ),
          409,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );
    expect(
      () => rejectedApi.join(qr, candidate, '玩家甲'),
      throwsA(
        isA<LanException>()
            .having((e) => e.code, 'code', 'room_locked')
            .having((e) => e.authoritative, 'authoritative', isTrue),
      ),
    );
  });
}
