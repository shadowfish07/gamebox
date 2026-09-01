import 'package:flutter/services.dart';

abstract interface class NicknameRules {
  Future<String> normalize(String raw);
}

final class NicknameValidationFailure implements Exception {
  const NicknameValidationFailure();

  @override
  String toString() => 'NicknameValidationFailure()';
}

final class NicknameRulesUnavailable implements Exception {
  const NicknameRulesUnavailable();

  @override
  String toString() => 'NicknameRulesUnavailable()';
}

final class MethodChannelNicknameRules implements NicknameRules {
  const MethodChannelNicknameRules();

  static const _channel = MethodChannel('me.zqydev.gamebox/app_profile');

  @override
  Future<String> normalize(String raw) async {
    try {
      final response = await _channel.invokeMapMethod<String, Object?>(
        'normalizeNickname',
        <String, Object?>{'nickname': raw},
      );
      if (response == null ||
          response.length != 1 ||
          response['nickname'] is! String ||
          (response['nickname']! as String).isEmpty) {
        throw const NicknameRulesUnavailable();
      }
      return response['nickname']! as String;
    } on PlatformException catch (error) {
      if (error.code == 'invalid_nickname') {
        throw const NicknameValidationFailure();
      }
      throw const NicknameRulesUnavailable();
    } on MissingPluginException {
      throw const NicknameRulesUnavailable();
    }
  }
}
