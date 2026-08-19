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

  final AuthApi _authApi;
  final TokenStore _tokenStore;
  final DateTime Function() _now;

  SessionStatus _status = SessionStatus.restoring;
  Session? _session;
  Future<bool>? _refreshInFlight;
  Future<ApiError?>? _registrationInFlight;
  var _generation = 0;
  var _disposed = false;

  SessionStatus get status => _status;
  Session? get session => _session;
  String? get accessToken => _session?.accessToken;

  Future<void> restore() async {
    if (_disposed || _status != SessionStatus.restoring) {
      return;
    }
    final generation = ++_generation;
    String? refreshToken;
    try {
      refreshToken = await _tokenStore.readRefreshToken();
    } catch (_) {
      if (_isCurrent(generation)) {
        await _failClosed(generation);
      }
      return;
    }
    if (!_isCurrent(generation)) {
      return;
    }
    if (refreshToken == null) {
      _transition(SessionStatus.unauthenticated);
      return;
    }
    if (refreshToken.isEmpty) {
      await _failClosed(generation);
      return;
    }
    try {
      final rotated = await _authApi.refresh(refreshToken);
      if (!_isCurrent(generation)) {
        return;
      }
      if (!rotated.refreshExpiresAt.isAfter(_now())) {
        await _failClosed(generation);
        return;
      }
      await _persistAndPublish(rotated, generation);
    } catch (_) {
      if (_isCurrent(generation)) {
        await _failClosed(generation);
      }
    }
  }

  Future<ApiError?> register(String inviteCode, String nickname) {
    final existing = _registrationInFlight;
    if (existing != null) {
      return existing;
    }
    if (_disposed || _status != SessionStatus.unauthenticated) {
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
        await _failClosed(generation);
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
        _transition(SessionStatus.unauthenticated);
      }
      return error;
    } catch (_) {
      if (_isCurrent(generation)) {
        _session = null;
        _transition(SessionStatus.unauthenticated);
      }
      return const ApiError(code: 'internal_error', message: '注册失败，请稍后重试');
    }
  }

  /// Refreshes credentials once. Concurrent callers receive this exact Future.
  Future<bool> refresh() {
    final existing = _refreshInFlight;
    if (existing != null) {
      return existing;
    }
    final current = _session;
    if (_disposed ||
        _status != SessionStatus.authenticated ||
        current == null) {
      return Future<bool>.value(false);
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
      await _failClosed(generation);
      return false;
    }
    try {
      final rotated = await _authApi.refresh(previous.refreshToken);
      if (!_isCurrent(generation) || _status != SessionStatus.authenticated) {
        return false;
      }
      if (rotated.user.id != previous.user.id ||
          !rotated.refreshExpiresAt.isAfter(_now())) {
        await _failClosed(generation);
        return false;
      }
      return _persistAndPublish(rotated, generation);
    } catch (_) {
      if (_isCurrent(generation)) {
        await _failClosed(generation);
      }
      return false;
    }
  }

  Future<bool> handleAppResumed() {
    final current = _session;
    if (_disposed ||
        _status != SessionStatus.authenticated ||
        current == null) {
      return Future<bool>.value(false);
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
        await _failClosed(generation);
      }
      return false;
    }
    if (!_isCurrent(generation)) {
      return false;
    }
    _session = next;
    _status = SessionStatus.authenticated;
    _notify();
    return true;
  }

  Future<void> _failClosed(int generation) async {
    if (!_isCurrent(generation)) {
      return;
    }
    _session = null;
    try {
      await _tokenStore.deleteRefreshToken();
    } catch (_) {
      // Authentication still fails closed in memory if secure storage itself
      // is temporarily unavailable.
    }
    if (_isCurrent(generation)) {
      _transition(SessionStatus.unauthenticated);
    }
  }

  bool _isCurrent(int generation) {
    return !_disposed && generation == _generation;
  }

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
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _generation += 1;
    _session = null;
    _refreshInFlight = null;
    _registrationInFlight = null;
    super.dispose();
  }
}
