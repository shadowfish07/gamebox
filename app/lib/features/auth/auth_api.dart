import '../../core/api/api_client.dart';
import '../../core/api/api_error.dart';
import '../../core/auth/session.dart';

abstract interface class AuthApi {
  Future<Session> register(String inviteCode, String nickname);

  Future<Session> refresh(String refreshToken);

  Future<SessionUser> updateNickname(
    String nickname, {
    required AccessTokenProvider accessToken,
    required UnauthorizedHandler onUnauthorized,
  });
}

final class HttpAuthApi implements AuthApi {
  HttpAuthApi(this._client);

  final ApiClient _client;

  @override
  Future<Session> register(String inviteCode, String nickname) async {
    final envelope = await _client.postJson(
      '/v1/auth/register',
      {'inviteCode': inviteCode, 'nickname': nickname},
      expectedStatuses: const {201},
    );
    return _sessionFromEnvelope(envelope);
  }

  @override
  Future<Session> refresh(String refreshToken) async {
    final envelope = await _client.postJson(
      '/v1/auth/refresh',
      {'refreshToken': refreshToken},
      expectedStatuses: const {200},
    );
    return _sessionFromEnvelope(envelope);
  }

  @override
  Future<SessionUser> updateNickname(
    String nickname, {
    required AccessTokenProvider accessToken,
    required UnauthorizedHandler onUnauthorized,
  }) async {
    final envelope = await _client.patchJson(
      '/v1/me',
      {'nickname': nickname},
      accessToken: accessToken,
      onUnauthorized: onUnauthorized,
      expectedStatuses: const {200},
    );
    try {
      return SessionUser.fromEnvelope(envelope);
    } on FormatException {
      throw const ApiError(code: 'invalid_response', message: '服务器响应无效');
    }
  }

  Session _sessionFromEnvelope(Map<String, Object?> envelope) {
    try {
      return Session.fromEnvelope(envelope);
    } on FormatException {
      throw const ApiError(code: 'invalid_response', message: '服务器响应无效');
    }
  }
}
