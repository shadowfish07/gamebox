import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/core/platform/lan_host_platform.dart';
import 'package:gamebox/core/platform/method_channel_lan_host_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/lan-host');

  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  test(
    'decodes exact version one host maps and redacts creation secret',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'createRoom');
            expect(call.arguments, {'nickname': '玩家甲'});
            return {
              'schemaVersion': 1,
              'state': 'waiting',
              'roomId': '11111111-1111-4111-8111-111111111111',
              'port': 50000,
              'gameRevision': 0,
              'endpointChanged': false,
              'endpoint': '192.168.4.1:50000',
              'roomKey': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
              'joinExpiresAt': 1900000000000,
            };
          });
      final created = await MethodChannelLanHostPlatform(channel: channel)
          .createRoom('玩家甲');
      expect(created.status.endpoint!.encoded, '192.168.4.1:50000');
      expect(created.toString(), isNot(contains(created.roomKey)));
    },
  );

  test('rejects unknown native response fields', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) async => {
            'schemaVersion': 1,
            'state': 'empty',
            'roomId': null,
            'port': 0,
            'gameRevision': 0,
            'endpointChanged': false,
            'endpoint': null,
            'unknown': true,
          },
        );
    expect(
      () => MethodChannelLanHostPlatform(channel: channel).getStatus(),
      throwsA(
        isA<LanHostException>().having(
          (e) => e.code,
          'code',
          'invalid_response',
        ),
      ),
    );
  });
}
