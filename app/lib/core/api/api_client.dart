import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'api_error.dart';
import 'network_failure.dart';
import 'strict_json.dart';

const apiBaseUrl = String.fromEnvironment(
  'GAMEBOX_API_BASE_URL',
  defaultValue: 'http://10.0.2.2:8080',
);

typedef AccessTokenProvider = String? Function();
typedef UnauthorizedHandler = Future<bool> Function(String failedAccessToken);

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
      final failedAccessToken = accessToken?.call();
      var response = await _send(
        method: method,
        uri: uri,
        encodedBody: encodedBody,
        accessToken: failedAccessToken,
      );
      if (response.statusCode == 401 &&
          onUnauthorized != null &&
          failedAccessToken != null &&
          failedAccessToken.isNotEmpty) {
        final refreshed = await onUnauthorized(failedAccessToken);
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
    } on http.RequestAbortedException {
      throw const ApiError(code: 'network_error', message: '网络连接失败，请稍后重试');
    } on http.ClientException {
      throw const ApiError(code: 'network_error', message: '网络连接失败，请稍后重试');
    } on FormatException {
      throw const ApiError(code: 'invalid_response', message: '服务器响应无效');
    } catch (error) {
      if (isNetworkFailure(error)) {
        throw const ApiError(code: 'network_error', message: '网络连接失败，请稍后重试');
      }
      rethrow;
    }
  }

  Future<http.Response> _send({
    required String method,
    required Uri uri,
    required String? encodedBody,
    required String? accessToken,
  }) {
    final abort = Completer<void>();
    final request =
        http.AbortableRequest(method, uri, abortTrigger: abort.future)
          ..followRedirects = false
          ..maxRedirects = 0
          ..headers['Accept'] = 'application/json';
    if (encodedBody != null) {
      request.headers['Content-Type'] = 'application/json; charset=utf-8';
      request.body = encodedBody;
    }
    if (accessToken != null && accessToken.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $accessToken';
    }
    return _sendAndCollect(request, abort);
  }

  Future<http.Response> _sendAndCollect(
    http.AbortableRequest request,
    Completer<void> abort,
  ) {
    final result = Completer<http.Response>();
    final bytes = BytesBuilder(copy: false);
    StreamSubscription<List<int>>? subscription;
    late final Timer timer;

    void cancelSubscription() {
      final current = subscription;
      if (current != null) {
        unawaited(current.cancel().catchError((_) {}));
      }
    }

    void completeError(
      Object error,
      StackTrace stackTrace, {
      bool abortRequest = false,
    }) {
      if (result.isCompleted) {
        return;
      }
      timer.cancel();
      result.completeError(error, stackTrace);
      if (abortRequest && !abort.isCompleted) {
        abort.complete();
      }
      cancelSubscription();
    }

    timer = Timer(timeout, () {
      completeError(
        TimeoutException('HTTP request timed out'),
        StackTrace.current,
        abortRequest: true,
      );
    });

    _httpClient
        .send(request)
        .then(
          (streamed) {
            if (result.isCompleted) {
              final abandoned = streamed.stream.listen(null);
              unawaited(abandoned.cancel().catchError((_) {}));
              return;
            }
            final declaredLength = streamed.contentLength;
            if (declaredLength != null &&
                declaredLength > _maximumResponseBytes) {
              subscription = streamed.stream.listen(null, onError: (_) {});
              completeError(
                const ApiError(code: 'invalid_response', message: '服务器响应无效'),
                StackTrace.current,
                abortRequest: true,
              );
              return;
            }
            subscription = streamed.stream.listen(
              (chunk) {
                if (result.isCompleted) {
                  return;
                }
                if (bytes.length + chunk.length > _maximumResponseBytes) {
                  completeError(
                    const ApiError(
                      code: 'invalid_response',
                      message: '服务器响应无效',
                    ),
                    StackTrace.current,
                    abortRequest: true,
                  );
                  return;
                }
                bytes.add(chunk);
              },
              onError: (Object error, StackTrace stackTrace) {
                completeError(
                  _normalizeTransportError(error, request.url),
                  stackTrace,
                  abortRequest: true,
                );
              },
              onDone: () {
                if (result.isCompleted) {
                  return;
                }
                timer.cancel();
                result.complete(
                  http.Response.bytes(
                    bytes.takeBytes(),
                    streamed.statusCode,
                    request: streamed.request,
                    headers: streamed.headers,
                    isRedirect: streamed.isRedirect,
                    persistentConnection: streamed.persistentConnection,
                    reasonPhrase: streamed.reasonPhrase,
                  ),
                );
              },
              cancelOnError: true,
            );
            if (result.isCompleted) {
              cancelSubscription();
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            completeError(
              _normalizeTransportError(error, request.url),
              stackTrace,
            );
          },
        );
    return result.future;
  }

  Map<String, Object?> _decodeResponse(
    http.Response response,
    Set<int> expectedStatuses,
  ) {
    if (response.statusCode >= 300 && response.statusCode < 400) {
      throw const ApiError(code: 'invalid_response', message: '服务器响应无效');
    }
    if (!_isJsonContentType(response.headers['content-type'])) {
      throw const ApiError(code: 'invalid_response', message: '服务器响应无效');
    }
    late final Map<String, Object?> decoded;
    try {
      decoded = decodeStrictJsonObject(response.bodyBytes);
    } on FormatException {
      throw const ApiError(code: 'invalid_response', message: '服务器响应无效');
    }
    if (!expectedStatuses.contains(response.statusCode)) {
      throw _decodeApiError(decoded);
    }
    return decoded;
  }

  ApiError _decodeApiError(Map<String, Object?> decoded) {
    if (!hasExactJsonKeys(decoded, const {'error'})) {
      return const ApiError(code: 'invalid_response', message: '服务器响应无效');
    }
    final error = decoded['error'];
    if (error is! Map<String, Object?> ||
        !hasExactJsonKeys(error, const {'code', 'message', 'details'})) {
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

  static bool _isJsonContentType(String? value) {
    if (value == null) {
      return false;
    }
    final parts = value.split(';');
    if (parts.first.trim().toLowerCase() != 'application/json') {
      return false;
    }
    if (parts.length == 1) {
      return true;
    }
    if (parts.length != 2) {
      return false;
    }
    return RegExp(
      r'^charset\s*=\s*(?:utf-8|"utf-8")$',
      caseSensitive: false,
    ).hasMatch(parts[1].trim());
  }

  static Object _normalizeTransportError(Object error, Uri uri) {
    if (error is FormatException ||
        error is TimeoutException ||
        error is http.ClientException ||
        isNetworkFailure(error)) {
      return error;
    }
    return http.ClientException('HTTP transport failed', uri);
  }
}
