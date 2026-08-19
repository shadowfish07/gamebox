import 'package:flutter/services.dart';

import 'game_launch_request.dart';
import 'game_launcher.dart';

class MethodChannelGameLauncher implements GameLauncher {
  MethodChannelGameLauncher({MethodChannel? channel})
    : _channel = channel ?? _defaultChannel;

  static const MethodChannel _defaultChannel = MethodChannel(
    'me.zqydev.gamebox/game_launcher',
  );

  final MethodChannel _channel;

  @override
  Future<void> launch(GameLaunchRequest request) async {
    try {
      await _channel.invokeMethod<void>('launchGame', request.toArguments());
    } on PlatformException catch (error) {
      throw GameLaunchPlatformException(error.code);
    }
  }

  @override
  Future<void> launchHostSmoke() async {
    try {
      await _channel.invokeMethod<void>('launchHostSmoke');
    } on PlatformException catch (error) {
      throw GameLaunchPlatformException(error.code);
    }
  }
}

class GameLaunchPlatformException implements Exception {
  const GameLaunchPlatformException(this.code);

  final String code;

  @override
  String toString() => 'GameLaunchPlatformException';
}
