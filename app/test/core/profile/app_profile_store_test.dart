import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/core/profile/app_profile.dart';
import 'package:gamebox/core/profile/app_profile_store.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('gamebox-profile-test.');
  });

  tearDown(() async {
    if (directory.existsSync()) await directory.delete(recursive: true);
  });

  test('missing profile is the only absent-profile result', () async {
    final store = LocalAppProfileStore(supportDirectory: () async => directory);

    expect(await store.read(), isNull);
  });

  test('write flushes and atomically publishes one strict profile', () async {
    final store = LocalAppProfileStore(supportDirectory: () async => directory);
    const profile = AppProfile(
      schemaVersion: 1,
      nickname: '小鱼',
      syncState: ProfileSyncState.pending,
    );

    await store.write(profile);

    expect(await store.read(), profile);
    final files = directory.listSync().whereType<File>().toList();
    expect(files.map((file) => file.path), [
      '${directory.path}/gamebox-profile.json',
    ]);
    final json = jsonDecode(files.single.readAsStringSync()) as Map;
    expect(json, <String, Object?>{
      'schemaVersion': 1,
      'nickname': '小鱼',
      'syncState': 'pending',
      'lastSyncedNickname': null,
      'blockingSyncCode': null,
    });
  });

  test(
    'failed atomic replace preserves the previously committed bytes',
    () async {
      final initial = LocalAppProfileStore(
        supportDirectory: () async => directory,
      );
      const oldProfile = AppProfile(
        schemaVersion: 1,
        nickname: '旧昵称',
        syncState: ProfileSyncState.synced,
        lastSyncedNickname: '旧昵称',
      );
      await initial.write(oldProfile);
      final profileFile = File('${directory.path}/gamebox-profile.json');
      final oldBytes = await profileFile.readAsBytes();
      final failing = LocalAppProfileStore(
        supportDirectory: () async => directory,
        replaceFile: (_, _) async =>
            throw const FileSystemException('disk full'),
      );

      await expectLater(
        failing.write(
          const AppProfile(
            schemaVersion: 1,
            nickname: '新昵称',
            syncState: ProfileSyncState.pending,
          ),
        ),
        throwsA(isA<ProfileStoreFailure>()),
      );

      expect(await profileFile.readAsBytes(), oldBytes);
      expect(directory.listSync().whereType<File>(), hasLength(1));
    },
  );

  test(
    'oversized UTF-8 payload is rejected before file access or publication',
    () async {
      final initial = LocalAppProfileStore(
        supportDirectory: () async => directory,
      );
      await initial.write(
        const AppProfile(
          schemaVersion: 1,
          nickname: '已提交',
          syncState: ProfileSyncState.pending,
        ),
      );
      final profileFile = File('${directory.path}/gamebox-profile.json');
      final committedBytes = await profileFile.readAsBytes();
      var supportDirectoryCalls = 0;
      final store = LocalAppProfileStore(
        supportDirectory: () async {
          supportDirectoryCalls += 1;
          return directory;
        },
      );

      await expectLater(
        store.write(
          AppProfile(
            schemaVersion: 1,
            nickname: List.filled(22000, '界').join(),
            syncState: ProfileSyncState.pending,
          ),
        ),
        throwsA(isA<ProfileStoreFailure>()),
      );

      expect(supportDirectoryCalls, 0);
      expect(await profileFile.readAsBytes(), committedBytes);
      expect(directory.listSync().whereType<File>(), hasLength(1));
    },
  );

  test(
    'corrupt profile is recoverable failure and bytes stay quarantined',
    () async {
      final profileFile = File('${directory.path}/gamebox-profile.json');
      final corrupt = utf8.encode('{"schemaVersion":1,"nickname":"secret"');
      await profileFile.writeAsBytes(corrupt, flush: true);
      final store = LocalAppProfileStore(
        supportDirectory: () async => directory,
      );

      await expectLater(
        store.read(),
        throwsA(
          isA<ProfileLoadFailure>().having(
            (failure) => failure.toString(),
            'safe diagnostic',
            isNot(contains('secret')),
          ),
        ),
      );

      expect(await profileFile.readAsBytes(), corrupt);
    },
  );

  test(
    'version zero profile upgrades offline through the atomic path',
    () async {
      final profileFile = File('${directory.path}/gamebox-profile.json');
      await profileFile.writeAsString(
        '{"schemaVersion":0,"nickname":"旧玩家"}',
        flush: true,
      );
      final store = LocalAppProfileStore(
        supportDirectory: () async => directory,
      );

      final profile = await store.read();

      expect(
        profile,
        const AppProfile(
          schemaVersion: 1,
          nickname: '旧玩家',
          syncState: ProfileSyncState.pending,
        ),
      );
      expect(
        jsonDecode(await profileFile.readAsString()),
        containsPair('schemaVersion', 1),
      );
    },
  );

  test(
    'unknown schema and duplicate fields are corrupt, never absent',
    () async {
      final store = LocalAppProfileStore(
        supportDirectory: () async => directory,
      );
      final profileFile = File('${directory.path}/gamebox-profile.json');
      for (final bytes in [
        '{"schemaVersion":2,"nickname":"玩家"}',
        '{"schemaVersion":0,"nickname":"玩家","nickname":"覆盖"}',
      ]) {
        await profileFile.writeAsString(bytes, flush: true);
        await expectLater(store.read(), throwsA(isA<ProfileLoadFailure>()));
        expect(await profileFile.readAsString(), bytes);
      }
    },
  );

  test('failed version zero rewrite preserves the legacy bytes', () async {
    final profileFile = File('${directory.path}/gamebox-profile.json');
    const legacy = '{"schemaVersion":0,"nickname":"旧玩家"}';
    await profileFile.writeAsString(legacy, flush: true);
    final store = LocalAppProfileStore(
      supportDirectory: () async => directory,
      replaceFile: (_, _) async => throw const FileSystemException('disk full'),
    );

    await expectLater(
      store.read(),
      throwsA(
        isA<ProfileLoadFailure>().having(
          (failure) => failure.kind,
          'kind',
          ProfileLoadFailureKind.unavailable,
        ),
      ),
    );

    expect(await profileFile.readAsString(), legacy);
  });

  test(
    'blocked forward state round-trips without triggering sync work',
    () async {
      final store = LocalAppProfileStore(
        supportDirectory: () async => directory,
      );
      const blocked = AppProfile(
        schemaVersion: 1,
        nickname: '本地玩家',
        syncState: ProfileSyncState.blocked,
        lastSyncedNickname: '旧公服昵称',
        blockingSyncCode: 'nickname_taken',
      );

      await store.write(blocked);

      expect(await store.read(), blocked);
    },
  );
}
