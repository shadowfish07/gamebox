// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';

import '../../core/lan/lan_api.dart';
import '../../core/lan/lan_credential_store.dart';
import '../../core/lan/lan_models.dart';
import '../../core/platform/game_results_platform.dart';
import 'game_history_store.dart';

typedef PublicResultFetcher = Future<AuthoritativeGameResult> Function(
  String matchId,
);

final class GameHistoryController extends ChangeNotifier {
  GameHistoryController({
    required GameResultsPlatform platform,
    required GameHistoryStore store,
    required LanApi lanApi,
    required LanCredentialStore credentials,
    PublicResultFetcher? fetchPublicResult,
    String? publicUserId,
  }) : _platform = platform,
       _store = store,
       _lanApi = lanApi,
       _credentials = credentials,
       _fetchPublicResult = fetchPublicResult,
       _publicUserId = publicUserId;

  final GameResultsPlatform _platform;
  final GameHistoryStore _store;
  final LanApi _lanApi;
  final LanCredentialStore _credentials;
  PublicResultFetcher? _fetchPublicResult;
  String? _publicUserId;
  bool _disposed = false;

  List<GameHistoryRecord> results = const [];
  List<PendingGameResultRecord> pending = const [];
  bool loading = false;
  String? errorCode;

  set fetchPublicResult(PublicResultFetcher? value) =>
      _fetchPublicResult = value;

  set publicUserId(String? value) => _publicUserId = value;

  Future<void> refresh() async {
    if (loading) return;
    loading = true;
    errorCode = null;
    _notifyListeners();
    try {
      pending = await _platform.listPending();
      final committed = await _platform.listCommitted();
      var recoveryFailed = false;
      for (final item in List<PendingGameResultRecord>.from(pending)) {
        final local = committed.where(
          (entry) => entry.result.matchId == item.matchId,
        );
        try {
          await _recover(item, local.firstOrNull);
        } on Object {
          recoveryFailed = true;
        }
      }
      pending = await _platform.listPending();
      results = await _store.load();
      if (recoveryFailed) errorCode = 'recovery_failed';
      if (_store.lastCorruptCount > 0) errorCode = 'history_corrupt';
    } on Object {
      errorCode = 'history_unavailable';
    } finally {
      loading = false;
      _notifyListeners();
    }
  }

  Future<void> retry(PendingGameResultRecord item) async {
    if (loading) return;
    loading = true;
    errorCode = null;
    _notifyListeners();
    try {
      final committed = await _platform.listCommitted();
      await _recover(
        item,
        committed
            .where((entry) => entry.result.matchId == item.matchId)
            .firstOrNull,
      );
      pending = await _platform.listPending();
      results = await _store.load();
    } on Object {
      errorCode = 'recovery_failed';
    } finally {
      loading = false;
      _notifyListeners();
    }
  }

  Future<void> _recover(
    PendingGameResultRecord item,
    CommittedGameResult? committed,
  ) async {
    var phase = 'initialize';
    try {
      await _recoverTracked(item, committed, (value) => phase = value);
    } on Object catch (error) {
      debugPrint(
        'GAMEBOX_HISTORY_RECOVERY match=${item.matchId} '
        'source=${item.source} phase=$phase error=${error.runtimeType}',
      );
      rethrow;
    }
  }

  Future<void> _recoverTracked(
    PendingGameResultRecord item,
    CommittedGameResult? committed,
    void Function(String value) setPhase,
  ) async {
    late final AuthoritativeGameResult result;
    late final String persistedSha256;
    late final String localUserId;
    LanCredential? credential;
    String? lanAckHash;

    if (item.source == 'public') {
      setPhase('public-session');
      localUserId =
          _publicUserId ?? (throw StateError('public_session_unavailable'));
      if (committed == null) {
        setPhase('public-fetch');
        final fetch = _fetchPublicResult;
        if (fetch == null) throw StateError('public_session_unavailable');
        result = await fetch(item.matchId);
        persistedSha256 = await _platform.persistRecovered(result);
      } else {
        result = committed.result;
        persistedSha256 = committed.sha256;
      }
    } else if (item.source == 'lan') {
      setPhase('lan-credential');
      credential = await _credentials.readCredential(item.matchId);
      setPhase('lan-identity');
      localUserId =
          item.localUserId ??
          credential?.playerId ??
          (throw StateError('lan_identity_unavailable'));
      if (credential == null) {
        setPhase('lan-committed');
        if (committed == null) throw StateError('lan_result_unavailable');
        result = committed.result;
        persistedSha256 = committed.sha256;
      } else {
        setPhase('lan-fetch');
        final fetched = await _lanApi.fetchResult(
          credential.endpoint,
          credential,
        );
        lanAckHash = fetched.resultHash;
        if (committed == null) {
          result = fetched.result;
          persistedSha256 = await _platform.persistRecovered(result);
        } else {
          result = committed.result;
          persistedSha256 = committed.sha256;
          if (result.encode() != fetched.result.encode()) {
            throw const FormatException('result_conflict');
          }
        }
      }
    } else {
      throw const FormatException('invalid_source');
    }

    setPhase('validate');
    if (result.matchId != item.matchId ||
        !result.players.any((player) => player.userId == localUserId)) {
      throw const FormatException('result_mismatch');
    }
    setPhase('import');
    await _store.import(
      GameHistoryRecord(
        authoritative: result,
        source: item.source == 'lan'
            ? GameResultSource.lan
            : GameResultSource.public,
        localUserId: localUserId,
      ),
    );
    if (credential != null && lanAckHash != null) {
      setPhase('acknowledge');
      await _lanApi.acknowledgeResult(
        credential.endpoint,
        credential,
        lanAckHash,
      );
      setPhase('credential-delete');
      await _credentials.delete(item.matchId);
    }
    setPhase('complete-pending');
    await _platform.completePending(item.matchId, persistedSha256);
  }

  void _notifyListeners() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
