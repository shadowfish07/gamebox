import 'game_launch_request.dart';

abstract interface class GameLauncher {
  Future<void> launch(GameLaunchRequest request);

  Future<void> launchHostSmoke();
}

final class GameLaunchException implements Exception {
  const GameLaunchException(this.code);

  final String code;

  @override
  String toString() => 'GameLaunchException';
}
