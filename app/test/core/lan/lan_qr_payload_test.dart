import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/core/lan/lan_models.dart';
import 'package:gamebox/core/lan/lan_qr_payload.dart';
import 'package:gamebox/core/lan/private_ipv4.dart';

void main() {
  const room = '11111111-1111-4111-8111-111111111111';
  const key = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
  final now = DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true);
  final endpoint = LanEndpoint(
    host: PrivateIpv4.parse('10.0.2.2'),
    port: 54321,
  );

  test('join QR round trips canonically without exposing its key', () {
    final qr = LanJoinQr(
      roomId: room,
      endpoint: endpoint,
      roomKey: key,
      expiresAt: now.add(const Duration(minutes: 10)),
    );
    final encoded = qr.encode();
    final decoded = LanQrPayload.parse(encoded, now) as LanJoinQr;
    expect(decoded.roomId, room);
    expect(decoded.endpoint, endpoint);
    expect(decoded.roomKey, key);
    expect(decoded.encode(), encoded);
    expect(decoded.toString(), isNot(contains(key)));
  });

  test('resume QR contains no credential and round trips', () {
    final qr = LanResumeQr(roomId: room, endpoint: endpoint);
    expect(
      qr.encode(),
      'gamebox-lan://resume?v=1&room=$room&host=10.0.2.2&port=54321',
    );
    expect(LanQrPayload.parse(qr.encode(), now), isA<LanResumeQr>());
    expect(qr.encode(), isNot(contains('key=')));
  });

  test('rejects unknown, duplicate, malformed, expired and unsafe QR values', () {
    final valid =
        'gamebox-lan://join?v=1&room=$room&host=10.0.2.2&port=54321&key=$key&exp=1700000001000';
    final invalid = <String>[
      '$valid&x=1',
      '$valid&port=54321',
      valid.replaceFirst('v=1', 'v=01'),
      valid.replaceFirst(
        room,
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'.toUpperCase(),
      ),
      valid.replaceFirst('host=10.0.2.2', 'host=8.8.8.8'),
      valid.replaceFirst('port=54321', 'port=054321'),
      valid.replaceFirst(key, '${key}A'),
      '$valid#fragment',
      valid.replaceFirst('gamebox-lan://', 'gamebox-lan://user@'),
    ];
    for (final value in invalid) {
      expect(
        () => LanQrPayload.parse(value, now),
        throwsA(isA<LanException>()),
        reason: value,
      );
    }
    expect(
      () => LanQrPayload.parse(valid, now.add(const Duration(seconds: 2))),
      throwsA(
        isA<LanException>().having((e) => e.code, 'code', 'join_expired'),
      ),
    );
  });
}
