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
      await _channel.invokeMethod<void>('launchGame', {
        'gameId': request.gameId,
        'matchId': request.matchId,
        'launchTicket': request.launchTicket,
        'wsUrl': request.wsUrl,
        'source': request.source.name,
        'resumeToken': request.resumeToken,
        'localUserId': request.localUserId,
      });
    } on PlatformException catch (error) {
      throw GameLaunchException(error.code);
    } on MissingPluginException {
      throw const GameLaunchException('missing_plugin');
    }
  }

  @override
  Future<void> launchHostSmoke() async {
    try {
      await _channel.invokeMethod<void>('launchHostSmoke');
    } on PlatformException catch (error) {
      throw GameLaunchException(error.code);
    } on MissingPluginException {
      throw const GameLaunchException('missing_plugin');
    }
  }
}
