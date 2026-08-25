import '../lan/lan_models.dart';

final class CommittedGameResult {
  const CommittedGameResult({required this.result, required this.sha256});

  final AuthoritativeGameResult result;
  final String sha256;
}

final class PendingGameResultRecord {
  const PendingGameResultRecord({
    required this.matchId,
    required this.gameId,
    required this.source,
    required this.endpointKind,
    this.localUserId,
  });

  final String matchId;
  final String gameId;
  final String source;
  final String endpointKind;
  final String? localUserId;
}

abstract interface class GameResultsPlatform {
  Future<List<CommittedGameResult>> listCommitted();
  Future<List<PendingGameResultRecord>> listPending();
  Future<String> persistRecovered(AuthoritativeGameResult result);
  Future<void> completePending(String matchId, String expectedSha256);
  Future<bool> quarantine(String matchId);
}
