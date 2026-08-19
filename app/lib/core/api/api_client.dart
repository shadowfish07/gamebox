import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'api_error.dart';

const apiBaseUrl = String.fromEnvironment(
  'GAMEBOX_API_BASE_URL',
  defaultValue: 'http://10.0.2.2:8080',
);

typedef AccessTokenProvider = String? Function();
typedef UnauthorizedHandler = Future<bool> Function();

/// The small JSON/HTTP boundary shared by Flutter features.
///
/// A safe GET may be retried once after a successful 401 refresh. Mutating
/// requests still invoke the refresh hook for future requests, but their body
/// is never replayed automatically.
final class ApiClient {
  static const _maximumResponseBytes = 512 * 1024;

  ApiClient({
    http.Client? httpClient,
    Uri? baseUri,
    this.timeout = const Duration(seconds: 10),
  }) : _httpClient = httpClient ?? http.Client(),
       _baseUri = baseUri ?? Uri.parse(apiBaseUrl) {
    if (!_isValidBaseUri(_baseUri)) {
      throw ArgumentError('API base URL must be an HTTP(S) origin');
    }
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'must be positive');
    }
  }

  final http.Client _httpClient;
  final Uri _baseUri;
  final Duration timeout;

  Future<Map<String, Object?>> getJson(
    String path, {
    AccessTokenProvider? accessToken,
    UnauthorizedHandler? onUnauthorized,
  }) {
    return _requestJson(
      method: 'GET',
      path: path,
      accessToken: accessToken,
      onUnauthorized: onUnauthorized,
      mayRetryAfterUnauthorized: true,
      expectedStatuses: const {200},
    );
  }

  Future<Map<String, Object?>> postJson(
    String path,
    Map<String, Object?> body, {
    AccessTokenProvider? accessToken,
    UnauthorizedHandler? onUnauthorized,
    Set<int> expectedStatuses = const {200, 201},
  }) {
    return _requestJson(
      method: 'POST',
      path: path,
      body: body,
      accessToken: accessToken,
      onUnauthorized: onUnauthorized,
      mayRetryAfterUnauthorized: false,
      expectedStatuses: expectedStatuses,
    );
  }

  void close() => _httpClient.close();

  Future<Map<String, Object?>> _requestJson({
    required String method,
    required String path,
    required bool mayRetryAfterUnauthorized,
    required Set<int> expectedStatuses,
    Map<String, Object?>? body,
    AccessTokenProvider? accessToken,
    UnauthorizedHandler? onUnauthorized,
  }) async {
    final uri = _resolvePath(path);
    final encodedBody = body == null ? null : jsonEncode(body);
    try {
      var response = await _send(
        method: method,
        uri: uri,
        encodedBody: encodedBody,
        accessToken: accessToken?.call(),
      );
      if (response.statusCode == 401 && onUnauthorized != null) {
        final refreshed = await onUnauthorized();
        if (refreshed && mayRetryAfterUnauthorized) {
          response = await _send(
            method: method,
            uri: uri,
            encodedBody: encodedBody,
            accessToken: accessToken?.call(),
          );
        }
      }
      return _decodeResponse(response, expectedStatuses);
    } on ApiError {
      rethrow;
    } on TimeoutException {
      throw const ApiError(code: 'timeout', message: '请求超时，请稍后重试');
    } on http.ClientException {
      throw const ApiError(code: 'network_error', message: '网络连接失败，请稍后重试');
    } on FormatException {
      throw const ApiError(code: 'invalid_response', message: '服务器响应无效');
    }
  }

  Future<http.Response> _send({
    required String method,
    required Uri uri,
    required String? encodedBody,
    required String? accessToken,
  }) {
    final request = http.Request(method, uri)
      ..headers['Accept'] = 'application/json';
    if (encodedBody != null) {
      request.headers['Content-Type'] = 'application/json; charset=utf-8';
      request.body = encodedBody;
    }
    if (accessToken != null && accessToken.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $accessToken';
    }
    return _sendAndCollect(request).timeout(timeout);
  }

  Future<http.Response> _sendAndCollect(http.Request request) async {
    final streamed = await _httpClient.send(request);
    final declaredLength = streamed.contentLength;
    if (declaredLength != null && declaredLength > _maximumResponseBytes) {
      throw const ApiError(code: 'invalid_response', message: '服务器响应无效');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in streamed.stream) {
      if (bytes.length + chunk.length > _maximumResponseBytes) {
        throw const ApiError(code: 'invalid_response', message: '服务器响应无效');
      }
      bytes.add(chunk);
    }
    return http.Response.bytes(
      bytes.takeBytes(),
      streamed.statusCode,
      request: streamed.request,
      headers: streamed.headers,
      isRedirect: streamed.isRedirect,
      persistentConnection: streamed.persistentConnection,
      reasonPhrase: streamed.reasonPhrase,
    );
  }

  Map<String, Object?> _decodeResponse(
    http.Response response,
    Set<int> expectedStatuses,
  ) {
    final contentType = response.headers['content-type']
        ?.split(';')
        .first
        .trim()
        .toLowerCase();
    if (contentType != 'application/json') {
      throw const ApiError(code: 'invalid_response', message: '服务器响应无效');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw const ApiError(code: 'invalid_response', message: '服务器响应无效');
    }
    if (!expectedStatuses.contains(response.statusCode)) {
      throw _decodeApiError(decoded);
    }
    if (decoded is! Map<String, Object?>) {
      throw const ApiError(code: 'invalid_response', message: '服务器响应无效');
    }
    return Map<String, Object?>.unmodifiable(decoded);
  }

  ApiError _decodeApiError(Object? decoded) {
    if (decoded is! Map<String, Object?>) {
      return const ApiError(code: 'invalid_response', message: '服务器响应无效');
    }
    final error = decoded['error'];
    if (error is! Map<String, Object?>) {
      return const ApiError(code: 'invalid_response', message: '服务器响应无效');
    }
    final code = error['code'];
    final message = error['message'];
    final details = error['details'];
    if (code is! String ||
        message is! String ||
        details is! Map<String, Object?> ||
        !_isBoundedCode(code) ||
        !_isBoundedMessage(message)) {
      return const ApiError(code: 'invalid_response', message: '服务器响应无效');
    }
    return ApiError(code: code, message: message);
  }

  Uri _resolvePath(String path) {
    if (!path.startsWith('/') || path.startsWith('//')) {
      throw ArgumentError('API path must be origin-relative');
    }
    final resolved = _baseUri.resolve(path);
    if (resolved.scheme != _baseUri.scheme ||
        resolved.host != _baseUri.host ||
        resolved.port != _baseUri.port) {
      throw ArgumentError('API path must stay on the configured origin');
    }
    return resolved;
  }

  static bool _isValidBaseUri(Uri uri) {
    return (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        (uri.path.isEmpty || uri.path == '/') &&
        !uri.hasQuery &&
        !uri.hasFragment;
  }

  static bool _isBoundedCode(String value) {
    return value.isNotEmpty &&
        value.length <= 64 &&
        RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(value);
  }

  static bool _isBoundedMessage(String value) {
    return value.isNotEmpty &&
        value.runes.length <= 256 &&
        !value.runes.any((rune) => rune < 0x20 || rune == 0x7f);
  }
}
