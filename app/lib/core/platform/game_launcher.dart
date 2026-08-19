import 'game_launch_request.dart';

abstract interface class GameLauncher {
  Future<void> launch(GameLaunchRequest request);

  Future<void> launchHostSmoke();
}
