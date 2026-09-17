import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/api/api_error.dart';
import 'battleship_api.dart';
import 'battleship_models.dart';

abstract interface class SeaPendingStore {
  Future<Map<String, Object?>?> read(String key);
  Future<void> write(String key, Map<String, Object?>? value);
}

final class SecureSeaPendingStore implements SeaPendingStore {
  const SecureSeaPendingStore();
  static const _storage = FlutterSecureStorage();
  @override
  Future<Map<String, Object?>?> read(String key) async {
    final raw = await _storage.read(key: key);
    return raw == null ? null : jsonDecode(raw) as Map<String, Object?>;
  }

  @override
  Future<void> write(String key, Map<String, Object?>? value) => value == null
      ? _storage.delete(key: key)
      : _storage.write(key: key, value: jsonEncode(value));
}

final class BattleshipController extends ChangeNotifier {
  BattleshipController(this.api, this.id, this.store);
  final BattleshipApi api;
  final String id;
  final SeaPendingStore store;
  SeaMatch? match;
  Map<String, Object?>? pendingAction;
  bool busy = false,
      syncing = true,
      foreground = true,
      _disposed = false,
      _initialized = false;
  String? error;
  Timer? _timer;
  int _refreshSerial = 0;
  String get _key => 'battleship.pending.${api.userId}.$id';
  bool get canAct =>
      foreground &&
      !busy &&
      !syncing &&
      error == null &&
      pendingAction == null &&
      match != null;
  List<FleetShip> get shownShips {
    final pending = pendingAction;
    if (pending != null &&
        (pending['kind'] == 'save' || pending['kind'] == 'ready')) {
      return (pending['ships'] as List).map(FleetShip.parse).toList();
    }
    return match?.ownShips ?? [];
  }

  Future<void> start() async {
    if (_initialized) return;
    _initialized = true;
    try {
      pendingAction = await store.read(_key);
    } catch (_) {
      error = '无法读取待发送操作，请重试';
      syncing = false;
      _notify();
      return;
    }
    await refresh();
  }

  void setForeground(bool value) {
    foreground = value;
    _timer?.cancel();
    if (value) {
      unawaited(refresh());
    } else {
      _refreshSerial++;
      syncing = true;
      _notify();
    }
  }

  void _schedule() {
    _timer?.cancel();
    if (!_disposed && foreground && !busy) {
      _timer = Timer(
        const Duration(seconds: 5),
        () => unawaited(refresh(silent: true)),
      );
    }
  }

  Future<void> refresh({bool silent = false}) async {
    if (_disposed || busy || !foreground) return;
    _timer?.cancel();
    final serial = ++_refreshSerial;
    if (!silent) {
      syncing = true;
      _notify();
    }
    try {
      final next = await api.get(id);
      if (!_disposed &&
          serial == _refreshSerial &&
          (match == null || next.revision >= match!.revision)) {
        match = next;
        error = null;
      }
    } catch (_) {
      if (!_disposed && serial == _refreshSerial) error = '连接失败，重试后继续';
    } finally {
      if (serial == _refreshSerial) {
        syncing = false;
        _notify();
        _schedule();
      }
    }
  }

  Future<void> submit(
    String kind, {
    List<FleetShip> ships = const [],
    int cell = 0,
  }) async {
    if (!canAct) return;
    pendingAction = {
      'actionId': battleshipId(),
      'revision': match!.revision,
      'kind': kind,
      'ships': ships.map((s) => s.toJson()).toList(),
      'cell': cell,
    };
    await retry();
  }

  Future<void> retry() async {
    if (busy || !foreground || _disposed) return;
    if (pendingAction == null) {
      if (match == null) {
        _initialized = false;
        await start();
      } else {
        await refresh();
      }
      return;
    }
    _refreshSerial++;
    syncing = false;
    busy = true;
    error = null;
    _timer?.cancel();
    _notify();
    try {
      // Persist the exact idempotent request before sending. Closing the page or
      // killing the app cannot silently discard an uncertain placement or shot.
      await store.write(_key, pendingAction);
      final next = await api.act(id, pendingAction!);
      await store.write(_key, null);
      if (!_disposed) {
        match = next;
        pendingAction = null;
      }
    } on ApiError catch (e) {
      if ([
        'stale_revision',
        'invalid_request',
        'match_not_found',
      ].contains(e.code)) {
        try {
          await store.write(_key, null);
          pendingAction = null;
        } catch (_) {}
        if (!_disposed) error = '对局已更新，请刷新后重试';
      } else {
        if (!_disposed) error = '发送未确认，请重试';
      }
    } catch (_) {
      if (!_disposed) error = '发送未确认，请重试';
    } finally {
      busy = false;
      _notify();
      _schedule();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
