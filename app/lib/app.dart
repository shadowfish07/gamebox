import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_release_updater/flutter_release_updater.dart';
import 'package:http/http.dart' as http;

import 'core/api/api_client.dart';
import 'core/auth/token_store.dart';
import 'core/platform/game_launch_request.dart';
import 'core/platform/game_launcher.dart';
import 'features/auth/auth_api.dart';
import 'features/auth/registration_page.dart';
import 'features/auth/session_controller.dart';
import 'features/gomoku/gomoku_repository.dart';
import 'features/home/home_api.dart';
import 'features/home/home_controller.dart';
import 'features/home/home_page.dart';

class GameboxApp extends StatefulWidget {
  const GameboxApp({
    super.key,
    required this.gameLauncher,
    this.sessionController,
    this.homeController,
    this.updateController,
    bool? hostSmokeEnabled,
    String? instrumentationCanaryNonce,
  }) : hostSmokeEnabled =
           hostSmokeEnabled ?? const bool.fromEnvironment('GAMEBOX_HOST_SMOKE'),
       instrumentationCanaryNonce =
           instrumentationCanaryNonce ??
           const String.fromEnvironment('GAMEBOX_INSTRUMENTATION_CANARY_NONCE');

  final GameLauncher gameLauncher;
  final SessionController? sessionController;
  final HomeController? homeController;
  final UpdateController? updateController;
  final bool hostSmokeEnabled;
  final String instrumentationCanaryNonce;

  @override
  State<GameboxApp> createState() => _GameboxAppState();
}

class _GameboxAppState extends State<GameboxApp> with WidgetsBindingObserver {
  var _isLaunchingHostSmoke = false;
  var _hostSmokeError = false;
  SessionController? _sessionController;
  ApiClient? _ownedApiClient;
  HomeController? _homeController;
  var _ownsSessionController = false;
  var _ownsHomeController = false;
  var _homeControllerAuthenticated = false;

  @override
  void initState() {
    super.initState();
    if (!widget.hostSmokeEnabled) {
      _configureAuthentication();
      unawaited(widget.updateController?.start());
    }
  }

  void _configureAuthentication() {
    final injected = widget.sessionController;
    if (injected != null) {
      _sessionController = injected;
    } else {
      final apiClient = ApiClient(httpClient: http.Client());
      _ownedApiClient = apiClient;
      _sessionController = SessionController(
        authApi: HttpAuthApi(apiClient),
        tokenStore: SecureTokenStore(),
      );
      _ownsSessionController = true;
    }
    _sessionController!.addListener(_sessionChanged);
    WidgetsBinding.instance.addObserver(this);
    _syncHomeController();
    unawaited(_sessionController!.restore());
  }

  void _sessionChanged() {
    _syncHomeController();
    if (mounted) {
      setState(() {});
    }
  }

  void _syncHomeController() {
    final sessionController = _sessionController;
    if (sessionController == null ||
        sessionController.status != SessionStatus.authenticated ||
        sessionController.session == null) {
      if (_ownsHomeController) {
        _homeController?.dispose();
        _homeController = null;
        _ownsHomeController = false;
      } else if (_homeControllerAuthenticated) {
        _homeController?.pauseForeground();
      }
      _homeControllerAuthenticated = false;
      return;
    }
    if (_homeController == null) {
      final injected = widget.homeController;
      if (injected != null) {
        _homeController = injected;
      } else {
        final apiClient = _ownedApiClient ??= ApiClient(
          httpClient: http.Client(),
        );
        _homeController = HomeController(
          repository: GomokuRepository(
            api: HttpHomeApi(apiClient, sessionController),
            gameLauncher: widget.gameLauncher,
            apiBaseUri: Uri.parse(apiBaseUrl),
          ),
        );
        _ownsHomeController = true;
      }
    }
    if (_homeControllerAuthenticated) return;
    _homeControllerAuthenticated = true;
    _homeController?.resumeForeground();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_handleAppResumed());
    } else {
      _homeController?.pauseForeground();
    }
  }

  Future<void> _handleAppResumed() async {
    final sessionController = _sessionController;
    if (sessionController == null) return;
    await sessionController.handleAppResumed();
    if (!mounted || sessionController.status != SessionStatus.authenticated) {
      return;
    }
    _syncHomeController();
    _homeController?.resumeForeground();
  }

  @override
  void dispose() {
    final controller = _sessionController;
    if (controller != null) {
      WidgetsBinding.instance.removeObserver(this);
      controller.removeListener(_sessionChanged);
      if (_ownsSessionController) {
        controller.dispose();
      }
    }
    _homeController?.pauseForeground();
    if (_ownsHomeController) {
      _homeController?.dispose();
    }
    _homeController = null;
    _homeControllerAuthenticated = false;
    _ownedApiClient?.close();
    widget.updateController?.dispose();
    super.dispose();
  }

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
      key: ValueKey<String>(_navigationBoundary),
      title: 'Gamebox',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: widget.hostSmokeEnabled ? _buildHostSmoke() : _buildAuthFlow(),
    );
  }

  String get _navigationBoundary {
    if (widget.hostSmokeEnabled) return 'host-smoke';
    final controller = _sessionController;
    final session = controller?.session;
    if (controller?.status == SessionStatus.authenticated && session != null) {
      return 'authenticated:${session.user.id}';
    }
    return 'public';
  }

  Widget _buildAuthFlow() {
    final controller = _sessionController!;
    return switch (controller.status) {
      SessionStatus.restoring => Scaffold(
        body: Center(
          child: Semantics(
            label: 'session-restoring',
            child: const CircularProgressIndicator(),
          ),
        ),
      ),
      SessionStatus.unauthenticated ||
      SessionStatus.submitting => RegistrationPage(
        controller: controller,
        updateController: widget.updateController,
      ),
      SessionStatus.authenticated => _buildAuthenticatedHome(controller),
    };
  }

  Widget _buildAuthenticatedHome(SessionController controller) {
    final session = controller.session;
    if (session == null) {
      return Scaffold(
        body: Center(
          child: Semantics(
            label: 'credential-state-invalid',
            child: const CircularProgressIndicator(),
          ),
        ),
      );
    }
    final homeController = _homeController;
    if (homeController == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return HomePage(
      controller: homeController,
      currentUserId: session.user.id,
      nickname: session.user.nickname,
      updateController: widget.updateController,
    );
  }

  Widget _buildHostSmoke() {
    return Scaffold(
      body: Center(
        child: Column(
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
                onPressed: _isLaunchingHostSmoke ? null : _launchHostSmoke,
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
        ),
      ),
    );
  }
}
