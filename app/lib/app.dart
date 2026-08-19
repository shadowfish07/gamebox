import 'package:flutter/material.dart';

import 'core/platform/game_launch_request.dart';
import 'core/platform/game_launcher.dart';

class GameboxApp extends StatefulWidget {
  const GameboxApp({
    super.key,
    required this.gameLauncher,
    bool? hostSmokeEnabled,
    String? instrumentationCanaryNonce,
  }) : hostSmokeEnabled =
           hostSmokeEnabled ?? const bool.fromEnvironment('GAMEBOX_HOST_SMOKE'),
       instrumentationCanaryNonce =
           instrumentationCanaryNonce ??
           const String.fromEnvironment('GAMEBOX_INSTRUMENTATION_CANARY_NONCE');

  final GameLauncher gameLauncher;
  final bool hostSmokeEnabled;
  final String instrumentationCanaryNonce;

  @override
  State<GameboxApp> createState() => _GameboxAppState();
}

class _GameboxAppState extends State<GameboxApp> {
  var _isLaunchingHostSmoke = false;
  var _hostSmokeError = false;

  bool get _canLaunchInstrumentationCanary => RegExp(
    r'^[A-Za-z0-9_-]{8,64}$',
  ).hasMatch(widget.instrumentationCanaryNonce);

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

  Future<void> _launchInstrumentationCanary({String gameId = 'gomoku'}) async {
    if (_isLaunchingHostSmoke || !_canLaunchInstrumentationCanary) {
      return;
    }
    setState(() {
      _isLaunchingHostSmoke = true;
      _hostSmokeError = false;
    });
    try {
      await widget.gameLauncher.launch(
        GameLaunchRequest(
          gameId: gameId,
          matchId: '11111111-1111-4111-8111-111111111111',
          launchTicket:
              'gamebox-canary-ticket-${widget.instrumentationCanaryNonce}',
          wsUrl: 'ws://127.0.0.1:65535/canary',
        ),
      );
    } on GameLaunchException {
      if (mounted) {
        setState(() => _hostSmokeError = true);
      }
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
                    Semantics(
                      key: const Key('host-smoke.launch'),
                      label: 'host-smoke.launch',
                      button: true,
                      enabled: !_isLaunchingHostSmoke,
                      onTap: _isLaunchingHostSmoke ? null : _launchHostSmoke,
                      excludeSemantics: true,
                      child: FilledButton(
                        onPressed: _isLaunchingHostSmoke
                            ? null
                            : _launchHostSmoke,
                        child: const Text('启动宿主烟测'),
                      ),
                    ),
                    if (_canLaunchInstrumentationCanary) ...[
                      const SizedBox(height: 12),
                      Semantics(
                        key: const Key('host-smoke.normal-canary'),
                        label: 'host-smoke.normal-canary',
                        button: true,
                        enabled: !_isLaunchingHostSmoke,
                        onTap: _isLaunchingHostSmoke
                            ? null
                            : _launchInstrumentationCanary,
                        excludeSemantics: true,
                        child: OutlinedButton(
                          onPressed: _isLaunchingHostSmoke
                              ? null
                              : _launchInstrumentationCanary,
                          child: const Text('启动普通启动验证'),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Semantics(
                        key: const Key('host-smoke.collision-canary'),
                        label: 'host-smoke.collision-canary',
                        button: true,
                        enabled: !_isLaunchingHostSmoke,
                        onTap: _isLaunchingHostSmoke
                            ? null
                            : () => _launchInstrumentationCanary(
                                gameId: '--launch-ticket',
                              ),
                        excludeSemantics: true,
                        child: OutlinedButton(
                          onPressed: _isLaunchingHostSmoke
                              ? null
                              : () => _launchInstrumentationCanary(
                                  gameId: '--launch-ticket',
                                ),
                          child: const Text('启动参数碰撞验证'),
                        ),
                      ),
                    ],
                    if (_hostSmokeError) ...[
                      const SizedBox(height: 16),
                      Semantics(
                        label: 'host-smoke.error',
                        excludeSemantics: true,
                        child: const Text('无法启动宿主烟测，请重试'),
                      ),
                    ],
                  ],
                )
              : const Text('身份功能将在 Phase 3 接入'),
        ),
      ),
    );
  }
}
