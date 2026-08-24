import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../api/strict_json.dart';
import 'app_profile.dart';

abstract interface class AppProfileStore {
  Future<AppProfile?> read();

  Future<void> write(AppProfile profile);
}

final class ProfileLoadFailure implements Exception {
  const ProfileLoadFailure.corrupt() : kind = ProfileLoadFailureKind.corrupt;

  const ProfileLoadFailure.unavailable()
    : kind = ProfileLoadFailureKind.unavailable;

  final ProfileLoadFailureKind kind;

  @override
  String toString() => 'ProfileLoadFailure(${kind.name})';
}

enum ProfileLoadFailureKind { corrupt, unavailable }

final class ProfileStoreFailure implements Exception {
  const ProfileStoreFailure();

  @override
  String toString() => 'ProfileStoreFailure(unavailable)';
}

typedef SupportDirectoryProvider = Future<Directory> Function();
typedef ReplaceProfileFile = Future<void> Function(File source, String target);

final class LocalAppProfileStore implements AppProfileStore {
  LocalAppProfileStore({
    SupportDirectoryProvider? supportDirectory,
    ReplaceProfileFile? replaceFile,
  }) : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
       _replaceFile = replaceFile ?? _rename;

  static const _profileFilename = 'gamebox-profile.json';
  static const _maximumProfileBytes = 64 * 1024;
  static var _temporarySequence = 0;

  final SupportDirectoryProvider _supportDirectory;
  final ReplaceProfileFile _replaceFile;

  @override
  Future<AppProfile?> read() async {
    final File profileFile;
    try {
      profileFile = await _resolveProfileFile();
      if (!await profileFile.exists()) return null;
      final length = await profileFile.length();
      if (length <= 0 || length > _maximumProfileBytes) {
        throw const ProfileLoadFailure.corrupt();
      }
      final bytes = await profileFile.readAsBytes();
      final object = decodeStrictJsonObject(Uint8List.fromList(bytes));
      final version = object['schemaVersion'];
      if (version == 0) {
        final upgraded = _decodeVersionZero(object);
        try {
          await write(upgraded);
        } on ProfileStoreFailure {
          throw const ProfileLoadFailure.unavailable();
        }
        return upgraded;
      }
      if (version != AppProfile.currentSchemaVersion) {
        throw const FormatException('Unsupported profile schema');
      }
      return _decodeVersionOne(object);
    } on ProfileLoadFailure {
      rethrow;
    } on FileSystemException {
      throw const ProfileLoadFailure.unavailable();
    } on FormatException {
      throw const ProfileLoadFailure.corrupt();
    } on Object {
      throw const ProfileLoadFailure.unavailable();
    }
  }

  @override
  Future<void> write(AppProfile profile) async {
    if (!_isValidProfile(profile)) throw ArgumentError('Invalid app profile');
    File? temporary;
    RandomAccessFile? output;
    try {
      final destination = await _resolveProfileFile(createParent: true);
      final sequence = _temporarySequence++;
      temporary = File(
        '${destination.parent.path}/.$_profileFilename.'
        '${DateTime.now().microsecondsSinceEpoch}.$sequence.tmp',
      );
      final bytes = utf8.encode(
        jsonEncode(<String, Object?>{
          'schemaVersion': profile.schemaVersion,
          'nickname': profile.nickname,
          'syncState': profile.syncState.name,
          'lastSyncedNickname': profile.lastSyncedNickname,
          'blockingSyncCode': profile.blockingSyncCode,
        }),
      );
      final opened = await temporary.open(mode: FileMode.write);
      output = opened;
      await opened.writeFrom(bytes);
      await opened.flush();
      await opened.close();
      output = null;
      await _replaceFile(temporary, destination.path);
      temporary = null;
    } on Object {
      throw const ProfileStoreFailure();
    } finally {
      try {
        await output?.close();
      } on Object {
        // The original safe storage failure remains authoritative.
      }
      try {
        if (temporary != null && await temporary.exists()) {
          await temporary.delete();
        }
      } on Object {
        // A stale hidden temp file is not a committed profile.
      }
    }
  }

  Future<File> _resolveProfileFile({bool createParent = false}) async {
    final directory = await _supportDirectory();
    if (createParent) await directory.create(recursive: true);
    return File('${directory.path}/$_profileFilename');
  }

  static Future<void> _rename(File source, String target) async {
    await source.rename(target);
  }

  static AppProfile _decodeVersionZero(Map<String, Object?> object) {
    if (!hasExactJsonKeys(object, const {'schemaVersion', 'nickname'}) ||
        object['nickname'] is! String ||
        (object['nickname']! as String).isEmpty) {
      throw const FormatException('Invalid legacy profile');
    }
    return AppProfile(
      schemaVersion: AppProfile.currentSchemaVersion,
      nickname: object['nickname']! as String,
      syncState: ProfileSyncState.pending,
    );
  }

  static AppProfile _decodeVersionOne(Map<String, Object?> object) {
    if (!hasExactJsonKeys(object, const {
      'schemaVersion',
      'nickname',
      'syncState',
      'lastSyncedNickname',
      'blockingSyncCode',
    })) {
      throw const FormatException('Invalid profile fields');
    }
    final nickname = object['nickname'];
    final syncName = object['syncState'];
    final lastSyncedNickname = object['lastSyncedNickname'];
    final blockingSyncCode = object['blockingSyncCode'];
    if (nickname is! String ||
        syncName is! String ||
        lastSyncedNickname is! String? ||
        blockingSyncCode is! String?) {
      throw const FormatException('Invalid profile field types');
    }
    final syncState = ProfileSyncState.values
        .where((state) => state.name == syncName)
        .firstOrNull;
    if (syncState == null) throw const FormatException('Invalid sync state');
    final profile = AppProfile(
      schemaVersion: AppProfile.currentSchemaVersion,
      nickname: nickname,
      syncState: syncState,
      lastSyncedNickname: lastSyncedNickname,
      blockingSyncCode: blockingSyncCode,
    );
    if (!_isValidProfile(profile)) {
      throw const FormatException('Invalid profile invariants');
    }
    return profile;
  }

  static bool _isValidProfile(AppProfile profile) {
    if (profile.schemaVersion != AppProfile.currentSchemaVersion ||
        profile.nickname.isEmpty ||
        profile.nickname.length > _maximumProfileBytes) {
      return false;
    }
    return switch (profile.syncState) {
      ProfileSyncState.synced =>
        profile.lastSyncedNickname == profile.nickname &&
            profile.blockingSyncCode == null,
      ProfileSyncState.pending => profile.blockingSyncCode == null,
      ProfileSyncState.blocked =>
        profile.blockingSyncCode != null &&
            profile.blockingSyncCode!.isNotEmpty &&
            profile.blockingSyncCode!.length <= 64,
    };
  }
}
