// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';

import '../../core/lan/lan_api.dart';
import '../../core/lan/lan_credential_store.dart';
import '../../core/lan/lan_models.dart';
import '../../core/lan/lan_qr_payload.dart';
import '../../core/platform/game_launch_request.dart';
import '../../core/platform/game_launcher.dart';
import '../../core/platform/lan_host_platform.dart';

sealed class LanRoomState {
  const LanRoomState();
}

final class LanIdle extends LanRoomState {
  const LanIdle();
}

final class LanCreating extends LanRoomState {
  const LanCreating();
}

final class LanWaitingForGuest extends LanRoomState {
  const LanWaitingForGuest({
    required this.roomId,
    required this.qr,
    this.errorCode,
  });
  final String roomId;
  final LanJoinQr? qr;
  final String? errorCode;
}

final class LanJoining extends LanRoomState {
  const LanJoining();
}

final class LanReady extends LanRoomState {
  const LanReady(this.receipt);
  final LanLaunchReceipt receipt;
}

final class LanActive extends LanRoomState {
  const LanActive({
    required this.roomId,
    required this.revision,
    required this.role,
  });
  final String roomId;
  final int revision;
  final String role;
}

final class LanEndpointChanged extends LanRoomState {
  const LanEndpointChanged(this.qr);
  final LanResumeQr qr;
}

final class LanRecoveryCorrupt extends LanRoomState {
  const LanRecoveryCorrupt(this.roomId);
  final String roomId;
}

final class LanFinishedAwaitingAck extends LanRoomState {
  const LanFinishedAwaitingAck(this.roomId);
  final String roomId;
}

final class LanRoomFailure extends LanRoomState {
  const LanRoomFailure(this.code);
  final String code;
}

final class LanRoomController extends ChangeNotifier {
  LanRoomController({
    required LanHostPlatform host,
    required LanApi api,
    required LanCredentialStore credentialStore,
    required GameLauncher gameLauncher,
    DateTime Function()? now,
  }) : _host = host,
       _api = api,
       _credentialStore = credentialStore,
       _gameLauncher = gameLauncher,
       _now = now ?? DateTime.now;

  final LanHostPlatform _host;
  final LanApi _api;
  final LanCredentialStore _credentialStore;
  final GameLauncher _gameLauncher;
  final DateTime Function() _now;
  LanRoomState _state = const LanIdle();
  LanRoomState get state => _state;
  bool _busy = false;
  bool get isBusy => _busy;
  LanHostCreation? _hostCreation;
  bool _disposed = false;

  Future<void> initialize() => refreshHostStatus();
  Future<void> handleAppResumed() => refreshHostStatus();

  Future<void> refreshHostStatus() async {
    try {
      _applyHostStatus(await _host.getStatus());
    } on LanHostException catch (error) {
      _set(LanRoomFailure(error.code));
    }
  }

  Future<void> createHost(String nickname) async {
    if (_busy) return;
    _busy = true;
    _set(const LanCreating());
    try {
      final creation = await _host.createRoom(nickname);
      _hostCreation = creation;
      _showWaiting(creation);
    } on LanHostException catch (error) {
      _set(LanRoomFailure(error.code));
    } finally {
      _busy = false;
      _notifyListeners();
    }
  }

  Future<void> refreshEndpoint() async {
    try {
      final status = await _host.refreshEndpoint();
      final creation = _hostCreation;
      if (creation != null && status.state == LanNativeState.waiting) {
        _hostCreation = LanHostCreation(
          status: status,
          roomKey: creation.roomKey,
          joinExpiresAt: creation.joinExpiresAt,
        );
        _showWaiting(_hostCreation!);
      } else {
        _applyHostStatus(status);
      }
    } on LanHostException catch (error) {
      _set(LanRoomFailure(error.code));
    }
  }

  Future<void> joinRaw(String raw, String nickname) async {
    if (_busy) return;
    _busy = true;
    _set(const LanJoining());
    try {
      final payload = LanQrPayload.parse(raw, _now());
      if (payload is LanJoinQr) {
        var candidate = await _credentialStore.readCandidate(payload.roomId);
        candidate ??= await _credentialStore.createCandidate(
          payload.roomId,
          payload.endpoint,
        );
        final receipt = await _api.join(payload, candidate, nickname);
        await _credentialStore.commit(candidate, receipt.playerId);
        await _launchGuest(receipt, payload.endpoint);
      } else if (payload is LanResumeQr) {
        final credential = await _credentialStore.readCredential(
          payload.roomId,
        );
        if (credential == null) throw const LanException('credential_missing');
        final receipt = await _api.resumeTicket(payload, credential);
        await _credentialStore.updateEndpoint(credential, payload.endpoint);
        await _launchGuest(receipt, payload.endpoint);
      }
    } on LanException catch (error) {
      if (error.authoritative && error.code != 'match_not_finished') {
        final payload = _safeRoomId(raw);
        if (payload != null) await _credentialStore.delete(payload);
      }
      _set(LanRoomFailure(error.code));
    } on Object {
      _set(const LanRoomFailure('storage_unavailable'));
    } finally {
      _busy = false;
      _notifyListeners();
    }
  }

  Future<void> continueHost() async {
    try {
      final launch = await _host.issueHostLaunch();
      await _gameLauncher.launch(
        GameLaunchRequest(
          gameId: launch.gameId,
          matchId: launch.matchId,
          launchTicket: launch.launchTicket,
          wsUrl: launch.wsUrl,
          source: GameLaunchSource.lan,
        ),
      );
      final current = _state;
      _set(
        LanActive(
          roomId: launch.matchId,
          revision: current is LanActive ? current.revision : 0,
          role: 'host',
        ),
      );
    } on LanHostException catch (error) {
      _set(LanRoomFailure(error.code));
    } on GameLaunchException catch (error) {
      _set(LanRoomFailure(error.code));
    }
  }

  Future<void> cancelOrResign({required bool confirmed}) async {
    final current = _state;
    final revision = switch (current) {
      LanActive(:final revision) => revision,
      LanWaitingForGuest() => 0,
      _ => -1,
    };
    if (revision < 0 || revision > 0 && !confirmed) return;
    try {
      final status = await _host.closeRoom(revision == 0 ? 'cancel' : 'resign');
      _applyHostStatus(status);
    } on LanHostException catch (error) {
      _set(LanRoomFailure(error.code));
    }
  }

  Future<void> discardCorrupt({required bool confirmed}) async {
    if (!confirmed || _state is! LanRecoveryCorrupt) return;
    try {
      await _host.closeRoom('discard_corrupt');
      _set(const LanIdle());
    } on LanHostException catch (error) {
      _set(LanRoomFailure(error.code));
    }
  }

  Future<void> _launchGuest(
    LanLaunchReceipt receipt,
    LanEndpoint endpoint,
  ) async {
    _set(LanReady(receipt));
    await _gameLauncher.launch(
      GameLaunchRequest(
        gameId: receipt.gameId,
        matchId: receipt.matchId,
        launchTicket: receipt.launchTicket,
        wsUrl: endpoint.webSocketUri.toString(),
        source: GameLaunchSource.lan,
      ),
    );
    _set(LanActive(roomId: receipt.matchId, revision: 0, role: 'guest'));
  }

  void _showWaiting(LanHostCreation creation) {
    final status = creation.status;
    final endpoint = status.endpoint;
    _set(
      LanWaitingForGuest(
        roomId: status.roomId!,
        qr: endpoint == null
            ? null
            : LanJoinQr(
                roomId: status.roomId!,
                endpoint: endpoint,
                roomKey: creation.roomKey,
                expiresAt: creation.joinExpiresAt,
              ),
        errorCode: endpoint == null ? 'no_network_address' : null,
      ),
    );
  }

  void _applyHostStatus(LanHostStatus status) {
    switch (status.state) {
      case LanNativeState.empty:
      case LanNativeState.cancelled:
        _hostCreation = null;
        _set(const LanIdle());
      case LanNativeState.corrupt:
        _set(LanRecoveryCorrupt(status.roomId!));
      case LanNativeState.finished:
        _set(LanFinishedAwaitingAck(status.roomId!));
      case LanNativeState.waiting:
        final creation = _hostCreation;
        if (creation != null) {
          _showWaiting(creation);
        } else {
          _set(LanActive(roomId: status.roomId!, revision: 0, role: 'host'));
        }
      case LanNativeState.active:
        if (status.endpointChanged && status.endpoint != null) {
          _set(
            LanEndpointChanged(
              LanResumeQr(roomId: status.roomId!, endpoint: status.endpoint!),
            ),
          );
        } else {
          _set(
            LanActive(
              roomId: status.roomId!,
              revision: status.gameRevision,
              role: 'host',
            ),
          );
        }
    }
  }

  String? _safeRoomId(String raw) {
    try {
      return LanQrPayload.parse(raw, _now()).roomId;
    } on Object {
      return null;
    }
  }

  void _set(LanRoomState next) {
    if (_disposed) return;
    _state = next;
    _notifyListeners();
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
