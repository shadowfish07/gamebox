import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/core/api/api_error.dart';
import 'package:gamebox/core/profile/app_profile.dart';
import 'package:gamebox/core/profile/app_profile_store.dart';
import 'package:gamebox/core/profile/nickname_rules.dart';
import 'package:gamebox/features/profile/profile_controller.dart';

void main() {
  test(
    'first launch becomes nickname setup without a public session',
    () async {
      final controller = ProfileController(
        store: _MemoryProfileStore(),
        nicknameRules: const _FixtureRules(),
      );

      await controller.load();

      expect(controller.status, ProfileStatus.needsNickname);
      expect(controller.profile, isNull);
    },
  );

  test(
    'corrupt local bytes stay a distinct recoverable load failure',
    () async {
      final store = _MemoryProfileStore()
        ..readError = const ProfileLoadFailure.corrupt();
      final controller = ProfileController(
        store: store,
        nicknameRules: const _FixtureRules(),
      );

      await controller.load();
      await controller.reconcileRestoredNickname('服务器昵称');

      expect(controller.status, ProfileStatus.loadFailure);
      expect(controller.profile, isNull);
      expect(store.writes, isEmpty);
    },
  );

  test(
    'local commit normalizes once and persists pending public sync',
    () async {
      final store = _MemoryProfileStore();
      final controller = ProfileController(
        store: store,
        nicknameRules: const _FixtureRules(),
      );
      await controller.load();

      expect(await controller.commitNickname('  Local Hero  '), isNull);

      expect(controller.status, ProfileStatus.ready);
      expect(controller.profile?.nickname, 'Local Hero');
      expect(controller.profile?.syncState, ProfileSyncState.pending);
      expect(store.writes, [controller.profile]);
    },
  );

  test(
    'successful old public restore migrates once when profile is absent',
    () async {
      final store = _MemoryProfileStore();
      final controller = ProfileController(
        store: store,
        nicknameRules: const _FixtureRules(),
      );
      await controller.load();

      await controller.reconcileRestoredNickname('旧公服玩家');
      await controller.reconcileRestoredNickname('后来服务器值');

      expect(controller.profile?.nickname, '旧公服玩家');
      expect(controller.profile?.syncState, ProfileSyncState.pending);
      expect(controller.profile?.lastSyncedNickname, '后来服务器值');
      expect(store.writes, hasLength(2));
    },
  );

  test(
    'local commit wins a later differing restored public nickname',
    () async {
      final store = _MemoryProfileStore();
      final controller = ProfileController(
        store: store,
        nicknameRules: const _FixtureRules(),
      );
      await controller.load();

      await controller.commitNickname('本地玩家');
      await controller.reconcileRestoredNickname('服务器玩家');

      expect(controller.profile?.nickname, '本地玩家');
      expect(controller.profile?.syncState, ProfileSyncState.pending);
      expect(controller.profile?.lastSyncedNickname, '服务器玩家');
    },
  );

  test(
    'local commit wins even while migration write is already queued',
    () async {
      final firstWrite = Completer<void>();
      final store = _MemoryProfileStore()..firstWriteBarrier = firstWrite;
      final controller = ProfileController(
        store: store,
        nicknameRules: const _FixtureRules(),
      );
      await controller.load();

      final migration = controller.reconcileRestoredNickname('服务器玩家');
      await store.firstWriteStarted.future;
      final local = controller.commitNickname('本地玩家');
      firstWrite.complete();
      await Future.wait([migration, local]);

      expect(controller.profile?.nickname, '本地玩家');
      expect(store.value?.nickname, '本地玩家');
      expect(controller.profile?.syncState, ProfileSyncState.pending);
    },
  );

  test(
    'invalid local attempt cannot cancel migration awaiting normalization',
    () async {
      final rules = _DelayedRules();
      final store = _MemoryProfileStore();
      final controller = ProfileController(store: store, nicknameRules: rules);
      await controller.load();

      final migration = controller.reconcileRestoredNickname('服务器玩家');
      await rules.started('服务器玩家');
      final local = controller.commitNickname('x');
      rules.succeed('服务器玩家', '服务器玩家');
      await rules.started('x');
      rules.reject('x');

      expect(await local, ProfileCommitFailure.invalidNickname);
      await migration;
      expect(
        store.value,
        const AppProfile(
          schemaVersion: 1,
          nickname: '服务器玩家',
          syncState: ProfileSyncState.synced,
          lastSyncedNickname: '服务器玩家',
        ),
      );
    },
  );

  test(
    'failed local write cannot cancel migration awaiting normalization',
    () async {
      final rules = _DelayedRules();
      final store = _MemoryProfileStore()..failNickname = '本地玩家';
      final controller = ProfileController(store: store, nicknameRules: rules);
      await controller.load();

      final migration = controller.reconcileRestoredNickname('服务器玩家');
      await rules.started('服务器玩家');
      final local = controller.commitNickname('本地玩家');
      rules.succeed('服务器玩家', '服务器玩家');
      await rules.started('本地玩家');
      rules.succeed('本地玩家', '本地玩家');

      expect(await local, ProfileCommitFailure.unavailable);
      await migration;
      expect(store.value?.nickname, '服务器玩家');
      expect(store.value?.syncState, ProfileSyncState.synced);
    },
  );

  test(
    'successful local write still wins migration awaiting normalization',
    () async {
      final rules = _DelayedRules();
      final store = _MemoryProfileStore();
      final controller = ProfileController(store: store, nicknameRules: rules);
      await controller.load();

      final migration = controller.reconcileRestoredNickname('服务器玩家');
      await rules.started('服务器玩家');
      final local = controller.commitNickname('本地玩家');
      rules.succeed('服务器玩家', '服务器玩家');
      await rules.started('本地玩家');
      rules.succeed('本地玩家', '本地玩家');

      expect(await local, isNull);
      await migration;
      expect(store.value?.nickname, '本地玩家');
      expect(store.value?.syncState, ProfileSyncState.pending);
      expect(store.value?.lastSyncedNickname, '服务器玩家');
    },
  );

  test(
    'failed absent migration is surfaced and load retry keeps intent',
    () async {
      final store = _MemoryProfileStore()..failNickname = '服务器玩家';
      final controller = ProfileController(
        store: store,
        nicknameRules: const _FixtureRules(),
      );
      await controller.load();

      await controller.reconcileRestoredNickname('服务器玩家');

      expect(controller.profile, isNull);
      expect(controller.status, ProfileStatus.loadFailure);
      expect(
        controller.reconciliationFailure,
        ProfileReconciliationFailure.unavailable,
      );
      store.failNickname = null;

      await controller.load();

      expect(controller.status, ProfileStatus.ready);
      expect(controller.profile?.nickname, '服务器玩家');
      expect(controller.profile?.syncState, ProfileSyncState.synced);
      expect(controller.reconciliationFailure, isNull);
    },
  );

  test(
    'failed pending persistence keeps local profile and retries explicitly',
    () async {
      final store = _MemoryProfileStore()
        ..value = const AppProfile(
          schemaVersion: 1,
          nickname: '本地玩家',
          syncState: ProfileSyncState.pending,
        )
        ..failNickname = '本地玩家';
      final controller = ProfileController(
        store: store,
        nicknameRules: const _FixtureRules(),
      );
      await controller.load();

      await controller.reconcileRestoredNickname('服务器玩家');

      expect(controller.status, ProfileStatus.ready);
      expect(controller.profile?.nickname, '本地玩家');
      expect(controller.profile?.lastSyncedNickname, isNull);
      expect(
        controller.reconciliationFailure,
        ProfileReconciliationFailure.unavailable,
      );
      store.failNickname = null;

      await controller.retryReconciliation();

      expect(controller.status, ProfileStatus.ready);
      expect(controller.profile?.nickname, '本地玩家');
      expect(controller.profile?.syncState, ProfileSyncState.pending);
      expect(controller.profile?.lastSyncedNickname, '服务器玩家');
      expect(controller.reconciliationFailure, isNull);
    },
  );

  test(
    'matching restored nickname clears pending without PATCH behavior',
    () async {
      final store = _MemoryProfileStore();
      final controller = ProfileController(
        store: store,
        nicknameRules: const _FixtureRules(),
      );
      await controller.load();
      await controller.commitNickname('相同昵称');

      await controller.reconcileRestoredNickname('相同昵称');

      expect(controller.profile?.syncState, ProfileSyncState.synced);
      expect(controller.profile?.lastSyncedNickname, '相同昵称');
    },
  );

  test(
    'local nickname commits before its immediate public PATCH completes',
    () async {
      final store = _MemoryProfileStore();
      final patch = Completer<ApiError?>();
      final calls = <String>[];
      final controller = ProfileController(
        store: store,
        nicknameRules: const _FixtureRules(),
      );
      await controller.load();
      await controller.authenticatedSessionStarted(
        userId: '11111111-1111-4111-8111-111111111111',
        serverNickname: '服务器玩家',
        updateNickname: (nickname) {
          calls.add(nickname);
          return patch.future;
        },
      );

      final failure = await controller.commitNickname('本地玩家');

      expect(failure, isNull);
      expect(store.value?.nickname, '本地玩家');
      expect(store.value?.syncState, ProfileSyncState.pending);
      expect(controller.status, ProfileStatus.ready);
      expect(calls, ['本地玩家']);
      expect(patch.isCompleted, isFalse);
      patch.complete(const ApiError(code: 'network_error', message: '暂时失败'));
      await _drainAsync();
    },
  );

  test(
    'automatic retries use a rolling five minute nickname cooldown',
    () async {
      var now = DateTime.utc(2026, 8, 25, 10);
      final calls = <String>[];
      final store = _MemoryProfileStore()
        ..value = const AppProfile(
          schemaVersion: 1,
          nickname: '本地玩家',
          syncState: ProfileSyncState.pending,
          lastSyncedNickname: '服务器玩家',
        );
      final controller = ProfileController(
        store: store,
        nicknameRules: const _FixtureRules(),
        now: () => now,
      );
      await controller.load();
      await controller.authenticatedSessionStarted(
        userId: '11111111-1111-4111-8111-111111111111',
        serverNickname: '服务器玩家',
        updateNickname: (nickname) async {
          calls.add(nickname);
          return const ApiError(code: 'network_error', message: '暂时失败');
        },
      );
      expect(calls, ['本地玩家']);

      now = now.add(const Duration(minutes: 4, seconds: 59));
      await controller.handleAppResumed();
      expect(calls, ['本地玩家']);

      now = now.add(const Duration(seconds: 1));
      await controller.handleAppResumed();
      expect(calls, ['本地玩家', '本地玩家']);

      await controller.retryPublicSync();
      expect(calls, ['本地玩家', '本地玩家', '本地玩家']);

      await controller.commitNickname('全新意图');
      await _drainAsync();
      expect(calls.last, '全新意图');
      expect(calls, hasLength(4));
    },
  );

  for (final code in const [
    'network_error',
    'timeout',
    'internal_error',
    'unauthorized',
  ]) {
    test('$code retains a ready pending profile', () async {
      final store = _MemoryProfileStore()
        ..value = const AppProfile(
          schemaVersion: 1,
          nickname: '本地玩家',
          syncState: ProfileSyncState.pending,
          lastSyncedNickname: '服务器玩家',
        );
      final controller = ProfileController(
        store: store,
        nicknameRules: const _FixtureRules(),
      );
      await controller.load();

      await controller.authenticatedSessionStarted(
        userId: '11111111-1111-4111-8111-111111111111',
        serverNickname: '服务器玩家',
        updateNickname: (_) async => ApiError(code: code, message: '安全错误'),
      );

      expect(controller.status, ProfileStatus.ready);
      expect(controller.profile?.nickname, '本地玩家');
      expect(controller.profile?.syncState, ProfileSyncState.pending);
    });
  }

  for (final code in const ['nickname_taken', 'invalid_request']) {
    test('$code persists blocked state and stops automatic retry', () async {
      var calls = 0;
      final store = _MemoryProfileStore()
        ..value = const AppProfile(
          schemaVersion: 1,
          nickname: '本地玩家',
          syncState: ProfileSyncState.pending,
          lastSyncedNickname: '服务器玩家',
        );
      final controller = ProfileController(
        store: store,
        nicknameRules: const _FixtureRules(),
      );
      await controller.load();
      await controller.authenticatedSessionStarted(
        userId: '11111111-1111-4111-8111-111111111111',
        serverNickname: '服务器玩家',
        updateNickname: (_) async {
          calls += 1;
          return ApiError(code: code, message: '安全错误');
        },
      );

      expect(controller.status, ProfileStatus.ready);
      expect(controller.profile?.syncState, ProfileSyncState.blocked);
      expect(controller.profile?.blockingSyncCode, code);
      expect(store.value, controller.profile);
      await controller.handleAppResumed();
      expect(calls, 1);

      await controller.retryPublicSync();
      expect(calls, 2);
    });
  }

  test(
    'transient explicit retry replaces an old blocking classification',
    () async {
      var calls = 0;
      final store = _MemoryProfileStore()
        ..value = const AppProfile(
          schemaVersion: 1,
          nickname: '本地玩家',
          syncState: ProfileSyncState.pending,
          lastSyncedNickname: '服务器玩家',
        );
      final controller = ProfileController(
        store: store,
        nicknameRules: const _FixtureRules(),
      );
      await controller.load();
      await controller.authenticatedSessionStarted(
        userId: '11111111-1111-4111-8111-111111111111',
        serverNickname: '服务器玩家',
        updateNickname: (_) async {
          calls += 1;
          return ApiError(
            code: calls == 1 ? 'nickname_taken' : 'network_error',
            message: '安全错误',
          );
        },
      );
      expect(controller.profile?.syncState, ProfileSyncState.blocked);

      await controller.retryPublicSync();

      expect(controller.profile?.syncState, ProfileSyncState.pending);
      expect(controller.profile?.blockingSyncCode, isNull);
      expect(store.value, controller.profile);
    },
  );

  test(
    'server success remains pending when sync-marker persistence fails',
    () async {
      var calls = 0;
      final store = _MemoryProfileStore()
        ..value = const AppProfile(
          schemaVersion: 1,
          nickname: '本地玩家',
          syncState: ProfileSyncState.pending,
          lastSyncedNickname: '服务器玩家',
        )
        ..failNickname = '本地玩家';
      final controller = ProfileController(
        store: store,
        nicknameRules: const _FixtureRules(),
      );
      await controller.load();
      await controller.authenticatedSessionStarted(
        userId: '11111111-1111-4111-8111-111111111111',
        serverNickname: '服务器玩家',
        updateNickname: (_) async {
          calls += 1;
          return null;
        },
      );

      expect(controller.status, ProfileStatus.ready);
      expect(controller.profile?.syncState, ProfileSyncState.pending);
      expect(
        controller.reconciliationFailure,
        ProfileReconciliationFailure.unavailable,
      );
      store.failNickname = null;
      await controller.retryPublicSync();

      expect(calls, 2);
      expect(controller.profile?.syncState, ProfileSyncState.synced);
      expect(controller.profile?.lastSyncedNickname, '本地玩家');
      expect(controller.reconciliationFailure, isNull);
    },
  );

  test('public nickname mutations are serialized so an older completion cannot win', () async {
    final server = _DelayedPublicNicknameServer(nickname: '服务器玩家');
    final controller = ProfileController(
      store: _MemoryProfileStore(),
      nicknameRules: const _FixtureRules(),
    );
    await controller.load();
    await controller.authenticatedSessionStarted(
      userId: '11111111-1111-4111-8111-111111111111',
      serverNickname: server.nickname,
      updateNickname: server.update,
    );

    await controller.commitNickname('第一版本');
    await server.started('第一版本');
    await controller.commitNickname('第二版本');
    server.complete('第二版本');
    await _drainAsync();
    server.complete('第一版本');
    await _drainAsync();

    expect(server.calls, ['第一版本', '第二版本']);
    expect(server.maximumInFlight, 1);
    expect(server.nickname, '第二版本');
    expect(controller.profile?.nickname, '第二版本');
    expect(controller.profile?.syncState, ProfileSyncState.synced);
    expect(controller.profile?.lastSyncedNickname, '第二版本');
  });

  test('same public account stays serialized across disconnect and reauthentication', () async {
    const userId = '11111111-1111-4111-8111-111111111111';
    final server = _DelayedAccountNicknameServer()..nicknames[userId] = '服务器玩家';
    final controller = ProfileController(
      store: _MemoryProfileStore(),
      nicknameRules: const _FixtureRules(),
    );
    await controller.load();
    await controller.authenticatedSessionStarted(
      userId: userId,
      serverNickname: server.nicknames[userId]!,
      updateNickname: (nickname) => server.update(
        accountId: userId,
        updaterId: 'old-session',
        nickname: nickname,
      ),
    );

    await controller.commitNickname('第一版本');
    await server.started(userId, 'old-session', '第一版本');
    await controller.commitNickname('排队旧版本');
    controller.disconnectPublicSession();
    final reauthenticated = controller.authenticatedSessionStarted(
      userId: userId,
      serverNickname: '服务器玩家',
      updateNickname: (nickname) => server.update(
        accountId: userId,
        updaterId: 'new-session',
        nickname: nickname,
      ),
    );
    await _drainAsync();
    await controller.commitNickname('第二版本');

    // Try to let the new session finish first. A per-account queue must keep
    // it behind the old session's already-issued network mutation.
    server.complete(userId, 'new-session', '第二版本');
    server.complete(userId, 'new-session', '排队旧版本');
    server.complete(userId, 'old-session', '排队旧版本');
    await _drainAsync();
    expect(server.calls, ['old-session:第一版本']);
    server.complete(userId, 'old-session', '第一版本');
    await server.started(userId, 'new-session', '第二版本');
    await reauthenticated;
    await _drainAsync();

    expect(server.calls, ['old-session:第一版本', 'new-session:第二版本']);
    expect(server.maximumInFlightFor(userId), 1);
    expect(server.nicknames[userId], '第二版本');
    expect(controller.profile?.nickname, '第二版本');
    expect(controller.profile?.syncState, ProfileSyncState.synced);
    expect(controller.profile?.lastSyncedNickname, '第二版本');
  });

  test(
    'different public accounts do not share a nickname mutation queue',
    () async {
      const firstUserId = '11111111-1111-4111-8111-111111111111';
      const secondUserId = '22222222-2222-4222-8222-222222222222';
      final server = _DelayedAccountNicknameServer()
        ..nicknames[firstUserId] = '第一账号'
        ..nicknames[secondUserId] = '第二账号';
      final controller = ProfileController(
        store: _MemoryProfileStore(),
        nicknameRules: const _FixtureRules(),
      );
      await controller.load();
      await controller.authenticatedSessionStarted(
        userId: firstUserId,
        serverNickname: server.nicknames[firstUserId]!,
        updateNickname: (nickname) => server.update(
          accountId: firstUserId,
          updaterId: 'first-session',
          nickname: nickname,
        ),
      );

      await controller.commitNickname('本地玩家');
      await server.started(firstUserId, 'first-session', '本地玩家');
      controller.disconnectPublicSession();
      final reauthenticated = controller.authenticatedSessionStarted(
        userId: secondUserId,
        serverNickname: server.nicknames[secondUserId]!,
        updateNickname: (nickname) => server.update(
          accountId: secondUserId,
          updaterId: 'second-session',
          nickname: nickname,
        ),
      );

      await server.started(secondUserId, 'second-session', '本地玩家');
      expect(server.maximumInFlightFor(firstUserId), 1);
      expect(server.maximumInFlightFor(secondUserId), 1);
      server.complete(secondUserId, 'second-session', '本地玩家');
      await reauthenticated;
      server.complete(firstUserId, 'first-session', '本地玩家');
      await _drainAsync();

      expect(controller.profile?.nickname, '本地玩家');
      expect(controller.profile?.syncState, ProfileSyncState.synced);
      expect(controller.profile?.lastSyncedNickname, '本地玩家');
    },
  );

  test(
    'queued nickname intents coalesce to one PATCH of the newest value',
    () async {
      final server = _DelayedPublicNicknameServer(nickname: '服务器玩家');
      final controller = ProfileController(
        store: _MemoryProfileStore(),
        nicknameRules: const _FixtureRules(),
      );
      await controller.load();
      await controller.authenticatedSessionStarted(
        userId: '11111111-1111-4111-8111-111111111111',
        serverNickname: server.nickname,
        updateNickname: server.update,
      );

      await controller.commitNickname('占位版本');
      await server.started('占位版本');
      await controller.commitNickname('第一版本');
      await controller.commitNickname('第二版本');
      server.complete('第一版本');
      server.complete('第二版本');
      server.complete('占位版本');
      await _drainAsync();

      expect(server.calls, ['占位版本', '第二版本']);
      expect(server.maximumInFlight, 1);
      expect(server.nickname, '第二版本');
      expect(controller.profile?.nickname, '第二版本');
      expect(controller.profile?.syncState, ProfileSyncState.synced);
    },
  );

  test(
    'queued newest nickname still runs after the older PATCH fails',
    () async {
      final server = _DelayedPublicNicknameServer(nickname: '服务器玩家')
        ..failures['第一版本'] = const ApiError(
          code: 'network_error',
          message: '暂时失败',
        );
      final controller = ProfileController(
        store: _MemoryProfileStore(),
        nicknameRules: const _FixtureRules(),
      );
      await controller.load();
      await controller.authenticatedSessionStarted(
        userId: '11111111-1111-4111-8111-111111111111',
        serverNickname: server.nickname,
        updateNickname: server.update,
      );

      await controller.commitNickname('第一版本');
      await server.started('第一版本');
      await controller.commitNickname('第二版本');
      server.complete('第一版本');
      await server.started('第二版本');
      server.complete('第二版本');
      await _drainAsync();

      expect(server.calls, ['第一版本', '第二版本']);
      expect(server.maximumInFlight, 1);
      expect(server.nickname, '第二版本');
      expect(controller.profile?.nickname, '第二版本');
      expect(controller.profile?.syncState, ProfileSyncState.synced);
    },
  );

  test(
    'stale blocking failure cannot overwrite a newer successful nickname',
    () async {
      final oldPatch = Completer<ApiError?>();
      final newPatch = Completer<ApiError?>();
      final store = _MemoryProfileStore();
      final controller = ProfileController(
        store: store,
        nicknameRules: const _FixtureRules(),
      );
      await controller.load();
      await controller.authenticatedSessionStarted(
        userId: '11111111-1111-4111-8111-111111111111',
        serverNickname: '服务器玩家',
        updateNickname: (nickname) => nickname == '第一版本'
            ? oldPatch.future
            : nickname == '第二版本'
            ? newPatch.future
            : Future.value(null),
      );

      await controller.commitNickname('第一版本');
      await controller.commitNickname('第二版本');
      newPatch.complete(null);
      await _drainAsync();
      oldPatch.complete(const ApiError(code: 'nickname_taken', message: '已占用'));
      await _drainAsync();

      expect(controller.profile?.nickname, '第二版本');
      expect(controller.profile?.syncState, ProfileSyncState.synced);
      expect(controller.profile?.blockingSyncCode, isNull);
    },
  );

  test('stale success cannot clear a newer pending nickname', () async {
    final oldPatch = Completer<ApiError?>();
    final newPatch = Completer<ApiError?>();
    final store = _MemoryProfileStore();
    final controller = ProfileController(
      store: store,
      nicknameRules: const _FixtureRules(),
    );
    await controller.load();
    await controller.authenticatedSessionStarted(
      userId: '11111111-1111-4111-8111-111111111111',
      serverNickname: '服务器玩家',
      updateNickname: (nickname) => nickname == '第一版本'
          ? oldPatch.future
          : nickname == '第二版本'
          ? newPatch.future
          : Future.value(null),
    );

    await controller.commitNickname('第一版本');
    await controller.commitNickname('第二版本');
    newPatch.complete(const ApiError(code: 'timeout', message: '超时'));
    await _drainAsync();
    oldPatch.complete(null);
    await _drainAsync();

    expect(controller.profile?.nickname, '第二版本');
    expect(controller.profile?.syncState, ProfileSyncState.pending);
    expect(controller.profile?.lastSyncedNickname, '服务器玩家');
  });

  test(
    'completion from a disconnected public user generation is ignored',
    () async {
      final oldPatch = Completer<ApiError?>();
      final store = _MemoryProfileStore();
      final controller = ProfileController(
        store: store,
        nicknameRules: const _FixtureRules(),
      );
      await controller.load();
      await controller.authenticatedSessionStarted(
        userId: '11111111-1111-4111-8111-111111111111',
        serverNickname: '服务器玩家',
        updateNickname: (_) => oldPatch.future,
      );
      await controller.commitNickname('本地玩家');

      controller.disconnectPublicSession();
      await controller.authenticatedSessionStarted(
        userId: '22222222-2222-4222-8222-222222222222',
        serverNickname: '另一个账号',
        updateNickname: (_) async =>
            const ApiError(code: 'network_error', message: '暂时失败'),
      );
      oldPatch.complete(null);
      await _drainAsync();

      expect(controller.profile?.nickname, '本地玩家');
      expect(controller.profile?.syncState, ProfileSyncState.pending);
      expect(controller.profile?.lastSyncedNickname, '另一个账号');
    },
  );

  test('disconnect clears retained server migration intent before local load retry', () async {
    final store = _MemoryProfileStore()
      ..readError = const ProfileLoadFailure.unavailable();
    final controller = ProfileController(
      store: store,
      nicknameRules: const _FixtureRules(),
    );
    await controller.load();
    await controller.authenticatedSessionStarted(
      userId: '11111111-1111-4111-8111-111111111111',
      serverNickname: '旧账号昵称',
      updateNickname: (_) async => null,
    );

    controller.disconnectPublicSession();
    store.readError = null;
    await controller.load();

    expect(controller.status, ProfileStatus.needsNickname);
    expect(controller.profile, isNull);
    expect(store.writes, isEmpty);
  });
}

Future<void> _drainAsync() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

final class _FixtureRules implements NicknameRules {
  const _FixtureRules();

  @override
  Future<String> normalize(String raw) async {
    final normalized = raw.trim();
    if (normalized.runes.length < 2 || normalized.runes.length > 16) {
      throw const NicknameValidationFailure();
    }
    return normalized;
  }
}

final class _MemoryProfileStore implements AppProfileStore {
  AppProfile? value;
  Object? readError;
  String? failNickname;
  Completer<void>? firstWriteBarrier;
  final firstWriteStarted = Completer<void>();
  final writes = <AppProfile>[];

  @override
  Future<AppProfile?> read() async {
    if (readError case final error?) throw error;
    return value;
  }

  @override
  Future<void> write(AppProfile profile) async {
    writes.add(profile);
    if (!firstWriteStarted.isCompleted) firstWriteStarted.complete();
    if (writes.length == 1) await firstWriteBarrier?.future;
    if (profile.nickname == failNickname) throw const ProfileStoreFailure();
    value = profile;
  }
}

final class _DelayedRules implements NicknameRules {
  final _started = <String, Completer<void>>{};
  final _results = <String, Completer<String>>{};

  Future<void> started(String raw) =>
      (_started[raw] ??= Completer<void>()).future;

  void succeed(String raw, String normalized) =>
      (_results[raw] ??= Completer<String>()).complete(normalized);

  void reject(String raw) => (_results[raw] ??= Completer<String>())
      .completeError(const NicknameValidationFailure());

  @override
  Future<String> normalize(String raw) {
    (_started[raw] ??= Completer<void>()).complete();
    return (_results[raw] ??= Completer<String>()).future;
  }
}

final class _DelayedPublicNicknameServer {
  _DelayedPublicNicknameServer({required this.nickname});

  String nickname;
  final failures = <String, ApiError>{};
  final calls = <String>[];
  final _started = <String, Completer<void>>{};
  final _completions = <String, Completer<void>>{};
  var _inFlight = 0;
  var maximumInFlight = 0;

  Future<void> started(String nickname) =>
      (_started[nickname] ??= Completer<void>()).future;

  void complete(String nickname) =>
      (_completions[nickname] ??= Completer<void>()).complete();

  Future<ApiError?> update(String nextNickname) async {
    calls.add(nextNickname);
    _inFlight += 1;
    if (_inFlight > maximumInFlight) maximumInFlight = _inFlight;
    (_started[nextNickname] ??= Completer<void>()).complete();
    await (_completions[nextNickname] ??= Completer<void>()).future;
    final failure = failures[nextNickname];
    if (failure == null) nickname = nextNickname;
    _inFlight -= 1;
    return failure;
  }
}

final class _DelayedAccountNicknameServer {
  final nicknames = <String, String>{};
  final calls = <String>[];
  final _started = <String, Completer<void>>{};
  final _completions = <String, Completer<void>>{};
  final _inFlightByAccount = <String, int>{};
  final _maximumInFlightByAccount = <String, int>{};

  String _requestKey(String accountId, String updaterId, String nickname) =>
      '$accountId|$updaterId|$nickname';

  Future<void> started(String accountId, String updaterId, String nickname) =>
      (_started[_requestKey(accountId, updaterId, nickname)] ??=
              Completer<void>())
          .future;

  void complete(String accountId, String updaterId, String nickname) {
    final completion =
        _completions[_requestKey(accountId, updaterId, nickname)] ??=
            Completer<void>();
    if (!completion.isCompleted) completion.complete();
  }

  int maximumInFlightFor(String accountId) =>
      _maximumInFlightByAccount[accountId] ?? 0;

  Future<ApiError?> update({
    required String accountId,
    required String updaterId,
    required String nickname,
  }) async {
    final requestKey = _requestKey(accountId, updaterId, nickname);
    calls.add('$updaterId:$nickname');
    final inFlight = (_inFlightByAccount[accountId] ?? 0) + 1;
    _inFlightByAccount[accountId] = inFlight;
    final previousMaximum = _maximumInFlightByAccount[accountId] ?? 0;
    if (inFlight > previousMaximum) {
      _maximumInFlightByAccount[accountId] = inFlight;
    }
    (_started[requestKey] ??= Completer<void>()).complete();
    await (_completions[requestKey] ??= Completer<void>()).future;
    nicknames[accountId] = nickname;
    _inFlightByAccount[accountId] = inFlight - 1;
    return null;
  }
}
