import 'package:flutter/material.dart';

import 'core/platform/game_launcher.dart';

class GameboxApp extends StatefulWidget {
  const GameboxApp({
    super.key,
    required this.gameLauncher,
    bool? hostSmokeEnabled,
  }) : hostSmokeEnabled =
           hostSmokeEnabled ?? const bool.fromEnvironment('GAMEBOX_HOST_SMOKE');

  final GameLauncher gameLauncher;
  final bool hostSmokeEnabled;

  @override
  State<GameboxApp> createState() => _GameboxAppState();
}

class _GameboxAppState extends State<GameboxApp> {
  var _isLaunchingHostSmoke = false;
  var _hostSmokeError = false;

  Future<void> _launchHostSmoke() async {
    if (_isLaunchingHostSmoke) {
      return;
    }
    setState(() {
      _isLaunchingHostSmoke = true;
      _hostSmokeError = false;
    });
    try {
      await widget.gameLauncher.launchHostSmoke();
    } on GameLaunchException {
      if (mounted) {
        setState(() => _hostSmokeError = true);
      }
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'Gamebox',
          context: ErrorDescription('launching host smoke'),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isLaunchingHostSmoke = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gamebox',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: Scaffold(
        body: Center(
          child: widget.hostSmokeEnabled
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FilledButton(
                      key: const Key('host-smoke.launch'),
                      onPressed: _isLaunchingHostSmoke
                          ? null
                          : _launchHostSmoke,
                      child: const Text('启动宿主烟测'),
                    ),
                    if (_hostSmokeError) ...[
                      const SizedBox(height: 16),
                      const Text('无法启动宿主烟测，请重试'),
                    ],
                  ],
                )
              : const Text('身份功能将在 Phase 3 接入'),
        ),
      ),
    );
  }
}
