import '../lan/lan_models.dart';

enum LanNativeState { empty, waiting, active, finished, cancelled, corrupt }

final class LanHostStatus {
  const LanHostStatus({
    required this.state,
    required this.roomId,
    required this.port,
    required this.gameRevision,
    required this.endpointChanged,
    required this.endpoint,
  });

  final LanNativeState state;
  final String? roomId;
  final int port;
  final int gameRevision;
  final bool endpointChanged;
  final LanEndpoint? endpoint;
}

final class LanHostCreation {
  const LanHostCreation({
    required this.status,
    required this.roomKey,
    required this.joinExpiresAt,
  });

  final LanHostStatus status;
  final String roomKey;
  final DateTime joinExpiresAt;

  @override
  String toString() =>
      'LanHostCreation(status: ${status.state}, roomKey: <redacted>)';
}

final class LanHostLaunch {
  const LanHostLaunch({
    required this.matchId,
    required this.gameId,
    required this.playerId,
    required this.launchTicket,
    required this.resumeToken,
    required this.wsUrl,
    required this.expiresAt,
  });

  final String matchId;
  final String gameId;
  final String playerId;
  final String launchTicket;
  final String resumeToken;
  final String wsUrl;
  final DateTime expiresAt;

  @override
  String toString() =>
      'LanHostLaunch(matchId: $matchId, credentials: <redacted>)';
}

abstract interface class LanHostPlatform {
  Future<LanHostStatus> getStatus();
  Future<LanHostCreation> createRoom(String nickname);
  Future<LanHostLaunch> issueHostLaunch();
  Future<LanHostStatus> refreshEndpoint();
  Future<LanHostStatus> closeRoom(String mode);
  Future<LanHostStatus> stopCompletedRoom({required bool allowMissingGuestAck});
}

final class LanHostException implements Exception {
  const LanHostException(this.code);
  final String code;
  @override
  String toString() => 'LanHostException($code)';
}
