import 'dart:async';

// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';

import '../../core/api/api_error.dart';
import '../../core/profile/app_profile.dart';
import '../../core/profile/app_profile_store.dart';
import '../../core/profile/nickname_rules.dart';

enum ProfileStatus { loading, needsNickname, saving, ready, loadFailure }

enum ProfileCommitFailure { invalidNickname, unavailable }

enum ProfileReconciliationFailure { unavailable }

typedef PublicNicknameUpdater = Future<ApiError?> Function(String nickname);

final class ProfileController extends ChangeNotifier {
  ProfileController({
    required AppProfileStore store,
    required NicknameRules nicknameRules,
    DateTime Function()? now,
  }) : _store = store,
       _nicknameRules = nicknameRules,
       _now = now ?? DateTime.now;

  static const _automaticRetryCooldown = Duration(minutes: 5);

  final AppProfileStore _store;
  final NicknameRules _nicknameRules;
  final DateTime Function() _now;

  ProfileStatus _status = ProfileStatus.loading;
  AppProfile? _profile;
  ProfileLoadFailure? _loadFailure;
  ProfileReconciliationFailure? _reconciliationFailure;
  Future<void> _writeTail = Future<void>.value();
  String? _restoredServerNickname;
  String? _publicUserId;
  String? _lastObservedServerNickname;
  PublicNicknameUpdater? _updatePublicNickname;
  String? _lastAutomaticNickname;
  DateTime? _lastAutomaticAttemptAt;
  var _profileIntentGeneration = 0;
  var _publicSessionGeneration = 0;
  final Set<(int, int)> _activeSyncAttempts = {};
  var _disposed = false;

  ProfileStatus get status => _status;
  AppProfile? get profile => _profile;
  ProfileLoadFailure? get loadFailure => _loadFailure;
  ProfileReconciliationFailure? get reconciliationFailure =>
      _reconciliationFailure;

  Future<void> load() async {
    if (_disposed) return;
    _setStatus(ProfileStatus.loading);
    try {
      final profile = await _store.read();
      if (_disposed) return;
      _profile = profile;
      _profileIntentGeneration += 1;
      _loadFailure = null;
      _setStatus(
        profile == null ? ProfileStatus.needsNickname : ProfileStatus.ready,
      );
      await retryReconciliation();
      await _attemptPublicSync(automatic: true);
    } on ProfileLoadFailure catch (failure) {
      if (_disposed) return;
      _profile = null;
      _loadFailure = failure;
      _setStatus(ProfileStatus.loadFailure);
    }
  }

  Future<ProfileCommitFailure?> commitNickname(String raw) async {
    final result = await _enqueue(() async {
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
      _profileIntentGeneration += 1;
      _loadFailure = null;
      _setStatus(ProfileStatus.ready);
      return null;
    });
    if (result == null) {
      unawaited(_attemptPublicSync(automatic: true));
    }
    return result;
  }

  Future<void> authenticatedSessionStarted({
    required String userId,
    required String serverNickname,
    required PublicNicknameUpdater updateNickname,
  }) async {
    if (_disposed || userId.isEmpty) return;
    final newUser = userId != _publicUserId;
    _publicUserId = userId;
    _updatePublicNickname = updateNickname;
    if (newUser) {
      _publicSessionGeneration += 1;
      _lastAutomaticNickname = null;
      _lastAutomaticAttemptAt = null;
    }
    final serverNicknameChanged = serverNickname != _lastObservedServerNickname;
    _lastObservedServerNickname = serverNickname;
    if (newUser || serverNicknameChanged) {
      await reconcileRestoredNickname(serverNickname);
    }
    if (newUser) {
      await _attemptPublicSync(automatic: true);
    }
  }

  void disconnectPublicSession() {
    if (_publicUserId == null && _updatePublicNickname == null) return;
    _publicSessionGeneration += 1;
    _publicUserId = null;
    _lastObservedServerNickname = null;
    _restoredServerNickname = null;
    _updatePublicNickname = null;
    _lastAutomaticNickname = null;
    _lastAutomaticAttemptAt = null;
  }

  Future<void> handleAppResumed() async {
    await retryReconciliation();
    await _attemptPublicSync(automatic: true);
  }

  Future<void> retryPublicSync() => _attemptPublicSync(automatic: false);

  Future<void> reconcileRestoredNickname(String serverNickname) async {
    if (_disposed) return;
    _restoredServerNickname = serverNickname;
    await retryReconciliation();
  }

  Future<void> retryReconciliation() async {
    if (_disposed ||
        _restoredServerNickname == null ||
        _status == ProfileStatus.loading ||
        _status == ProfileStatus.loadFailure) {
      return;
    }
    await _enqueue(() async {
      if (_disposed || _status == ProfileStatus.loadFailure) return;
      final serverNickname = _restoredServerNickname;
      if (serverNickname == null) return;
      final String normalizedServer;
      try {
        normalizedServer = await _nicknameRules.normalize(serverNickname);
      } on Object {
        _surfaceReconciliationFailure();
        return;
      }
      final current = _profile;
      late final AppProfile next;
      if (current == null) {
        next = AppProfile(
          schemaVersion: AppProfile.currentSchemaVersion,
          nickname: normalizedServer,
          syncState: ProfileSyncState.synced,
          lastSyncedNickname: normalizedServer,
        );
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
      if (next == current) {
        _clearReconciliationFailure();
        return;
      }
      try {
        await _store.write(next);
      } on Object {
        _surfaceReconciliationFailure();
        return;
      }
      _profile = next;
      if (next.nickname != current?.nickname) {
        _profileIntentGeneration += 1;
      }
      _loadFailure = null;
      _reconciliationFailure = null;
      _setStatus(ProfileStatus.ready);
    });
  }

  void _surfaceReconciliationFailure() {
    _reconciliationFailure = ProfileReconciliationFailure.unavailable;
    if (_profile == null) {
      _loadFailure = const ProfileLoadFailure.unavailable();
      _setStatus(ProfileStatus.loadFailure);
    } else {
      _setStatus(ProfileStatus.ready);
    }
  }

  void _clearReconciliationFailure() {
    if (_reconciliationFailure == null) return;
    _reconciliationFailure = null;
    _loadFailure = null;
    _setStatus(
      _profile == null ? ProfileStatus.needsNickname : ProfileStatus.ready,
    );
  }

  Future<void> _attemptPublicSync({required bool automatic}) async {
    if (_disposed ||
        _status == ProfileStatus.loading ||
        _status == ProfileStatus.loadFailure) {
      return;
    }
    final current = _profile;
    final updater = _updatePublicNickname;
    final publicUserId = _publicUserId;
    if (current == null ||
        updater == null ||
        publicUserId == null ||
        automatic && current.syncState != ProfileSyncState.pending ||
        !automatic && current.syncState == ProfileSyncState.synced) {
      return;
    }
    final now = _now();
    final lastAutomaticAttemptAt = _lastAutomaticAttemptAt;
    if (automatic &&
        _lastAutomaticNickname == current.nickname &&
        lastAutomaticAttemptAt != null &&
        now.difference(lastAutomaticAttemptAt) < _automaticRetryCooldown) {
      return;
    }
    final intentGeneration = _profileIntentGeneration;
    final sessionGeneration = _publicSessionGeneration;
    final attemptKey = (sessionGeneration, intentGeneration);
    if (!_activeSyncAttempts.add(attemptKey)) return;
    if (automatic) {
      _lastAutomaticNickname = current.nickname;
      _lastAutomaticAttemptAt = now;
    }
    ApiError? failure;
    try {
      failure = await updater(current.nickname);
    } on ApiError catch (error) {
      failure = error;
    } on Object {
      failure = const ApiError(code: 'internal_error', message: '昵称同步失败，请稍后重试');
    } finally {
      _activeSyncAttempts.remove(attemptKey);
    }
    if (!_isCurrentSync(
      intentGeneration,
      sessionGeneration,
      publicUserId,
      current.nickname,
    )) {
      return;
    }
    final blockingFailure =
        failure != null &&
        (failure.code == 'nickname_taken' || failure.code == 'invalid_request');
    if (failure != null &&
        !blockingFailure &&
        current.syncState != ProfileSyncState.blocked) {
      return;
    }
    await _enqueue(() async {
      if (!_isCurrentSync(
        intentGeneration,
        sessionGeneration,
        publicUserId,
        current.nickname,
      )) {
        return;
      }
      final next = failure == null
          ? AppProfile(
              schemaVersion: AppProfile.currentSchemaVersion,
              nickname: current.nickname,
              syncState: ProfileSyncState.synced,
              lastSyncedNickname: current.nickname,
            )
          : blockingFailure
          ? AppProfile(
              schemaVersion: AppProfile.currentSchemaVersion,
              nickname: current.nickname,
              syncState: ProfileSyncState.blocked,
              lastSyncedNickname: current.lastSyncedNickname,
              blockingSyncCode: failure.code,
            )
          : AppProfile(
              schemaVersion: AppProfile.currentSchemaVersion,
              nickname: current.nickname,
              syncState: ProfileSyncState.pending,
              lastSyncedNickname: current.lastSyncedNickname,
            );
      try {
        await _store.write(next);
      } on Object {
        _surfaceReconciliationFailure();
        return;
      }
      if (!_isCurrentSync(
        intentGeneration,
        sessionGeneration,
        publicUserId,
        current.nickname,
      )) {
        try {
          final profile = _profile;
          if (profile != null) await _store.write(profile);
        } on Object {
          _surfaceReconciliationFailure();
        }
        return;
      }
      _profile = next;
      _reconciliationFailure = null;
      _loadFailure = null;
      _setStatus(ProfileStatus.ready);
    });
  }

  bool _isCurrentSync(
    int intentGeneration,
    int sessionGeneration,
    String publicUserId,
    String nickname,
  ) {
    return !_disposed &&
        intentGeneration == _profileIntentGeneration &&
        sessionGeneration == _publicSessionGeneration &&
        publicUserId == _publicUserId &&
        nickname == _profile?.nickname;
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
    _profileIntentGeneration += 1;
    _publicSessionGeneration += 1;
    _publicUserId = null;
    _updatePublicNickname = null;
    _activeSyncAttempts.clear();
    super.dispose();
  }
}
