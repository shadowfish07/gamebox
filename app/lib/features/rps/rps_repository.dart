import '../../core/api/api_client.dart';
import '../../core/platform/game_launch_request.dart';
import '../../core/platform/game_launcher.dart';
import '../gomoku/gomoku_models.dart';
import 'rps_api.dart';
import 'rps_models.dart';

final class RpsRepository {
  RpsRepository({
    required this.api,
    required this.gameLauncher,
    Uri? apiBaseUri,
    DateTime Function()? now,
  }) : _apiBaseUri = apiBaseUri ?? Uri.parse(apiBaseUrl),
       _now = now ?? DateTime.now;

  final RpsApi api;
  final GameLauncher gameLauncher;
  final Uri _apiBaseUri;
  final DateTime Function() _now;

  Future<RpsStatus> fetchStatus() => api.fetchStatus();
  Future<List<GomokuOpponent>> fetchOpponents() => api.fetchOpponents();
  Future<void> cancelMatch(String matchId) => api.cancelMatch(matchId);

  Future<void> createAndOpen(String opponentId, RpsFormat format) async {
    final created = await api.createMatch(opponentId, format);
    if (created.format != format) throw const RpsLaunchConfigurationException();
    await openMatch(created.id);
  }

  Future<void> openMatch(String matchId) async {
    final ticket = await api.createLaunchTicket(matchId);
    if (!ticket.expiresAt.isAfter(_now().toUtc())) {
      throw const RpsLaunchConfigurationException();
    }
    await gameLauncher.launch(
      GameLaunchRequest(
        gameId: rpsGameId,
        matchId: matchId,
        launchTicket: ticket.launchTicket,
        wsUrl: _apiBaseUri
            .replace(
              scheme: _apiBaseUri.scheme == 'https' ? 'wss' : 'ws',
              path: '/v1/ws',
            )
            .toString(),
      ),
    );
  }
}

final class RpsLaunchConfigurationException implements Exception {
  const RpsLaunchConfigurationException();
}
