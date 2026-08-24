import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
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
