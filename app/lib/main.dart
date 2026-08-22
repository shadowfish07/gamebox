import 'package:flutter/material.dart';
import 'package:flutter_release_updater/flutter_release_updater.dart';

import 'app.dart';
import 'core/platform/method_channel_game_launcher.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  UpdateController? updateController;
  try {
    updateController = await UpdateController.production(
      repository: 'shadowfish07/gamebox',
      userAgent: 'Gamebox-update-check',
      cacheKeyPrefix: 'update',
    );
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
