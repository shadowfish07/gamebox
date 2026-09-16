import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_release_updater/flutter_release_updater.dart';
import 'package:http/http.dart' as http;

import 'core/api/api_client.dart';
import 'core/auth/token_store.dart';
import 'core/platform/game_launch_request.dart';
import 'core/platform/game_launcher.dart';
import 'design_system/generated/gamebox_tokens.g.dart';
import 'design_system/gamebox_theme.dart';
import 'features/reversi/reversi_models.dart';
import 'features/reversi/reversi_launcher.dart';
import 'features/auth/auth_api.dart';
import 'features/auth/device_transfer.dart';
import 'features/auth/device_transfer_page.dart';
import 'features/scratch/scratch_controller.dart';
import 'features/scratch/scratch_social_api.dart';
import 'features/auth/registration_page.dart';
import 'features/auth/session_controller.dart';
import 'features/gomoku/gomoku_models.dart';
import 'features/gomoku/gomoku_repository.dart';
import 'features/history/match_history_api.dart';
import 'features/home/home_api.dart';
import 'features/home/home_controller.dart';
import 'features/home/home_page.dart';
import 'features/rps/rps_api.dart';
import 'features/rps/rps_controller.dart';
import 'features/rps/rps_repository.dart';

class GameboxApp extends StatefulWidget {
  const GameboxApp({
    super.key,
    required this.gameLauncher,
    this.sessionController,
    this.deviceTransfer,
    this.homeController,
    this.matchHistoryApi,
    this.rpsController,
    this.chineseCheckersController,
    this.flightChessController,
    this.reversiController,
    this.updateController,
    bool? hostSmokeEnabled,
    String? instrumentationCanaryNonce,
  }) : assert(deviceTransfer == null || sessionController != null),
       hostSmokeEnabled =
           hostSmokeEnabled ?? const bool.fromEnvironment('GAMEBOX_HOST_SMOKE'),
       instrumentationCanaryNonce =
           instrumentationCanaryNonce ??
           const String.fromEnvironment('GAMEBOX_INSTRUMENTATION_CANARY_NONCE');

  final GameLauncher gameLauncher;
  final SessionController? sessionController;
  final DeviceTransfer? deviceTransfer;
  final HomeController? homeController;
  final MatchHistoryApi? matchHistoryApi;
  final RpsController? rpsController;
  final HomeController? chineseCheckersController;
  final HomeController? flightChessController;
  final HomeController? reversiController;
  final UpdateController? updateController;
  final bool hostSmokeEnabled;
  final String instrumentationCanaryNonce;

  @override
  State<GameboxApp> createState() => _GameboxAppState();
}

class _GameboxAppState extends State<GameboxApp> with WidgetsBindingObserver {
  DeviceTransfer? _transfer;
  bool _ownsTransfer = false;
  bool _preparingTransfer = false;
  bool _recoveringOutgoing = false;
  var _navigatorKey = GlobalKey<NavigatorState>();
  String? _navigatorBoundary;
  var _isLaunchingHostSmoke = false;
  var _hostSmokeError = false;
  SessionController? _sessionController;
  ApiClient? _ownedApiClient;
  HomeController? _homeController;
  HomeController? _chineseCheckersController;
  HomeController? _flightChessController;
  HomeController? _reversiController;
  RpsController? _rpsController;
  var _ownsSessionController = false;
  var _ownsHomeController = false;
  var _ownsChineseCheckersController = false;
  var _ownsFlightChessController = false;
  var _ownsReversiController = false;
  var _ownsRpsController = false;
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
      _transfer = widget.deviceTransfer;
      assert(_transfer == null || identical(_transfer!.session, injected));
    } else {
      final apiClient = ApiClient(httpClient: http.Client());
      _ownedApiClient = apiClient;
      _sessionController = SessionController(
        authApi: HttpAuthApi(apiClient),
        tokenStore: SecureTokenStore(),
      );
      _ownsSessionController = true;
      _transfer = DeviceTransfer(
        api: apiClient,
        session: _sessionController!,
        store: SecureTransferStore(),
        scratchStore: SecureScratchStore(),
      );
      _ownsTransfer = true;
    }
    _transfer?.addListener(_transferChanged);
    _preparingTransfer = _transfer != null;
    _sessionController!.addListener(_sessionChanged);
    WidgetsBinding.instance.addObserver(this);
    _syncHomeController();
    unawaited(_restoreWithTransfer());
  }

  void _transferChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _restoreWithTransfer() async {
    await _transfer?.restoreIncoming();
    if (_transfer?.incoming != true &&
        _sessionController!.status != SessionStatus.authenticated) {
      await _sessionController!.restore();
    }
    if (_transfer?.incoming != true && _transfer?.outgoing == true) {
      await _transfer!.cancelOutgoing();
      _recoveringOutgoing = _transfer!.outgoing;
    }
    if (mounted) setState(() => _preparingTransfer = false);
  }

  void _sessionChanged() {
    if (_transfer?.outgoing == true &&
        _sessionController!.status != SessionStatus.authenticated) {
      _recoveringOutgoing = true;
    }
    _syncHomeController();
    if (_sessionController!.status == SessionStatus.authenticated &&
        _sessionController!.migratedIn) {
      _sessionController!.migratedIn = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final context = _navigatorKey.currentContext;
        if (mounted && context != null) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('账号已迁入')));
        }
      });
    }
    if (mounted) {
      setState(() {});
    }
  }

  void _syncHomeController() {
    // Authentication boundaries must create a new navigator; reusing a global
    // key would reparent protected routes into the next session.
    final boundary = _navigationBoundary;
    if (_navigatorBoundary != boundary) {
      _navigatorBoundary = boundary;
      _navigatorKey = GlobalKey<NavigatorState>();
    }
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
      if (_ownsRpsController) {
        _rpsController?.dispose();
        _rpsController = null;
        _ownsRpsController = false;
      } else if (_homeControllerAuthenticated) {
        _rpsController?.pauseForeground();
      }
      if (_ownsChineseCheckersController) {
        _chineseCheckersController?.dispose();
        _chineseCheckersController = null;
        _ownsChineseCheckersController = false;
      } else if (_homeControllerAuthenticated) {
        _chineseCheckersController?.pauseForeground();
      }
      if (_ownsFlightChessController) {
        _flightChessController?.dispose();
        _flightChessController = null;
        _ownsFlightChessController = false;
      } else if (_homeControllerAuthenticated) {
        _flightChessController?.pauseForeground();
      }
      if (_ownsReversiController) {
        _reversiController?.dispose();
        _reversiController = null;
        _ownsReversiController = false;
      } else if (_homeControllerAuthenticated) {
        _reversiController?.pauseForeground();
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
    if (_rpsController == null &&
        (widget.rpsController != null || widget.homeController == null)) {
      final injected = widget.rpsController;
      if (injected != null) {
        _rpsController = injected;
      } else {
        final apiClient = _ownedApiClient ??= ApiClient(
          httpClient: http.Client(),
        );
        _rpsController = RpsController(
          repository: RpsRepository(
            api: HttpRpsApi(apiClient, sessionController),
            gameLauncher: widget.gameLauncher,
            apiBaseUri: Uri.parse(apiBaseUrl),
          ),
        );
        _ownsRpsController = true;
      }
    }
    if (_chineseCheckersController == null &&
        (widget.chineseCheckersController != null ||
            widget.homeController == null)) {
      final injected = widget.chineseCheckersController;
      if (injected != null) {
        _chineseCheckersController = injected;
      } else {
        final apiClient = _ownedApiClient ??= ApiClient(
          httpClient: http.Client(),
        );
        _chineseCheckersController = HomeController(
          repository: GomokuRepository(
            api: HttpHomeApi(
              apiClient,
              sessionController,
              gameId: chineseCheckersGameId,
            ),
            gameLauncher: widget.gameLauncher,
            gameId: chineseCheckersGameId,
            apiBaseUri: Uri.parse(apiBaseUrl),
          ),
        );
        _ownsChineseCheckersController = true;
      }
    }
    if (_flightChessController == null &&
        (widget.flightChessController != null ||
            widget.homeController == null)) {
      final injected = widget.flightChessController;
      if (injected != null) {
        _flightChessController = injected;
      } else {
        final apiClient = _ownedApiClient ??= ApiClient(
          httpClient: http.Client(),
        );
        _flightChessController = HomeController(
          repository: GomokuRepository(
            api: HttpHomeApi(
              apiClient,
              sessionController,
              gameId: flightChessGameId,
            ),
            gameLauncher: widget.gameLauncher,
            gameId: flightChessGameId,
            apiBaseUri: Uri.parse(apiBaseUrl),
          ),
        );
        _ownsFlightChessController = true;
      }
    }
    if (_reversiController == null &&
        (widget.reversiController != null || widget.homeController == null)) {
      final injected = widget.reversiController;
      if (injected != null) {
        _reversiController = injected;
      } else {
        final apiClient = _ownedApiClient ??= ApiClient(
          httpClient: http.Client(),
        );
        _reversiController = HomeController(
          repository: GomokuRepository(
            api: HttpHomeApi(
              apiClient,
              sessionController,
              gameId: reversiGameId,
            ),
            gameLauncher: ReversiLauncher(
              navigatorKey: _navigatorKey,
              api: HttpHomeApi(
                apiClient,
                sessionController,
                gameId: reversiGameId,
              ),
            ),
            gameId: reversiGameId,
            apiBaseUri: Uri.parse(apiBaseUrl),
          ),
        );
        _ownsReversiController = true;
      }
    }
    if (_homeControllerAuthenticated) return;
    _homeControllerAuthenticated = true;
    _homeController?.resumeForeground();
    _rpsController?.resumeForeground();
    _chineseCheckersController?.resumeForeground();
    _flightChessController?.resumeForeground();
    _reversiController?.resumeForeground();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_handleAppResumed());
    } else {
      _homeController?.pauseForeground();
      _rpsController?.pauseForeground();
      _chineseCheckersController?.pauseForeground();
      _flightChessController?.pauseForeground();
      _reversiController?.pauseForeground();
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
    _rpsController?.resumeForeground();
    _chineseCheckersController?.resumeForeground();
    _flightChessController?.resumeForeground();
    _reversiController?.resumeForeground();
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
    if (_ownsRpsController) {
      _rpsController?.dispose();
    }
    if (_ownsChineseCheckersController) {
      _chineseCheckersController?.dispose();
    }
    if (_ownsFlightChessController) {
      _flightChessController?.dispose();
    }
    if (_ownsReversiController) {
      _reversiController?.dispose();
    }
    _homeController = null;
    _rpsController = null;
    _chineseCheckersController = null;
    _flightChessController = null;
    _reversiController = null;
    _homeControllerAuthenticated = false;
    _transfer?.removeListener(_transferChanged);
    if (_ownsTransfer) _transfer?.dispose();
    _ownedApiClient?.close();
    widget.updateController?.dispose();
    super.dispose();
  }

  bool get _canLaunchInstrumentationCanary =>
      RegExp(r'^[A-Za-z0-9_-]{8,64}$')
          .hasMatch(widget.instrumentationCanaryNonce);

  Future<void> _launchHostSmoke({String? previewGame}) async {
    if (_isLaunchingHostSmoke) {
      return;
    }
    setState(() {
      _isLaunchingHostSmoke = true;
      _hostSmokeError = false;
    });
    try {
      await widget.gameLauncher.launchHostSmoke(previewGame: previewGame);
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
      navigatorKey: _navigatorKey,
      title: 'Gamebox',
      theme: GameboxTheme.light(),
      darkTheme: GameboxTheme.dark(),
      themeMode: ThemeMode.system,
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
    if (_preparingTransfer) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_transfer case final transfer?) {
      if (transfer.incoming) return DeviceTransferPage(transfer: transfer);
      if (_recoveringOutgoing && transfer.outgoing) {
        return Scaffold(
          appBar: AppBar(title: const Text('恢复换机状态')),
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(transfer.error ?? '正在恢复'),
                TextButton(
                  onPressed: transfer.busy
                      ? null
                      : () async {
                          if (controller.canRetryRestore) {
                            await controller.retryRestore();
                          }
                          await transfer.cancelOutgoing();
                        },
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        );
      }
    }
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
        transfer: _transfer,
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
    final MatchHistoryApi historyApi;
    if (widget.matchHistoryApi case final injected?) {
      historyApi = injected;
    } else {
      final apiClient = _ownedApiClient ??= ApiClient(
        httpClient: http.Client(),
      );
      historyApi = HttpMatchHistoryApi(apiClient, controller);
    }
    return HomePage(
      transfer: _transfer,
      scratchApi: HttpScratchSocialApi(
        _ownedApiClient ??= ApiClient(),
        controller,
      ),
      controller: homeController,
      currentUserId: session.user.id,
      nickname: session.user.nickname,
      historyApi: historyApi,
      rpsController: _rpsController,
      chineseCheckersController: _chineseCheckersController,
      flightChessController: _flightChessController,
      reversiController: _reversiController,
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
              onTap: _isLaunchingHostSmoke ? null : () => _launchHostSmoke(),
              excludeSemantics: true,
              child: FilledButton(
                onPressed: _isLaunchingHostSmoke
                    ? null
                    : () => _launchHostSmoke(),
                child: const Text('启动宿主烟测'),
              ),
            ),
            SizedBox(height: GameboxTokens.spacing.compact),
            Semantics(
              key: const Key('host-smoke.flight-chess-preview'),
              label: 'host-smoke.flight-chess-preview',
              button: true,
              enabled: !_isLaunchingHostSmoke,
              onTap: _isLaunchingHostSmoke
                  ? null
                  : () => _launchHostSmoke(previewGame: 'flight_chess'),
              excludeSemantics: true,
              child: OutlinedButton(
                onPressed: _isLaunchingHostSmoke
                    ? null
                    : () => _launchHostSmoke(previewGame: 'flight_chess'),
                child: const Text('预览飞行棋横屏'),
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
