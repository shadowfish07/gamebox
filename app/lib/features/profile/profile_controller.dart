import 'dart:async';

// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';

import '../../core/profile/app_profile.dart';
import '../../core/profile/app_profile_store.dart';
import '../../core/profile/nickname_rules.dart';

enum ProfileStatus { loading, needsNickname, saving, ready, loadFailure }

enum ProfileCommitFailure { invalidNickname, unavailable }

final class ProfileController extends ChangeNotifier {
  ProfileController({
    required AppProfileStore store,
    required NicknameRules nicknameRules,
  }) : _store = store,
       _nicknameRules = nicknameRules;

  final AppProfileStore _store;
  final NicknameRules _nicknameRules;

  ProfileStatus _status = ProfileStatus.loading;
  AppProfile? _profile;
  ProfileLoadFailure? _loadFailure;
  Future<void> _writeTail = Future<void>.value();
  String? _restoredWhileLoading;
  var _localCommitSerial = 0;
  var _disposed = false;

  ProfileStatus get status => _status;
  AppProfile? get profile => _profile;
  ProfileLoadFailure? get loadFailure => _loadFailure;

  Future<void> load() async {
    if (_disposed) return;
    _setStatus(ProfileStatus.loading);
    try {
      final profile = await _store.read();
      if (_disposed) return;
      _profile = profile;
      _loadFailure = null;
      _setStatus(
        profile == null ? ProfileStatus.needsNickname : ProfileStatus.ready,
      );
      final restored = _restoredWhileLoading;
      _restoredWhileLoading = null;
      if (restored != null) await reconcileRestoredNickname(restored);
    } on ProfileLoadFailure catch (failure) {
      if (_disposed) return;
      _profile = null;
      _loadFailure = failure;
      _restoredWhileLoading = null;
      _setStatus(ProfileStatus.loadFailure);
    }
  }

  Future<ProfileCommitFailure?> commitNickname(String raw) {
    _localCommitSerial += 1;
    return _enqueue(() async {
      if (_disposed ||
          (_status != ProfileStatus.needsNickname &&
              _status != ProfileStatus.ready &&
              _status != ProfileStatus.saving)) {
        return ProfileCommitFailure.unavailable;
      }
      _setStatus(ProfileStatus.saving);
      final String normalized;
      try {
        normalized = await _nicknameRules.normalize(raw);
      } on NicknameValidationFailure {
        _setStatus(
          _profile == null ? ProfileStatus.needsNickname : ProfileStatus.ready,
        );
        return ProfileCommitFailure.invalidNickname;
      } on Object {
        _setStatus(
          _profile == null ? ProfileStatus.needsNickname : ProfileStatus.ready,
        );
        return ProfileCommitFailure.unavailable;
      }
      final current = _profile;
      final sameAsServer = current?.lastSyncedNickname == normalized;
      final next = AppProfile(
        schemaVersion: AppProfile.currentSchemaVersion,
        nickname: normalized,
        syncState: sameAsServer
            ? ProfileSyncState.synced
            : ProfileSyncState.pending,
        lastSyncedNickname: current?.lastSyncedNickname,
      );
      try {
        await _store.write(next);
      } on Object {
        _setStatus(
          _profile == null ? ProfileStatus.needsNickname : ProfileStatus.ready,
        );
        return ProfileCommitFailure.unavailable;
      }
      _profile = next;
      _loadFailure = null;
      _setStatus(ProfileStatus.ready);
      return null;
    });
  }

  Future<void> reconcileRestoredNickname(String serverNickname) async {
    if (_disposed || _status == ProfileStatus.loadFailure) return;
    if (_status == ProfileStatus.loading) {
      _restoredWhileLoading = serverNickname;
      return;
    }
    final commitSerialAtCall = _localCommitSerial;
    await _enqueue(() async {
      if (_disposed || _status == ProfileStatus.loadFailure) return;
      final String normalizedServer;
      try {
        normalizedServer = await _nicknameRules.normalize(serverNickname);
      } on Object {
        return;
      }
      final current = _profile;
      late final AppProfile next;
      if (current == null && _localCommitSerial == commitSerialAtCall) {
        next = AppProfile(
          schemaVersion: AppProfile.currentSchemaVersion,
          nickname: normalizedServer,
          syncState: ProfileSyncState.synced,
          lastSyncedNickname: normalizedServer,
        );
      } else if (current == null) {
        return;
      } else if (current.nickname == normalizedServer) {
        next = AppProfile(
          schemaVersion: AppProfile.currentSchemaVersion,
          nickname: current.nickname,
          syncState: ProfileSyncState.synced,
          lastSyncedNickname: normalizedServer,
        );
      } else {
        next = AppProfile(
          schemaVersion: AppProfile.currentSchemaVersion,
          nickname: current.nickname,
          syncState: current.syncState == ProfileSyncState.blocked
              ? ProfileSyncState.blocked
              : ProfileSyncState.pending,
          lastSyncedNickname: normalizedServer,
          blockingSyncCode: current.syncState == ProfileSyncState.blocked
              ? current.blockingSyncCode
              : null,
        );
      }
      if (next == current) return;
      try {
        await _store.write(next);
      } on Object {
        return;
      }
      _profile = next;
      _loadFailure = null;
      _setStatus(ProfileStatus.ready);
    });
  }

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _writeTail = _writeTail.then((_) async {
      try {
        completer.complete(await operation());
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  void _setStatus(ProfileStatus value) {
    _status = value;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
