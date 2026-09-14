import 'package:flutter/services.dart';
import 'package:flutter/material.dart';

import '../../core/platform/game_launch_request.dart';
import '../../core/platform/game_launcher.dart';
import '../home/home_api.dart';
import 'reversi_controller.dart';
import 'reversi_page.dart';

final class ReversiLauncher implements GameLauncher {
  ReversiLauncher({required this.navigatorKey, required this.api});
  final GlobalKey<NavigatorState> navigatorKey;
  final HomeApi api;
  @override
  Future<void> launch(GameLaunchRequest request) async {
    final navigator = navigatorKey.currentState;
    if (navigator == null || request.gameId != 'reversi') {
      throw const GameLaunchException('invalid_state');
    }
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    final controller = ReversiController(
      request: request,
      freshTicket: () async =>
          (await api.createLaunchTicket(request.matchId)).launchTicket,
    );
    try {
      await navigator.push<void>(
        MaterialPageRoute(builder: (_) => ReversiPage(controller: controller)),
      );
    } finally {
      await SystemChrome.setPreferredOrientations([]);
    }
  }

  @override
  Future<void> launchHostSmoke({String? previewGame}) async {
    throw const GameLaunchException('unsupported');
  }
}
