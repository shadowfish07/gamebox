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
