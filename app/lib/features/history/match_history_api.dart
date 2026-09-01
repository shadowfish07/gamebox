import '../../core/api/api_client.dart';
import '../../core/api/api_error.dart';
import '../auth/session_controller.dart';
import 'match_history_models.dart';

abstract interface class MatchHistoryApi {
  Future<MatchHistoryPageData> fetchPage({
    MatchHistoryGame game = MatchHistoryGame.gomoku,
    String? cursor,
    int limit = 20,
  });
}

final class HttpMatchHistoryApi implements MatchHistoryApi {
  HttpMatchHistoryApi(this._client, this._session);

  final ApiClient _client;
  final SessionController _session;

  @override
  Future<MatchHistoryPageData> fetchPage({
    MatchHistoryGame game = MatchHistoryGame.gomoku,
    String? cursor,
    int limit = 20,
  }) async {
    final query = Uri(
      path: '/v1/games/${game.id}/history',
      queryParameters: {'limit': '$limit', 'cursor': ?cursor},
    ).toString();
    final envelope = await _client.getJson(
      query,
      accessToken: () => _session.accessToken,
      onUnauthorized: _session.refresh,
    );
    return _decode(
      () => MatchHistoryPageData.fromEnvelope(envelope, game: game),
    );
  }

  static T _decode<T>(T Function() decode) {
    try {
      return decode();
    } on FormatException {
      throw _invalidResponse;
    } on ArgumentError {
      throw _invalidResponse;
    }
  }

  static const _invalidResponse = ApiError(
    code: 'invalid_response',
    message: '服务器响应无效',
  );
}
