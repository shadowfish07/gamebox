import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/api/api_error.dart';
import '../../core/auth/session.dart';
import '../../core/auth/token_store.dart';
import 'auth_api.dart';

enum SessionStatus { restoring, unauthenticated, submitting, authenticated }

/// Owns the in-memory access credential and the rotating refresh lifecycle.
final class SessionController extends ChangeNotifier {
  SessionController({
    required AuthApi authApi,
    required TokenStore tokenStore,
    DateTime Function()? now,
  }) : _authApi = authApi,
       _tokenStore = tokenStore,
       _now = now ?? DateTime.now;

  // The current server deliberately collapses every invalid, revoked, or
  // expired HTTP credential into this single authoritative code.
  static const _authoritativeInvalidCodes = {'unauthorized'};

  final AuthApi _authApi;
  final TokenStore _tokenStore;
  final DateTime Function() _now;

  SessionStatus _status = SessionStatus.restoring;
  Session? _session;
  ApiError? _lastError;
  Future<bool>? _restoreInFlight;
  Future<bool>? _refreshInFlight;
  Future<bool>? _credentialCleanupInFlight;
  Future<ApiError?>? _registrationInFlight;
  var _hasStoredRefreshToken = false;
  var _credentialCleanupRequired = false;
  var _credentialCleanupPending = false;
  var _generation = 0;
  var _disposed = false;

  SessionStatus get status => _status;
  Session? get session => _session;
  String? get accessToken => _session?.accessToken;
  ApiError? get lastError => _lastError;
  bool get credentialCleanupPending => _credentialCleanupPending;
  bool get canRegister =>
      !_disposed &&
      _status == SessionStatus.unauthenticated &&
      !_credentialCleanupRequired &&
      !_credentialCleanupPending &&
      !_hasStoredRefreshToken;
  bool get canRetryRestore =>
      !_disposed &&
      _status == SessionStatus.unauthenticated &&
      !_credentialCleanupRequired &&
      !_credentialCleanupPending &&
      _hasStoredRefreshToken;
  bool get canRetryCredentialCleanup =>
      !_disposed &&
      _status == SessionStatus.unauthenticated &&
      _credentialCleanupRequired &&
      !_credentialCleanupPending;

  Future<void> restore() async {
    if (_disposed || _status != SessionStatus.restoring) {
      return;
    }
    await _beginRestore();
  }

  Future<bool> retryRestore() {
    if (!canRetryRestore) {
      return Future<bool>.value(false);
    }
    _transition(SessionStatus.restoring);
    return _beginRestore();
  }

  Future<bool> retryCredentialCleanup() {
    final existing = _credentialCleanupInFlight;
    if (existing != null) {
      return existing;
    }
    if (!canRetryCredentialCleanup) {
      return Future<bool>.value(false);
    }
    return _clearStoredCredential(_generation);
  }

  Future<bool> _beginRestore() {
    final existing = _restoreInFlight;
    if (existing != null) {
      return existing;
    }
    final generation = ++_generation;
    late final Future<bool> operation;
    operation = _performRestore(generation).whenComplete(() {
      if (identical(_restoreInFlight, operation)) {
        _restoreInFlight = null;
      }
    });
    _restoreInFlight = operation;
    return operation;
  }

  Future<bool> _performRestore(int generation) async {
    String? refreshToken;
    try {
      refreshToken = await _tokenStore.readRefreshToken();
    } on TokenStoreException catch (error) {
      if (!_isCurrent(generation)) {
        return false;
      }
      if (error.kind == TokenStoreFailureKind.corrupt) {
        await _clearStoredCredential(generation);
      } else {
        _preserveForRetry(
          generation,
          const ApiError(
            code: 'storage_unavailable',
            message: '无法读取登录信息，请稍后重试',
          ),
        );
      }
      return false;
    } catch (_) {
      if (_isCurrent(generation)) {
        _preserveForRetry(
          generation,
          const ApiError(
            code: 'storage_unavailable',
            message: '无法读取登录信息，请稍后重试',
          ),
        );
      }
      return false;
    }
    if (!_isCurrent(generation)) {
      return false;
    }
    if (refreshToken == null) {
      _hasStoredRefreshToken = false;
      _lastError = null;
      _transition(SessionStatus.unauthenticated);
      return false;
    }
    _hasStoredRefreshToken = true;
    if (!_isCredential(refreshToken)) {
      await _clearStoredCredential(generation);
      return false;
    }
    try {
      final rotated = await _authApi.refresh(refreshToken);
      if (!_isCurrent(generation)) {
        return false;
      }
      if (!rotated.refreshExpiresAt.isAfter(_now())) {
        _preserveForRetry(
          generation,
          const ApiError(code: 'invalid_response', message: '服务器响应无效'),
        );
        return false;
      }
      return _persistAndPublish(rotated, generation);
    } on ApiError catch (error) {
      if (!_isCurrent(generation)) {
        return false;
      }
      if (_authoritativeInvalidCodes.contains(error.code)) {
        await _clearStoredCredential(generation);
      } else {
        _preserveForRetry(generation, _safeFailure(error.code));
      }
      return false;
    } catch (_) {
      if (_isCurrent(generation)) {
        _preserveForRetry(
          generation,
          const ApiError(code: 'internal_error', message: '登录失败，请稍后重试'),
        );
      }
      return false;
    }
  }

  Future<ApiError?> register(String inviteCode, String nickname) {
    final existing = _registrationInFlight;
    if (existing != null) {
      return existing;
    }
    if (!canRegister) {
      return Future<ApiError?>.value(
        const ApiError(code: 'invalid_state', message: '当前无法注册'),
      );
    }
    final generation = ++_generation;
    _transition(SessionStatus.submitting);
    late final Future<ApiError?> operation;
    operation = _performRegistration(inviteCode, nickname, generation)
        .whenComplete(() {
          if (identical(_registrationInFlight, operation)) {
            _registrationInFlight = null;
          }
        });
    _registrationInFlight = operation;
    return operation;
  }

  Future<ApiError?> _performRegistration(
    String inviteCode,
    String nickname,
    int generation,
  ) async {
    try {
      final created = await _authApi.register(inviteCode, nickname);
      if (!_isCurrent(generation)) {
        return null;
      }
      if (!created.refreshExpiresAt.isAfter(_now())) {
        _session = null;
        _transition(SessionStatus.unauthenticated);
        return const ApiError(code: 'invalid_response', message: '服务器响应无效');
      }
      final persisted = await _persistAndPublish(created, generation);
      if (!persisted && _isCurrent(generation)) {
        return const ApiError(code: 'storage_error', message: '无法安全保存登录信息');
      }
      return null;
    } on ApiError catch (error) {
      if (_isCurrent(generation)) {
        _session = null;
        _lastError = _safeFailure(error.code);
        _transition(SessionStatus.unauthenticated);
      }
      return error;
    } catch (_) {
      if (_isCurrent(generation)) {
        _session = null;
        _lastError = const ApiError(
          code: 'internal_error',
          message: '注册失败，请稍后重试',
        );
        _transition(SessionStatus.unauthenticated);
      }
      return const ApiError(code: 'internal_error', message: '注册失败，请稍后重试');
    }
  }

  /// Refreshes credentials once. Concurrent callers receive this exact Future.
  Future<bool> refresh([String? failedAccessToken]) {
    final current = _session;
    if (_disposed ||
        _status != SessionStatus.authenticated ||
        current == null) {
      return Future<bool>.value(false);
    }
    if (failedAccessToken != null && failedAccessToken != current.accessToken) {
      return Future<bool>.value(true);
    }
    final existing = _refreshInFlight;
    if (existing != null) {
      return existing;
    }
    final generation = _generation;
    late final Future<bool> operation;
    operation = _performRefresh(current, generation).whenComplete(() {
      if (identical(_refreshInFlight, operation)) {
        _refreshInFlight = null;
      }
    });
    _refreshInFlight = operation;
    return operation;
  }

  Future<bool> _performRefresh(Session previous, int generation) async {
    if (!previous.refreshExpiresAt.isAfter(_now())) {
      await _clearStoredCredential(generation);
      return false;
    }
    try {
      final rotated = await _authApi.refresh(previous.refreshToken);
      if (!_isCurrent(generation) || _status != SessionStatus.authenticated) {
        return false;
      }
      if (rotated.user.id != previous.user.id ||
          !rotated.refreshExpiresAt.isAfter(_now())) {
        await _clearStoredCredential(generation);
        return false;
      }
      return _persistAndPublish(rotated, generation);
    } on ApiError catch (error) {
      if (!_isCurrent(generation)) {
        return false;
      }
      if (_authoritativeInvalidCodes.contains(error.code)) {
        await _clearStoredCredential(generation);
      } else {
        _preserveForRetry(generation, _safeFailure(error.code));
      }
      return false;
    } catch (_) {
      if (_isCurrent(generation)) {
        _preserveForRetry(
          generation,
          const ApiError(code: 'internal_error', message: '登录失败，请稍后重试'),
        );
      }
      return false;
    }
  }

  Future<bool> handleAppResumed() {
    if (_disposed) {
      return Future<bool>.value(false);
    }
    final cleanup = _credentialCleanupInFlight;
    if (cleanup != null) {
      return cleanup;
    }
    if (canRetryCredentialCleanup) {
      return retryCredentialCleanup();
    }
    if (canRetryRestore) {
      return retryRestore();
    }
    final current = _session;
    if (_status != SessionStatus.authenticated || current == null) {
      return _restoreInFlight ?? Future<bool>.value(false);
    }
    if (current.accessExpiresAt.isAfter(_now())) {
      return Future<bool>.value(true);
    }
    return refresh();
  }

  Future<bool> _persistAndPublish(Session next, int generation) async {
    if (!_isCurrent(generation)) {
      return false;
    }
    try {
      await _tokenStore.writeRefreshToken(next.refreshToken);
    } catch (_) {
      if (_isCurrent(generation)) {
        await _clearStoredCredential(generation);
      }
      return false;
    }
    if (!_isCurrent(generation)) {
      return false;
    }
    _session = next;
    _hasStoredRefreshToken = true;
    _credentialCleanupRequired = false;
    _credentialCleanupPending = false;
    _lastError = null;
    _status = SessionStatus.authenticated;
    _notify();
    return true;
  }

  Future<bool> _clearStoredCredential(int generation) {
    final existing = _credentialCleanupInFlight;
    if (existing != null) {
      return existing;
    }
    if (!_isCurrent(generation)) {
      return Future<bool>.value(false);
    }

    // Publish the complete fail-closed state before secure storage is touched.
    // No listener can observe authenticated state with a missing session.
    _session = null;
    _hasStoredRefreshToken = true;
    _credentialCleanupRequired = true;
    _credentialCleanupPending = true;
    _lastError = null;
    _status = SessionStatus.unauthenticated;
    _notify();

    late final Future<bool> operation;
    operation = _performCredentialCleanup(generation).whenComplete(() {
      if (identical(_credentialCleanupInFlight, operation)) {
        _credentialCleanupInFlight = null;
      }
    });
    _credentialCleanupInFlight = operation;
    return operation;
  }

  Future<bool> _performCredentialCleanup(int generation) async {
    var deleted = false;
    try {
      await _tokenStore.deleteRefreshToken();
      deleted = true;
    } catch (_) {
      // Memory still fails closed. A later explicit retry can inspect storage.
    }
    if (!_isCurrent(generation)) {
      return false;
    }
    _status = SessionStatus.unauthenticated;
    _credentialCleanupPending = false;
    _credentialCleanupRequired = !deleted;
    _hasStoredRefreshToken = !deleted;
    _lastError = deleted
        ? null
        : const ApiError(
            code: 'storage_unavailable',
            message: '无法更新登录信息，请稍后重试',
          );
    _notify();
    return deleted;
  }

  void _preserveForRetry(int generation, ApiError error) {
    if (!_isCurrent(generation)) {
      return;
    }
    _session = null;
    _hasStoredRefreshToken = true;
    _lastError = error;
    _transition(SessionStatus.unauthenticated);
  }

  static ApiError _safeFailure(String code) => switch (code) {
    'network_error' => const ApiError(
      code: 'network_error',
      message: '网络连接失败，请稍后重试',
    ),
    'timeout' => const ApiError(code: 'timeout', message: '请求超时，请稍后重试'),
    'invalid_response' => const ApiError(
      code: 'invalid_response',
      message: '服务器响应无效',
    ),
    _ => const ApiError(code: 'internal_error', message: '登录失败，请稍后重试'),
  };

  static bool _isCredential(String value) =>
      value.isNotEmpty &&
      value.length <= 4096 &&
      value.codeUnits.every((unit) => unit >= 0x21 && unit <= 0x7e);

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  void _transition(SessionStatus next) {
    if (_disposed || _status == next) {
      return;
    }
    _status = next;
    _notify();
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  String toString() =>
      'SessionController(status: ${_status.name}, credentials: <redacted>)';

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _generation += 1;
    _session = null;
    _restoreInFlight = null;
    _refreshInFlight = null;
    _credentialCleanupInFlight = null;
    _registrationInFlight = null;
    _credentialCleanupPending = false;
    super.dispose();
  }
}
