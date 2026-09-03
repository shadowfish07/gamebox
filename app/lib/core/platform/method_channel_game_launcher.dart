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
      });
    } on PlatformException catch (error) {
      throw GameLaunchException(error.code);
    } on MissingPluginException {
      throw const GameLaunchException('missing_plugin');
    }
  }

  @override
  Future<void> launchHostSmoke({String? previewGame}) async {
    if (previewGame != null && previewGame != 'flight_chess') {
      throw const GameLaunchException('invalid_preview_game');
    }
    try {
      final method = previewGame == 'flight_chess'
          ? 'launchFlightChessPreview'
          : 'launchHostSmoke';
      await _channel.invokeMethod<void>(method);
    } on PlatformException catch (error) {
      throw GameLaunchException(error.code);
    } on MissingPluginException {
      throw const GameLaunchException('missing_plugin');
    }
  }
}
