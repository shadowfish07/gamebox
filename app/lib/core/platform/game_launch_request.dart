/// An immutable, validated request for launching a game in the native host.
class GameLaunchRequest {
  GameLaunchRequest({
    required this.gameId,
    required this.matchId,
    required this.launchTicket,
    required this.wsUrl,
  }) {
    if (gameId.trim().isEmpty) {
      throw ArgumentError('gameId must not be blank');
    }
    if (!_canonicalUuid.hasMatch(matchId)) {
      throw ArgumentError('matchId must be a canonical UUID');
    }
    if (launchTicket.trim().isEmpty) {
      throw ArgumentError('launchTicket must not be blank');
    }
    final uri = Uri.tryParse(wsUrl);
    if (uri == null ||
        (uri.scheme != 'ws' && uri.scheme != 'wss') ||
        uri.host.isEmpty) {
      throw ArgumentError('wsUrl must use ws or wss with a host');
    }
  }

  static final RegExp _canonicalUuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );

  final String gameId;
  final String matchId;
  final String launchTicket;
  final String wsUrl;

  Map<String, String> toArguments() => {
    'gameId': gameId,
    'matchId': matchId,
    'launchTicket': launchTicket,
    'wsUrl': wsUrl,
  };
}
