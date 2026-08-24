enum ProfileSyncState { synced, pending, blocked }

final class AppProfile {
  const AppProfile({
    required this.schemaVersion,
    required this.nickname,
    required this.syncState,
    this.lastSyncedNickname,
    this.blockingSyncCode,
  });

  static const currentSchemaVersion = 1;

  final int schemaVersion;
  final String nickname;
  final ProfileSyncState syncState;
  final String? lastSyncedNickname;
  final String? blockingSyncCode;

  @override
  bool operator ==(Object other) =>
      other is AppProfile &&
      schemaVersion == other.schemaVersion &&
      nickname == other.nickname &&
      syncState == other.syncState &&
      lastSyncedNickname == other.lastSyncedNickname &&
      blockingSyncCode == other.blockingSyncCode;

  @override
  int get hashCode => Object.hash(
    schemaVersion,
    nickname,
    syncState,
    lastSyncedNickname,
    blockingSyncCode,
  );

  @override
  String toString() =>
      'AppProfile(schemaVersion: $schemaVersion, nickname: $nickname, '
      'syncState: ${syncState.name}, lastSyncedNickname: '
      '$lastSyncedNickname, blockingSyncCode: $blockingSyncCode)';
}
