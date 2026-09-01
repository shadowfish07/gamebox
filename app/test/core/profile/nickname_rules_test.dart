import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/core/profile/nickname_rules.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('me.zqydev.gamebox/app_profile');

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('platform normalization returns the Go display spelling', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'normalizeNickname');
          expect(call.arguments, <String, Object?>{'nickname': ' Alice 中 '});
          return <String, Object?>{'nickname': 'Alice 中'};
        });

    expect(
      await const MethodChannelNicknameRules().normalize(' Alice 中 '),
      'Alice 中',
    );
  });

  test('stable platform rejection becomes a safe validation failure', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(
            code: 'invalid_nickname',
            message: 'private native detail',
          );
        });

    await expectLater(
      const MethodChannelNicknameRules().normalize('A\u202eB'),
      throwsA(isA<NicknameValidationFailure>()),
    );
  });
}
