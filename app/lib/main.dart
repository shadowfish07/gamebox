import 'package:flutter/material.dart';

import 'app.dart';
import 'core/platform/method_channel_game_launcher.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(GameboxApp(gameLauncher: MethodChannelGameLauncher()));
}
