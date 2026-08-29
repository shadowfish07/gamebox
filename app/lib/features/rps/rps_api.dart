import '../../core/api/api_client.dart';
import '../../core/api/api_error.dart';
import '../auth/session_controller.dart';
import '../gomoku/gomoku_models.dart';
import 'rps_models.dart';

abstract interface class RpsApi {
  Future<RpsStatus> fetchStatus();
  Future<List<GomokuOpponent>> fetchOpponents();
  Future<CreatedRpsMatch> createMatch(String opponentId, RpsFormat format);
  Future<void> cancelMatch(String matchId);
  Future<RpsLaunchTicket> createLaunchTicket(String matchId);
}

final class HttpRpsApi implements RpsApi {
  HttpRpsApi(this._client, this._session);

  final ApiClient _client;
  final SessionController _session;

  @override
  Future<RpsStatus> fetchStatus() async => _decode(
    () async => RpsStatus.fromEnvelope(
      await _client.getJson(
        '/v1/games/rps/status',
        accessToken: _accessToken,
        onUnauthorized: _session.refresh,
      ),
    ),
  );

  @override
  Future<List<GomokuOpponent>> fetchOpponents() async => _decode(
    () async => GomokuOpponent.listFromEnvelope(
      await _client.getJson(
        '/v1/games/rps/opponents',
        accessToken: _accessToken,
        onUnauthorized: _session.refresh,
      ),
    ),
  );

  @override
  Future<CreatedRpsMatch> createMatch(
    String opponentId,
    RpsFormat format,
  ) async {
    _requireUuid(opponentId);
    return _decode(
      () async => CreatedRpsMatch.fromEnvelope(
        await _client.postJson(
          '/v1/games/rps/matches',
          {'opponentId': opponentId, 'format': format.wireValue},
          accessToken: _accessToken,
          onUnauthorized: _session.refresh,
          expectedStatuses: const {201},
        ),
      ),
    );
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
  Future<RpsLaunchTicket> createLaunchTicket(String matchId) async {
    _requireUuid(matchId);
    final ticket = await _decode(
      () async => RpsLaunchTicket.fromEnvelope(
        await _client.postJson(
          '/v1/matches/$matchId/launch-ticket',
          const {},
          accessToken: _accessToken,
          onUnauthorized: _session.refresh,
          expectedStatuses: const {201},
        ),
      ),
    );
    if (ticket.matchId != matchId) throw _invalidResponse;
    return ticket;
  }

  String? _accessToken() => _session.accessToken;

  static Future<T> _decode<T>(Future<T> Function() decode) async {
    try {
      return await decode();
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
