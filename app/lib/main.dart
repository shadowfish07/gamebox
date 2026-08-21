import 'package:flutter/material.dart';

import 'app.dart';
import 'core/platform/method_channel_game_launcher.dart';
import 'features/update/update_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  UpdateController? updateController;
  try {
    updateController = await UpdateController.production();
  } on Object catch (error, stackTrace) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'Gamebox updater',
        context: ErrorDescription('initializing the optional update service'),
      ),
    );
  }
  runApp(
    GameboxApp(
      gameLauncher: MethodChannelGameLauncher(),
      updateController: updateController,
    ),
  );
}
