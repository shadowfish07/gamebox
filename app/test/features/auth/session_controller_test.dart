import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/core/api/api_error.dart';
import 'package:gamebox/core/auth/session.dart';
import 'package:gamebox/core/auth/token_store.dart';
import 'package:gamebox/features/auth/auth_api.dart';
import 'package:gamebox/features/auth/session_controller.dart';

void main() {
  final now = DateTime.utc(2026, 8, 20, 12);

  test('restore without a refresh token becomes unauthenticated', () async {
    final api = _FakeAuthApi();
    final store = _MemoryTokenStore();
    final controller = SessionController(
      authApi: api,
      tokenStore: store,
      now: () => now,
    );

    await controller.restore();

    expect(controller.status, SessionStatus.unauthenticated);
    expect(controller.session, isNull);
    expect(controller.accessToken, isNull);
    expect(api.refreshCalls, 0);
  });

  test('restore rotates the refresh token before authenticating', () async {
    final api = _FakeAuthApi()
      ..onRefresh = (_) async => _session(
        accessToken: 'access-new',
        refreshToken: 'refresh-new',
        now: now,
      );
    final store = _MemoryTokenStore(value: 'refresh-old');
    final controller = SessionController(
      authApi: api,
      tokenStore: store,
      now: () => now,
    );
    var authenticatedAfterStorage = false;
    controller.addListener(() {
      if (controller.status == SessionStatus.authenticated) {
        authenticatedAfterStorage = store.value == 'refresh-new';
      }
    });

    await controller.restore();

    expect(controller.status, SessionStatus.authenticated);
    expect(controller.accessToken, 'access-new');
    expect(store.value, 'refresh-new');
    expect(store.writes, ['refresh-new']);
    expect(authenticatedAfterStorage, isTrue);
  });

  test('invalid stored refresh token is deleted and fails closed', () async {
    final api = _FakeAuthApi()
      ..onRefresh = (_) => Future<Session>.error(
        const ApiError(code: 'unauthorized', message: '身份验证失败'),
      );
    final store = _MemoryTokenStore(value: 'refresh-invalid');
    final controller = SessionController(
      authApi: api,
      tokenStore: store,
      now: () => now,
    );

    await controller.restore();

    expect(controller.status, SessionStatus.unauthenticated);
    expect(controller.session, isNull);
    expect(store.value, isNull);
    expect(store.deleteCalls, 1);
  });

  test(
    'registration storage failure never publishes its access token',
    () async {
      final api = _FakeAuthApi()
        ..onRegister = (_, _) async => _session(
          accessToken: 'unpublishable-access',
          refreshToken: 'unpersistable-refresh',
          now: now,
        );
      final store = _MemoryTokenStore()
        ..writeError = StateError('secure storage unavailable');
      final controller = SessionController(
        authApi: api,
        tokenStore: store,
        now: () => now,
      );
      await controller.restore();

      final error = await controller.register('invite-one', '小鱼');

      expect(error?.code, 'storage_error');
      expect(controller.status, SessionStatus.unauthenticated);
      expect(controller.accessToken, isNull);
      expect(store.value, isNull);
    },
  );

  test('refresh rejects a session rotated to a different user', () async {
    final api = _FakeAuthApi()
      ..onRefresh = (_) async => _session(
        accessToken: 'access-one',
        refreshToken: 'refresh-one',
        now: now,
      );
    final store = _MemoryTokenStore(value: 'refresh-zero');
    final controller = SessionController(
      authApi: api,
      tokenStore: store,
      now: () => now,
    );
    await controller.restore();
    api.onRefresh = (_) async => Session(
      user: const SessionUser(
        id: '22222222-2222-4222-8222-222222222222',
        nickname: '别的用户',
      ),
      accessToken: 'wrong-user-access',
      accessExpiresAt: now.add(const Duration(minutes: 15)),
      refreshToken: 'wrong-user-refresh',
      refreshExpiresAt: now.add(const Duration(days: 30)),
    );

    expect(await controller.refresh(), isFalse);
    expect(controller.status, SessionStatus.unauthenticated);
    expect(controller.accessToken, isNull);
    expect(store.value, isNull);
  });

  test(
    'expired refresh credential is cleared without a network call',
    () async {
      var clock = now.subtract(const Duration(minutes: 1));
      final api = _FakeAuthApi()
        ..onRefresh = (_) async => _session(
          accessToken: 'access-one',
          refreshToken: 'refresh-one',
          now: now,
          accessExpiresAt: now.subtract(const Duration(minutes: 2)),
          refreshExpiresAt: now,
        );
      final store = _MemoryTokenStore(value: 'refresh-zero');
      final controller = SessionController(
        authApi: api,
        tokenStore: store,
        now: () => clock,
      );
      await controller.restore();
      expect(controller.status, SessionStatus.authenticated);
      final callsAfterRestore = api.refreshCalls;
      clock = now;

      expect(await controller.refresh(), isFalse);
      expect(api.refreshCalls, callsAfterRestore);
      expect(controller.status, SessionStatus.unauthenticated);
    },
  );

  test(
    'registration saves the rotated refresh token and authenticates',
    () async {
      final api = _FakeAuthApi()
        ..onRegister = (invite, nickname) async {
          expect(invite, 'invite-one');
          expect(nickname, '小鱼');
          return _session(
            accessToken: 'registered-access',
            refreshToken: 'registered-refresh',
            now: now,
          );
        };
      final store = _MemoryTokenStore();
      final controller = SessionController(
        authApi: api,
        tokenStore: store,
        now: () => now,
      );
      await controller.restore();

      final error = await controller.register('invite-one', '小鱼');

      expect(error, isNull);
      expect(controller.status, SessionStatus.authenticated);
      expect(controller.accessToken, 'registered-access');
      expect(store.value, 'registered-refresh');
    },
  );

  test('registration API failure never writes a refresh token', () async {
    final api = _FakeAuthApi()
      ..onRegister = (_, _) => Future<Session>.error(
        const ApiError(code: 'invite_invalid', message: '邀请码无效或已使用'),
      );
    final store = _MemoryTokenStore();
    final controller = SessionController(
      authApi: api,
      tokenStore: store,
      now: () => now,
    );
    await controller.restore();

    final error = await controller.register('bad-invite', '小鱼');

    expect(error?.code, 'invite_invalid');
    expect(controller.status, SessionStatus.unauthenticated);
    expect(store.writes, isEmpty);
  });

  test('concurrent 401 refresh callers share exactly one Future', () async {
    final api = _FakeAuthApi()
      ..onRefresh = (_) async => _session(
        accessToken: 'access-one',
        refreshToken: 'refresh-one',
        now: now,
      );
    final store = _MemoryTokenStore(value: 'refresh-zero');
    final controller = SessionController(
      authApi: api,
      tokenStore: store,
      now: () => now,
    );
    await controller.restore();
    final pending = Completer<Session>();
    api.onRefresh = (_) => pending.future;

    final first = controller.refresh();
    final second = controller.refresh();

    expect(identical(first, second), isTrue);
    expect(api.refreshCalls, 2); // one restore and one shared 401 refresh
    pending.complete(
      _session(
        accessToken: 'access-two',
        refreshToken: 'refresh-two',
        now: now,
      ),
    );
    expect(await first, isTrue);
    expect(await second, isTrue);
    expect(store.value, 'refresh-two');
  });

  test('refresh rotation storage failure clears all authentication', () async {
    final api = _FakeAuthApi()
      ..onRefresh = (_) async => _session(
        accessToken: 'access-one',
        refreshToken: 'refresh-one',
        now: now,
      );
    final store = _MemoryTokenStore(value: 'refresh-zero');
    final controller = SessionController(
      authApi: api,
      tokenStore: store,
      now: () => now,
    );
    await controller.restore();
    store.writeError = StateError('secure storage unavailable');
    api.onRefresh = (_) async => _session(
      accessToken: 'secret-access-that-must-not-be-published',
      refreshToken: 'secret-refresh-that-could-not-be-saved',
      now: now,
    );

    expect(await controller.refresh(), isFalse);

    expect(controller.status, SessionStatus.unauthenticated);
    expect(controller.session, isNull);
    expect(controller.accessToken, isNull);
    expect(store.value, isNull);
    expect(store.deleteCalls, 1);
  });

  test(
    'resume refreshes only when the in-memory access token is expired',
    () async {
      var clock = now;
      final api = _FakeAuthApi()
        ..onRefresh = (_) async => _session(
          accessToken: 'access-one',
          refreshToken: 'refresh-one',
          now: now,
          accessExpiresAt: now.add(const Duration(minutes: 1)),
        );
      final store = _MemoryTokenStore(value: 'refresh-zero');
      final controller = SessionController(
        authApi: api,
        tokenStore: store,
        now: () => clock,
      );
      await controller.restore();

      expect(await controller.handleAppResumed(), isTrue);
      expect(api.refreshCalls, 1);

      clock = now.add(const Duration(minutes: 1));
      api.onRefresh = (_) async => _session(
        accessToken: 'access-two',
        refreshToken: 'refresh-two',
        now: clock,
      );
      expect(await controller.handleAppResumed(), isTrue);
      expect(api.refreshCalls, 2);
      expect(controller.accessToken, 'access-two');
    },
  );

  test(
    'dispose cancels stale completion and never notifies listeners',
    () async {
      final pending = Completer<Session>();
      final api = _FakeAuthApi()..onRefresh = (_) => pending.future;
      final store = _MemoryTokenStore(value: 'refresh-old');
      final controller = SessionController(
        authApi: api,
        tokenStore: store,
        now: () => now,
      );
      var notifications = 0;
      controller.addListener(() => notifications += 1);

      final restoring = controller.restore();
      await api.refreshStarted.future;
      controller.dispose();
      pending.complete(
        _session(
          accessToken: 'stale-access',
          refreshToken: 'stale-refresh',
          now: now,
        ),
      );
      await restoring;

      expect(notifications, 0);
      expect(store.writes, isEmpty);
      expect(store.value, 'refresh-old');
    },
  );

  test(
    'dispose cancels stale registration before secure storage changes',
    () async {
      final pending = Completer<Session>();
      final api = _FakeAuthApi()..onRegister = (_, _) => pending.future;
      final store = _MemoryTokenStore();
      final controller = SessionController(
        authApi: api,
        tokenStore: store,
        now: () => now,
      );
      await controller.restore();

      final registering = controller.register('invite-one', '小鱼');
      controller.dispose();
      pending.complete(
        _session(
          accessToken: 'stale-access',
          refreshToken: 'stale-refresh',
          now: now,
        ),
      );
      await registering;

      expect(store.writes, isEmpty);
      expect(store.value, isNull);
    },
  );
}

Session _session({
  required String accessToken,
  required String refreshToken,
  required DateTime now,
  DateTime? accessExpiresAt,
  DateTime? refreshExpiresAt,
}) {
  return Session(
    user: const SessionUser(
      id: '11111111-1111-4111-8111-111111111111',
      nickname: '小鱼',
    ),
    accessToken: accessToken,
    accessExpiresAt: accessExpiresAt ?? now.add(const Duration(minutes: 15)),
    refreshToken: refreshToken,
    refreshExpiresAt: refreshExpiresAt ?? now.add(const Duration(days: 30)),
  );
}

final class _FakeAuthApi implements AuthApi {
  Future<Session> Function(String refreshToken)? onRefresh;
  Future<Session> Function(String inviteCode, String nickname)? onRegister;
  int refreshCalls = 0;
  int registerCalls = 0;
  final refreshStarted = Completer<void>();

  @override
  Future<Session> refresh(String refreshToken) {
    refreshCalls += 1;
    if (!refreshStarted.isCompleted) {
      refreshStarted.complete();
    }
    return onRefresh?.call(refreshToken) ??
        Future<Session>.error(StateError('unexpected refresh'));
  }

  @override
  Future<Session> register(String inviteCode, String nickname) {
    registerCalls += 1;
    return onRegister?.call(inviteCode, nickname) ??
        Future<Session>.error(StateError('unexpected register'));
  }
}

final class _MemoryTokenStore implements TokenStore {
  _MemoryTokenStore({this.value});

  String? value;
  Object? readError;
  Object? writeError;
  Object? deleteError;
  int deleteCalls = 0;
  final writes = <String>[];

  @override
  Future<void> deleteRefreshToken() async {
    deleteCalls += 1;
    if (deleteError != null) {
      throw deleteError!;
    }
    value = null;
  }

  @override
  Future<String?> readRefreshToken() async {
    if (readError != null) {
      throw readError!;
    }
    return value;
  }

  @override
  Future<void> writeRefreshToken(String refreshToken) async {
    if (writeError != null) {
      throw writeError!;
    }
    writes.add(refreshToken);
    value = refreshToken;
  }
}
