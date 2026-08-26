import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_release_updater/flutter_release_updater.dart';
import 'package:http/http.dart' as http;

import 'core/api/api_client.dart';
import 'core/auth/token_store.dart';
import 'core/lan/lan_api.dart';
import 'core/lan/lan_credential_store.dart';
import 'core/platform/game_launch_request.dart';
import 'core/platform/game_launcher.dart';
import 'core/platform/method_channel_lan_host_platform.dart';
import 'core/platform/method_channel_game_results_platform.dart';
import 'core/profile/app_profile_store.dart';
import 'core/profile/nickname_rules.dart';
import 'design_system/components/gamebox_async_panel.dart';
import 'design_system/components/gamebox_page_body.dart';
import 'design_system/gamebox_theme.dart';
import 'design_system/generated/gamebox_tokens.g.dart';
import 'features/auth/auth_api.dart';
import 'features/auth/registration_page.dart';
import 'features/auth/session_controller.dart';
import 'features/gomoku/gomoku_repository.dart';
import 'features/history/match_history_api.dart';
import 'features/home/home_api.dart';
import 'features/home/home_controller.dart';
import 'features/home/home_page.dart';
import 'features/history/game_history_controller.dart';
import 'features/history/game_history_page.dart';
import 'features/history/game_history_store.dart';
import 'features/lan/lan_mode_page.dart';
import 'features/lan/lan_recovery_card.dart';
import 'features/lan/lan_room_controller.dart';
import 'features/profile/nickname_page.dart';
import 'features/profile/profile_controller.dart';

class GameboxApp extends StatefulWidget {
  const GameboxApp({
    super.key,
    required this.gameLauncher,
    this.sessionController,
    this.profileController,
    this.homeController,
    this.matchHistoryApi,
    this.updateController,
    this.lanRoomController,
    bool? hostSmokeEnabled,
    String? instrumentationCanaryNonce,
  }) : hostSmokeEnabled =
           hostSmokeEnabled ?? const bool.fromEnvironment('GAMEBOX_HOST_SMOKE'),
       instrumentationCanaryNonce =
           instrumentationCanaryNonce ??
           const String.fromEnvironment('GAMEBOX_INSTRUMENTATION_CANARY_NONCE');

  final GameLauncher gameLauncher;
  final SessionController? sessionController;
  final ProfileController? profileController;
  final HomeController? homeController;
  final MatchHistoryApi? matchHistoryApi;
  final UpdateController? updateController;
  final LanRoomController? lanRoomController;
  final bool hostSmokeEnabled;
  final String instrumentationCanaryNonce;

  @override
  State<GameboxApp> createState() => _GameboxAppState();
}

class _GameboxAppState extends State<GameboxApp> with WidgetsBindingObserver {
  final _navigatorKey = GlobalKey<NavigatorState>();
  final _routeObserver = _AppRouteObserver();
  var _isLaunchingHostSmoke = false;
  var _hostSmokeError = false;
  SessionController? _sessionController;
  ProfileController? _profileController;
  ApiClient? _ownedApiClient;
  HomeController? _homeController;
  var _ownsSessionController = false;
  var _ownsProfileController = false;
  var _ownsHomeController = false;
  var _homeControllerAuthenticated = false;
  String? _protectedNavigationUserId;
  LanRoomController? _lanRoomController;
  var _ownsLanRoomController = false;
  var _lanInitialized = false;
  late final GameHistoryController _historyController;

  @override
  void initState() {
    super.initState();
    if (!widget.hostSmokeEnabled) {
      _configureProfile();
      _configureHistory();
      _configureAuthentication();
      _configureLan();
      unawaited(widget.updateController?.start());
    }
  }

  void _configureHistory() {
    _historyController = GameHistoryController(
      platform: MethodChannelGameResultsPlatform(),
      store: GameHistoryStore(),
      lanApi: LanApi(),
      credentials: LanCredentialStore(),
    );
    unawaited(_historyController.refresh());
  }

  void _configureLan() {
    final injected = widget.lanRoomController;
    if (injected != null) {
      _lanRoomController = injected;
    } else {
      _lanRoomController = LanRoomController(
        host: MethodChannelLanHostPlatform(),
        api: LanApi(),
        credentialStore: LanCredentialStore(),
        gameLauncher: widget.gameLauncher,
      );
      _ownsLanRoomController = true;
    }
    _lanRoomController!.addListener(_lanChanged);
  }

  void _lanChanged() {
    unawaited(_historyController.refresh());
    if (mounted) setState(() {});
  }

  void _configureProfile() {
    final injected = widget.profileController;
    if (injected != null) {
      _profileController = injected;
    } else {
      _profileController = ProfileController(
        store: LocalAppProfileStore(),
        nicknameRules: const MethodChannelNicknameRules(),
      );
      _ownsProfileController = true;
    }
    _profileController!.addListener(_profileChanged);
    unawaited(_profileController!.load());
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
    _protectedNavigationUserId = _authenticatedUserId;
    WidgetsBinding.instance.addObserver(this);
    _syncHomeController();
    _syncSessionProfile();
    unawaited(_sessionController!.restore());
  }

  void _profileChanged() {
    if (mounted) setState(() {});
  }

  void _sessionChanged() {
    final previousUserId = _protectedNavigationUserId;
    final currentUserId = _authenticatedUserId;
    if (previousUserId != null && previousUserId != currentUserId) {
      _routeObserver.discardPublicRoutes(_navigatorKey.currentState);
    }
    _protectedNavigationUserId = currentUserId;
    _syncHomeController();
    _syncSessionProfile();
    if (mounted) {
      setState(() {});
    }
  }

  void _syncSessionProfile() {
    final sessionController = _sessionController;
    final profileController = _profileController;
    final session = sessionController?.session;
    if (profileController == null ||
        sessionController == null ||
        sessionController.status != SessionStatus.authenticated ||
        session == null) {
      profileController?.disconnectPublicSession();
      return;
    }
    unawaited(
      profileController.authenticatedSessionStarted(
        userId: session.user.id,
        serverNickname: session.user.nickname,
        updateNickname: sessionController.updateNickname,
      ),
    );
  }

  String? get _authenticatedUserId {
    final controller = _sessionController;
    if (controller?.status != SessionStatus.authenticated) return null;
    return controller?.session?.user.id;
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
      _historyController.fetchPublicResult = null;
      _historyController.publicUserId = null;
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
    _historyController.publicUserId = sessionController.session!.user.id;
    if (_homeControllerAuthenticated) return;
    _homeControllerAuthenticated = true;
    _historyController.fetchPublicResult = _homeController?.fetchResult;
    unawaited(_historyController.refresh());
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
    unawaited(_lanRoomController?.handleAppResumed());
    final sessionController = _sessionController;
    if (sessionController != null) {
      await sessionController.handleAppResumed();
      if (!mounted) return;
      _syncHomeController();
    }
    await _historyController.refresh();
    if (sessionController == null ||
        sessionController.status != SessionStatus.authenticated) {
      return;
    }
    _syncSessionProfile();
    await _profileController?.handleAppResumed();
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
    final profileController = _profileController;
    if (profileController != null) {
      profileController.removeListener(_profileChanged);
      if (_ownsProfileController) profileController.dispose();
    }
    _homeController?.pauseForeground();
    if (_ownsHomeController) {
      _homeController?.dispose();
    }
    _homeController = null;
    _homeControllerAuthenticated = false;
    _ownedApiClient?.close();
    final lanController = _lanRoomController;
    if (lanController != null) {
      lanController.removeListener(_lanChanged);
      if (_ownsLanRoomController) lanController.dispose();
    }
    widget.updateController?.dispose();
    if (!widget.hostSmokeEnabled) _historyController.dispose();
    super.dispose();
  }

  bool get _canLaunchInstrumentationCanary =>
      RegExp(r'^[A-Za-z0-9_-]{8,64}$')
          .hasMatch(widget.instrumentationCanaryNonce);

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
      navigatorKey: _navigatorKey,
      navigatorObservers: [_routeObserver],
      title: 'Gamebox',
      theme: GameboxTheme.light(),
      darkTheme: GameboxTheme.dark(),
      themeMode: ThemeMode.system,
      home: widget.hostSmokeEnabled ? _buildHostSmoke() : _buildProfileFlow(),
    );
  }

  Widget _buildProfileFlow() {
    final controller = _profileController!;
    return switch (controller.status) {
      ProfileStatus.loading => Scaffold(
        body: GameboxPageBody(
          children: [
            Semantics(
              label: 'profile-loading',
              child: GameboxAsyncPanel(
                icon: Icons.person_outline,
                title: '正在读取本机资料',
                message: '请稍候。',
                isLoading: true,
              ),
            ),
          ],
        ),
      ),
      ProfileStatus.loadFailure => Scaffold(
        appBar: AppBar(title: const Text('Gamebox')),
        body: GameboxPageBody(
          children: [
            const GameboxAsyncPanel(
              icon: Icons.person_off_outlined,
              title: '无法读取本机昵称',
              message: '请重试读取本机资料。',
            ),
            FilledButton(
              key: const Key('profile-load-retry'),
              onPressed: controller.load,
              child: const Text('重试'),
            ),
          ],
        ),
      ),
      ProfileStatus.needsNickname => NicknamePage(controller: controller),
      ProfileStatus.saving =>
        controller.profile == null
            ? NicknamePage(controller: controller)
            : _buildHomeShell(controller),
      ProfileStatus.ready => _buildHomeShell(controller),
    };
  }

  Widget _buildHomeShell(ProfileController profileController) {
    final profile = profileController.profile!;
    final sessionController = _sessionController!;
    final session = sessionController.session;
    final authenticated =
        sessionController.status == SessionStatus.authenticated &&
        session != null &&
        _homeController != null;
    final lanController = _lanRoomController!;
    if (!_lanInitialized) {
      _lanInitialized = true;
      unawaited(lanController.initialize());
    }
    return HomePage(
      controller: authenticated ? _homeController : null,
      currentUserId: authenticated ? session.user.id : null,
      nickname: profile.nickname,
      publicSection: authenticated
          ? null
          : _buildPublicSection(sessionController, profile.nickname),
      onEditNickname: _editNickname,
      onOpenPublic: authenticated ? null : _openPublicRegistration,
      onOpenLan: _openLan,
      onOpenHistory: _openHistory,
      lanRecovery:
          lanController.state is LanIdle ||
              lanController.state is LanRoomFailure
          ? null
          : LanRecoveryCard(controller: lanController),
      updateController: widget.updateController,
    );
  }

  void _openHistory() {
    final sessionController = _sessionController;
    MatchHistoryApi? publicApi;
    if (sessionController?.status == SessionStatus.authenticated &&
        sessionController?.session != null) {
      publicApi = widget.matchHistoryApi;
      if (publicApi == null) {
        final apiClient = _ownedApiClient ??= ApiClient(
          httpClient: http.Client(),
        );
        publicApi = HttpMatchHistoryApi(apiClient, sessionController!);
      }
    }
    _navigatorKey.currentState?.push<void>(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: 'history'),
        builder: (_) => GameHistoryPage(
          controller: _historyController,
          publicApi: publicApi,
        ),
      ),
    );
  }

  void _openLan() {
    final profile = _profileController?.profile;
    final controller = _lanRoomController;
    if (profile == null || controller == null) return;
    _navigatorKey.currentState?.push<void>(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: 'lan/mode'),
        builder: (_) =>
            LanModePage(controller: controller, nickname: profile.nickname),
      ),
    );
  }

  void _openPublicRegistration() {
    final session = _sessionController;
    final profile = _profileController?.profile;
    if (session == null || profile == null) return;
    _navigatorKey.currentState?.push<void>(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: 'public/register'),
        builder: (_) => RegistrationPage(
          controller: session,
          nickname: profile.nickname,
          onEditNickname: _editNickname,
          updateController: widget.updateController,
        ),
      ),
    );
  }

  Widget _buildPublicSection(
    SessionController sessionController,
    String nickname,
  ) {
    if (sessionController.status == SessionStatus.restoring) {
      return Column(
        key: const Key('public-session-restoring'),
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('公开匹配'),
          SizedBox(height: GameboxTokens.spacing.compact),
          const CircularProgressIndicator(),
          SizedBox(height: GameboxTokens.spacing.layout),
          const Text('正在恢复公开账号'),
        ],
      );
    }
    return RegistrationPage(
      controller: sessionController,
      nickname: nickname,
      onEditNickname: _editNickname,
      updateController: widget.updateController,
      embedded: true,
    );
  }

  void _editNickname() {
    final controller = _profileController;
    final nickname = controller?.profile?.nickname;
    if (controller == null || nickname == null) return;
    _navigatorKey.currentState?.push<void>(
      MaterialPageRoute<void>(
        builder: (routeContext) => NicknamePage(
          controller: controller,
          initialNickname: nickname,
          onSaved: () => Navigator.of(routeContext).pop(),
        ),
      ),
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

final class _AppRouteObserver extends NavigatorObserver {
  final List<Route<dynamic>> _routes = [];

  void discardPublicRoutes(NavigatorState? navigator) {
    if (navigator == null) return;
    final publicRoutes = _routes
        .where((route) => route.settings.name?.startsWith('public/') ?? false)
        .toList(growable: false)
        .reversed;
    for (final route in publicRoutes) {
      navigator.removeRoute(route);
    }
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.add(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (index == -1) {
      if (newRoute != null) _routes.add(newRoute);
      return;
    }
    if (newRoute == null) {
      _routes.removeAt(index);
    } else {
      _routes[index] = newRoute;
    }
  }
}
