import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:gamebox/core/api/api_client.dart';
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
    expect(controller.canRegister, isTrue);
    expect(controller.canRetryRestore, isFalse);
  });

  for (final code in const ['network_error', 'timeout', 'internal_error']) {
    test(
      '$code during restore preserves the account and later retry succeeds',
      () async {
        final api = _FakeAuthApi()
          ..onRefresh = (_) => Future<Session>.error(
            ApiError(code: code, message: 'safe temporary failure'),
          );
        final store = _MemoryTokenStore(value: 'refresh-preserved');
        final controller = SessionController(
          authApi: api,
          tokenStore: store,
          now: () => now,
        );

        await controller.restore();

        expect(controller.status, SessionStatus.unauthenticated);
        expect(controller.session, isNull);
        expect(controller.lastError?.code, code);
        expect(controller.canRetryRestore, isTrue);
        expect(controller.canRegister, isFalse);
        expect(store.value, 'refresh-preserved');
        expect(store.deleteCalls, 0);

        api.onRefresh = (_) async => _session(
          accessToken: 'access-retried',
          refreshToken: 'refresh-rotated',
          now: now,
        );
        expect(await controller.retryRestore(), isTrue);
        expect(controller.status, SessionStatus.authenticated);
        expect(controller.accessToken, 'access-retried');
        expect(store.value, 'refresh-rotated');
      },
    );
  }

  test('temporary runtime refresh failure preserves credential without auth memory', () async {
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
    api.onRefresh = (_) => Future<Session>.error(
      const ApiError(code: 'network_error', message: '网络连接失败，请稍后重试'),
    );

    expect(await controller.refresh('access-one'), isFalse);
    expect(controller.status, SessionStatus.unauthenticated);
    expect(controller.accessToken, isNull);
    expect(controller.canRetryRestore, isTrue);
    expect(store.value, 'refresh-one');
    expect(store.deleteCalls, 0);

    api.onRefresh = (_) async => _session(
      accessToken: 'access-two',
      refreshToken: 'refresh-two',
      now: now,
    );
    expect(await controller.handleAppResumed(), isTrue);
    expect(controller.accessToken, 'access-two');
  });

  test(
    'registration cannot overwrite a preserved account after temporary failure',
    () async {
      final api = _FakeAuthApi()
        ..onRefresh = (_) => Future<Session>.error(
          const ApiError(code: 'timeout', message: '请求超时，请稍后重试'),
        );
      final store = _MemoryTokenStore(value: 'refresh-preserved');
      final controller = SessionController(
        authApi: api,
        tokenStore: store,
        now: () => now,
      );
      await controller.restore();

      final error = await controller.register('new-invite', '新用户');

      expect(error?.code, 'invalid_state');
      expect(api.registerCalls, 0);
      expect(store.value, 'refresh-preserved');
    },
  );

  test(
    'temporarily unavailable secure storage is retried without deletion',
    () async {
      final api = _FakeAuthApi()
        ..onRefresh = (_) async => _session(
          accessToken: 'access-retried',
          refreshToken: 'refresh-rotated',
          now: now,
        );
      final store = _MemoryTokenStore(value: 'refresh-preserved')
        ..readError = const TokenStoreException.unavailable();
      final controller = SessionController(
        authApi: api,
        tokenStore: store,
        now: () => now,
      );

      await controller.restore();

      expect(controller.canRetryRestore, isTrue);
      expect(controller.canRegister, isFalse);
      expect(store.deleteCalls, 0);
      store.readError = null;
      expect(await controller.retryRestore(), isTrue);
      expect(controller.status, SessionStatus.authenticated);
    },
  );

  test('corrupt secure storage is cleared locally', () async {
    final store = _MemoryTokenStore(value: 'corrupt')
      ..readError = const TokenStoreException.corrupt();
    final controller = SessionController(
      authApi: _FakeAuthApi(),
      tokenStore: store,
      now: () => now,
    );

    await controller.restore();

    expect(controller.status, SessionStatus.unauthenticated);
    expect(controller.canRegister, isTrue);
    expect(controller.canRetryRestore, isFalse);
    expect(store.value, isNull);
    expect(store.deleteCalls, 1);
  });

  test('failed corrupt-token deletion still blocks registration', () async {
    final store = _MemoryTokenStore(value: 'corrupt')
      ..readError = const TokenStoreException.corrupt()
      ..deleteError = const TokenStoreException.unavailable();
    final controller = SessionController(
      authApi: _FakeAuthApi(),
      tokenStore: store,
      now: () => now,
    );

    await controller.restore();

    expect(controller.canRegister, isFalse);
    expect(controller.canRetryRestore, isFalse);
    expect(controller.canRetryCredentialCleanup, isTrue);
    expect(store.value, 'corrupt');
  });

  test(
    'hanging credential deletion leaves authentication before its first await',
    () async {
      final api = _FakeAuthApi()
        ..onRefresh = (_) async => _session(
          accessToken: 'access-one',
          refreshToken: 'refresh-one',
          now: now,
        );
      final deletion = Completer<void>();
      final store = _MemoryTokenStore(value: 'refresh-zero')
        ..onDelete = () => deletion.future;
      final controller = SessionController(
        authApi: api,
        tokenStore: store,
        now: () => now,
      );
      final observed = <({SessionStatus status, bool hasSession})>[];
      controller.addListener(() {
        observed.add((
          status: controller.status,
          hasSession: controller.session != null,
        ));
      });
      await controller.restore();
      api.onRefresh = (_) => Future<Session>.error(
        const ApiError(code: 'unauthorized', message: '身份验证失败'),
      );

      final refresh = controller.refresh('access-one');
      await store.deleteStarted.future;

      expect(controller.status, SessionStatus.unauthenticated);
      expect(controller.session, isNull);
      expect(controller.accessToken, isNull);
      expect(controller.credentialCleanupPending, isTrue);
      expect(controller.canRegister, isFalse);
      expect(controller.canRetryRestore, isFalse);
      expect(controller.canRetryCredentialCleanup, isFalse);
      expect(
        observed,
        everyElement(
          predicate<({SessionStatus status, bool hasSession})>(
            (state) =>
                state.status != SessionStatus.authenticated || state.hasSession,
          ),
        ),
      );

      deletion.complete();
      expect(await refresh, isFalse);
      expect(controller.credentialCleanupPending, isFalse);
      expect(controller.canRegister, isTrue);
      expect(controller.canRetryCredentialCleanup, isFalse);
      expect(store.value, isNull);
    },
  );

  test('failed credential deletion stays locked and concurrent retry is single-flight', () async {
    const secret = 'private-platform-diagnostic';
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
    store.deleteError = PlatformException(code: 'unavailable', message: secret);
    api.onRefresh = (_) => Future<Session>.error(
      const ApiError(code: 'unauthorized', message: '身份验证失败'),
    );

    expect(await controller.refresh('access-one'), isFalse);

    expect(controller.status, SessionStatus.unauthenticated);
    expect(controller.session, isNull);
    expect(controller.canRegister, isFalse);
    expect(controller.canRetryRestore, isFalse);
    expect(controller.canRetryCredentialCleanup, isTrue);
    expect(controller.lastError.toString(), isNot(contains(secret)));
    expect(store.value, 'refresh-one');

    final deletion = Completer<void>();
    store.deleteError = null;
    store.onDelete = () => deletion.future;
    store.deleteStarted = Completer<void>();
    final first = controller.retryCredentialCleanup();
    final second = controller.retryCredentialCleanup();

    expect(identical(first, second), isTrue);
    await store.deleteStarted.future;
    expect(controller.credentialCleanupPending, isTrue);
    expect(controller.canRegister, isFalse);
    expect(store.deleteCalls, 2);

    deletion.complete();
    expect(await first, isTrue);
    expect(await second, isTrue);
    expect(controller.canRegister, isTrue);
    expect(controller.canRetryCredentialCleanup, isFalse);
    expect(store.value, isNull);
  });

  test(
    'concurrent unauthorized refreshes start one credential cleanup',
    () async {
      final api = _FakeAuthApi()
        ..onRefresh = (_) async => _session(
          accessToken: 'access-one',
          refreshToken: 'refresh-one',
          now: now,
        );
      final deletion = Completer<void>();
      final store = _MemoryTokenStore(value: 'refresh-zero')
        ..onDelete = () => deletion.future;
      final controller = SessionController(
        authApi: api,
        tokenStore: store,
        now: () => now,
      );
      await controller.restore();
      api.onRefresh = (_) => Future<Session>.error(
        const ApiError(code: 'unauthorized', message: '身份验证失败'),
      );

      final first = controller.refresh('access-one');
      final second = controller.refresh('access-one');
      expect(identical(first, second), isTrue);
      await store.deleteStarted.future;

      expect(store.deleteCalls, 1);
      deletion.complete();
      expect(await first, isFalse);
      expect(await second, isFalse);
    },
  );

  test(
    'dispose during credential cleanup causes no late notification',
    () async {
      final api = _FakeAuthApi()
        ..onRefresh = (_) async => _session(
          accessToken: 'access-one',
          refreshToken: 'refresh-one',
          now: now,
        );
      final deletion = Completer<void>();
      final store = _MemoryTokenStore(value: 'refresh-zero')
        ..onDelete = () => deletion.future;
      final controller = SessionController(
        authApi: api,
        tokenStore: store,
        now: () => now,
      );
      await controller.restore();
      api.onRefresh = (_) => Future<Session>.error(
        const ApiError(code: 'unauthorized', message: '身份验证失败'),
      );
      var notifications = 0;
      controller.addListener(() => notifications += 1);

      final refresh = controller.refresh('access-one');
      await store.deleteStarted.future;
      expect(notifications, 1);
      controller.dispose();
      deletion.complete();
      await refresh;

      expect(notifications, 1);
    },
  );

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

  test('a delayed 401 for an old access token does not rotate again', () async {
    final api = _FakeAuthApi()
      ..onRefresh = (_) async => _session(
        accessToken: 'access-current',
        refreshToken: 'refresh-current',
        now: now,
      );
    final controller = SessionController(
      authApi: api,
      tokenStore: _MemoryTokenStore(value: 'refresh-old'),
      now: () => now,
    );
    await controller.restore();
    final callsAfterRestore = api.refreshCalls;

    expect(await controller.refresh('access-stale'), isTrue);
    expect(api.refreshCalls, callsAfterRestore);
    expect(controller.accessToken, 'access-current');
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
    'nickname success replaces only the current in-memory session user',
    () async {
      final api = _FakeAuthApi();
      api.onRefresh = (_) async => _session(
        accessToken: 'access-one',
        refreshToken: 'refresh-one',
        now: now,
      );
      api.onUpdateNickname = (nickname, accessToken, onUnauthorized) async {
        expect(nickname, '新昵称');
        expect(accessToken(), 'access-one');
        return const SessionUser(
          id: '11111111-1111-4111-8111-111111111111',
          nickname: '新昵称',
        );
      };
      final store = _MemoryTokenStore(value: 'refresh-zero');
      final controller = SessionController(
        authApi: api,
        tokenStore: store,
        now: () => now,
      );
      await controller.restore();
      final before = controller.session!;
      final writesAfterRestore = List<String>.of(store.writes);

      final error = await controller.updateNickname('新昵称');

      expect(error, isNull);
      final after = controller.session!;
      expect(after.user.nickname, '新昵称');
      expect(after.user.id, before.user.id);
      expect(after.accessToken, before.accessToken);
      expect(after.accessExpiresAt, before.accessExpiresAt);
      expect(after.refreshToken, before.refreshToken);
      expect(after.refreshExpiresAt, before.refreshExpiresAt);
      expect(store.writes, writesAfterRestore);
    },
  );

  test(
    'newer nickname completion supersedes an older in-flight response',
    () async {
      final first = Completer<SessionUser>();
      final second = Completer<SessionUser>();
      final api = _FakeAuthApi();
      api.onRefresh = (_) async => _session(
        accessToken: 'access-one',
        refreshToken: 'refresh-one',
        now: now,
      );
      api.onUpdateNickname = (nickname, _, _) =>
          nickname == '第一版' ? first.future : second.future;
      final controller = SessionController(
        authApi: api,
        tokenStore: _MemoryTokenStore(value: 'refresh-zero'),
        now: () => now,
      );
      await controller.restore();

      final oldUpdate = controller.updateNickname('第一版');
      final newUpdate = controller.updateNickname('第二版');
      second.complete(
        const SessionUser(
          id: '11111111-1111-4111-8111-111111111111',
          nickname: '第二版',
        ),
      );
      expect(await newUpdate, isNull);
      first.complete(
        const SessionUser(
          id: '11111111-1111-4111-8111-111111111111',
          nickname: '第一版',
        ),
      );
      expect(await oldUpdate, isNull);

      expect(controller.session?.user.nickname, '第二版');
    },
  );

  test(
    'nickname completion after token refresh preserves rotated credentials',
    () async {
      final update = Completer<SessionUser>();
      final api = _FakeAuthApi();
      api.onRefresh = (_) async => _session(
        accessToken: 'access-one',
        refreshToken: 'refresh-one',
        now: now,
      );
      api.onUpdateNickname = (_, _, _) => update.future;
      final controller = SessionController(
        authApi: api,
        tokenStore: _MemoryTokenStore(value: 'refresh-zero'),
        now: () => now,
      );
      await controller.restore();
      final nicknameUpdate = controller.updateNickname('新昵称');
      api.onRefresh = (_) async => _session(
        accessToken: 'access-two',
        refreshToken: 'refresh-two',
        now: now,
      );
      expect(await controller.refresh(), isTrue);
      update.complete(
        const SessionUser(
          id: '11111111-1111-4111-8111-111111111111',
          nickname: '新昵称',
        ),
      );

      expect(await nicknameUpdate, isNull);
      expect(controller.session?.user.nickname, '新昵称');
      expect(controller.session?.accessToken, 'access-two');
      expect(controller.session?.refreshToken, 'refresh-two');
    },
  );

  test('nickname response must confirm the exact requested nickname', () async {
    final api = _FakeAuthApi();
    api.onRefresh = (_) async => _session(
      accessToken: 'access-one',
      refreshToken: 'refresh-one',
      now: now,
    );
    api.onUpdateNickname = (_, _, _) async => const SessionUser(
      id: '11111111-1111-4111-8111-111111111111',
      nickname: '其他合法名',
    );
    final controller = SessionController(
      authApi: api,
      tokenStore: _MemoryTokenStore(value: 'refresh-zero'),
      now: () => now,
    );
    await controller.restore();

    final error = await controller.updateNickname('请求昵称');

    expect(error?.code, 'invalid_response');
    expect(controller.session?.user.nickname, '小鱼');
    expect(controller.session?.accessToken, 'access-one');
  });

  test('nickname completion from an old user generation cannot overwrite a new account', () async {
    final staleUpdate = Completer<SessionUser>();
    final api = _FakeAuthApi();
    api.onRefresh = (_) async => _session(
      accessToken: 'old-access',
      refreshToken: 'old-refresh',
      now: now,
    );
    api.onUpdateNickname = (_, _, _) => staleUpdate.future;
    final controller = SessionController(
      authApi: api,
      tokenStore: _MemoryTokenStore(value: 'stored-refresh'),
      now: () => now,
    );
    await controller.restore();
    final oldUpdate = controller.updateNickname('旧请求');
    api.onRefresh = (_) => Future<Session>.error(
      const ApiError(code: 'unauthorized', message: '身份验证失败'),
    );
    expect(await controller.refresh(), isFalse);
    api.onRegister = (_, _) async => _session(
      accessToken: 'new-access',
      refreshToken: 'new-refresh',
      now: now,
      userId: '22222222-2222-4222-8222-222222222222',
      nickname: '新用户',
    );
    expect(await controller.register('new-invite', '新用户'), isNull);

    staleUpdate.complete(
      const SessionUser(
        id: '11111111-1111-4111-8111-111111111111',
        nickname: '旧请求',
      ),
    );
    await oldUpdate;

    expect(controller.session?.user.id, '22222222-2222-4222-8222-222222222222');
    expect(controller.session?.user.nickname, '新用户');
    expect(controller.session?.accessToken, 'new-access');
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
  String userId = '11111111-1111-4111-8111-111111111111',
  String nickname = '小鱼',
}) {
  return Session(
    user: SessionUser(id: userId, nickname: nickname),
    accessToken: accessToken,
    accessExpiresAt: accessExpiresAt ?? now.add(const Duration(minutes: 15)),
    refreshToken: refreshToken,
    refreshExpiresAt: refreshExpiresAt ?? now.add(const Duration(days: 30)),
  );
}

final class _FakeAuthApi implements AuthApi {
  Future<Session> Function(String refreshToken)? onRefresh;
  Future<Session> Function(String inviteCode, String nickname)? onRegister;
  Future<SessionUser> Function(
    String nickname,
    AccessTokenProvider accessToken,
    UnauthorizedHandler onUnauthorized,
  )?
  onUpdateNickname;
  int refreshCalls = 0;
  int registerCalls = 0;
  int updateNicknameCalls = 0;
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

  @override
  Future<SessionUser> updateNickname(
    String nickname, {
    required AccessTokenProvider accessToken,
    required UnauthorizedHandler onUnauthorized,
  }) {
    updateNicknameCalls += 1;
    return onUpdateNickname?.call(nickname, accessToken, onUnauthorized) ??
        Future<SessionUser>.error(StateError('unexpected nickname update'));
  }
}

final class _MemoryTokenStore implements TokenStore {
  _MemoryTokenStore({this.value});

  String? value;
  Object? readError;
  Object? writeError;
  Object? deleteError;
  Future<void> Function()? onDelete;
  Completer<void> deleteStarted = Completer<void>();
  int deleteCalls = 0;
  final writes = <String>[];

  @override
  Future<void> deleteRefreshToken() async {
    deleteCalls += 1;
    if (!deleteStarted.isCompleted) {
      deleteStarted.complete();
    }
    await onDelete?.call();
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
