import '../../core/api/api_client.dart';
import '../../core/api/api_error.dart';
import '../../core/api/strict_json.dart';
import '../auth/session_controller.dart';
import '../gomoku/gomoku_models.dart';
import '../../core/lan/lan_models.dart';

abstract interface class HomeApi {
  Future<GomokuStatus> fetchStatus();

  Future<List<GomokuOpponent>> fetchOpponents();

  Future<CreatedGomokuMatch> createMatch(String opponentId);

  Future<void> cancelMatch(String matchId);

  Future<GomokuLaunchTicket> createLaunchTicket(String matchId);

  Future<AuthoritativeGameResult> fetchResult(String matchId);
}

final class HttpHomeApi implements HomeApi {
  HttpHomeApi(this._client, this._session);

  final ApiClient _client;
  final SessionController _session;

  @override
  Future<GomokuStatus> fetchStatus() async {
    final envelope = await _client.getJson(
      '/v1/games/gomoku/status',
      accessToken: _accessToken,
      onUnauthorized: _session.refresh,
    );
    return _decode(() => GomokuStatus.fromEnvelope(envelope));
  }

  @override
  Future<List<GomokuOpponent>> fetchOpponents() async {
    final envelope = await _client.getJson(
      '/v1/games/gomoku/opponents',
      accessToken: _accessToken,
      onUnauthorized: _session.refresh,
    );
    return _decode(() => GomokuOpponent.listFromEnvelope(envelope));
  }

  @override
  Future<CreatedGomokuMatch> createMatch(String opponentId) async {
    _requireUuid(opponentId);
    final envelope = await _client.postJson(
      '/v1/games/gomoku/matches',
      {'opponentId': opponentId},
      accessToken: _accessToken,
      onUnauthorized: _session.refresh,
      expectedStatuses: const {201},
    );
    return _decode(() => CreatedGomokuMatch.fromEnvelope(envelope));
  }

  @override
  Future<void> cancelMatch(String matchId) {
    _requireUuid(matchId);
    return _client.deleteEmpty(
      '/v1/matches/$matchId',
      accessToken: _accessToken,
      onUnauthorized: _session.refresh,
    );
  }

  @override
  Future<GomokuLaunchTicket> createLaunchTicket(String matchId) async {
    _requireUuid(matchId);
    final envelope = await _client.postJson(
      '/v1/matches/$matchId/launch-ticket',
      const {},
      accessToken: _accessToken,
      onUnauthorized: _session.refresh,
      expectedStatuses: const {201},
    );
    final ticket = _decode(() => GomokuLaunchTicket.fromEnvelope(envelope));
    if (ticket.matchId != matchId) {
      throw _invalidResponse;
    }
    return ticket;
  }

  @override
  Future<AuthoritativeGameResult> fetchResult(String matchId) async {
    _requireUuid(matchId);
    final envelope = await _client.getJson(
      '/v1/matches/$matchId/result',
      accessToken: _accessToken,
      onUnauthorized: _session.refresh,
    );
    if (!hasExactJsonKeys(envelope, const {'result'}) ||
        envelope['result'] is! Map<String, Object?>) {
      throw _invalidResponse;
    }
    return _decode(
      () => AuthoritativeGameResult.fromObject(
        envelope['result']! as Map<String, Object?>,
      ),
    );
  }

  String? _accessToken() => _session.accessToken;

  static T _decode<T>(T Function() decode) {
    try {
      return decode();
    } on FormatException {
      throw _invalidResponse;
    } on ArgumentError {
      throw _invalidResponse;
    }
  }

  static void _requireUuid(String value) {
    if (!isCanonicalGameboxUuid(value)) {
      throw const ApiError(code: 'invalid_request', message: '请求无效');
    }
  }

  static const _invalidResponse = ApiError(
    code: 'invalid_response',
    message: '服务器响应无效',
  );
}
