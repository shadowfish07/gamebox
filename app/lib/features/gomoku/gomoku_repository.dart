import '../../core/api/api_client.dart';
import '../../core/platform/game_launch_request.dart';
import '../../core/platform/game_launcher.dart';
import '../home/home_api.dart';
import 'gomoku_models.dart';

final class GomokuRepository {
  GomokuRepository({
    required this._api,
    required this._gameLauncher,
    Uri? apiBaseUri,
    DateTime Function()? now,
  }) : _apiBaseUri = apiBaseUri ?? Uri.parse(apiBaseUrl),
       _now = now ?? DateTime.now {
    if (!_isHttpOrigin(_apiBaseUri)) {
      throw ArgumentError('API base URL must be an HTTP(S) origin');
    }
  }

  final HomeApi _api;
  final GameLauncher _gameLauncher;
  final Uri _apiBaseUri;
  final DateTime Function() _now;

  Future<GomokuStatus> fetchStatus() => _api.fetchStatus();

  Future<List<GomokuOpponent>> fetchOpponents() => _api.fetchOpponents();

  Future<void> cancelMatch(String matchId) => _api.cancelMatch(matchId);

  Future<String> createAndOpen(String opponentId) async {
    final created = await _api.createMatch(opponentId);
    await openMatch(created.id);
    return created.id;
  }

  Future<void> openMatch(String matchId) async {
    final ticket = await _api.createLaunchTicket(matchId);
    if (ticket.matchId != matchId ||
        ticket.gameId != gomokuGameId ||
        !ticket.expiresAt.isAfter(_now().toUtc())) {
      throw const GomokuLaunchConfigurationException();
    }
    await _gameLauncher.launch(
      GameLaunchRequest(
        gameId: gomokuGameId,
        matchId: matchId,
        launchTicket: ticket.launchTicket,
        wsUrl: _webSocketUri(_apiBaseUri).toString(),
      ),
    );
  }

  static Uri _webSocketUri(Uri apiBaseUri) => apiBaseUri.replace(
    scheme: apiBaseUri.scheme == 'https' ? 'wss' : 'ws',
    path: '/v1/ws',
  );

  static bool _isHttpOrigin(Uri uri) =>
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      (uri.path.isEmpty || uri.path == '/') &&
      !uri.hasQuery &&
      !uri.hasFragment;
}

final class GomokuLaunchConfigurationException implements Exception {
  const GomokuLaunchConfigurationException();

  @override
  String toString() => 'GomokuLaunchConfigurationException';
}
