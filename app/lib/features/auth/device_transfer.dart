import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/api/api_client.dart';
import '../../core/api/api_error.dart';
import '../../core/auth/session.dart';
import '../scratch/scratch_controller.dart';
import 'session_controller.dart';

abstract interface class TransferStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

final class SecureTransferStore implements TransferStore {
  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false),
  );
  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

final class DeviceTransfer extends ChangeNotifier {
  DeviceTransfer({
    required this.api,
    required this.session,
    required this.store,
    required this.scratchStore,
  });
  static const incomingKey = 'gamebox.transfer.incoming.v1';
  static const outgoingKey = 'gamebox.transfer.outgoing.v1';
  final ApiClient api;
  final SessionController session;
  final TransferStore store;
  final ScratchStore scratchStore;
  bool busy = false;
  bool incoming = false;
  bool outgoing = false;
  bool _disposed = false;
  bool _retryJournalRestore = false;
  String? error;
  String? code;
  DateTime? expiresAt;
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> restoreIncoming() async {
    try {
      incoming = await store.read(incomingKey) != null;
      outgoing = await store.read(outgoingKey) != null;
      if (incoming) await receive();
    } catch (_) {
      _retryJournalRestore = true;
      incoming = true;
      error = '无法读取迁移进度，请重试';
      _changed();
    }
  }

  Future<void> generate() async {
    if (busy) return;
    busy = true;
    error = null;
    code = null;
    _changed();
    try {
      // Persist the cancellation obligation before sending any request. After
      // process death the app cancels this snapshot before allowing more draws.
      await store.write(outgoingKey, 'pending');
      outgoing = true;
      final controller = ScratchController(store: scratchStore);
      late String snapshot;
      try {
        await controller.load();
        if (controller.error != null || controller.unsaved) {
          throw StateError('save unavailable');
        }
        snapshot = controller.exportTransfer();
      } finally {
        controller.dispose();
      }
      final response = await api.postJson(
        '/v1/auth/transfer',
        {'snapshot': snapshot},
        accessToken: () => session.accessToken,
        onUnauthorized: session.refresh,
        expectedStatuses: const {201},
      );
      final value = response['code'];
      final expires = response['expiresAt'];
      if (value is! String ||
          !RegExp(r'^[A-Z2-7]{8}$').hasMatch(value) ||
          expires is! int) {
        throw const ApiError(code: 'invalid_response', message: '服务器响应无效');
      }
      code = value;
      expiresAt = DateTime.fromMillisecondsSinceEpoch(expires);
    } on ApiError catch (e) {
      error = transferMessage(e);
    } catch (_) {
      error = '无法准备迁移存档，请重试';
    } finally {
      busy = false;
      _changed();
    }
  }

  Future<bool> cancelOutgoing() async {
    if (busy) return false;
    busy = true;
    error = null;
    _changed();
    try {
      await _cancelOutgoing();
      return true;
    } on ApiError catch (e) {
      error = transferMessage(e);
      return false;
    } catch (_) {
      error = '无法取消迁移，请重试';
      return false;
    } finally {
      busy = false;
      _changed();
    }
  }

  Future<void> _cancelOutgoing() async {
    if (session.accessToken != null) {
      await api.deleteEmpty(
        '/v1/auth/transfer',
        accessToken: () => session.accessToken,
        onUnauthorized: session.refresh,
      );
    } else if (session.canRetryRestore) {
      throw const ApiError(code: 'network_error', message: '网络连接失败');
    } else if (!session.migratedAway) {
      // Missing credentials do not prove that an outstanding bearer code was
      // revoked. Only a confirmed transfer makes cancellation unnecessary.
      throw const ApiError(code: 'unauthorized', message: '无法确认迁移已取消');
    }
    await store.delete(outgoingKey);
    outgoing = false;
    code = null;
  }

  Future<void> receive([String? enteredCode]) async {
    if (busy) return;
    busy = true;
    error = null;
    _changed();
    try {
      var raw = await store.read(incomingKey);
      if (_retryJournalRestore) {
        outgoing = await store.read(outgoingKey) != null;
      }
      if (raw == null) {
        if (enteredCode == null || _retryJournalRestore) {
          await session.restore();
          if (session.canRetryRestore) await session.retryRestore();
          if (outgoing) await _cancelOutgoing();
          // Keep the startup gate closed until both journal reads and any
          // outgoing cancellation have succeeded, including on later retries.
          _retryJournalRestore = false;
          incoming = false;
          return;
        }
        if (!session.canRegister) throw StateError('session not ready');
        final normalized = enteredCode
            .replaceAll(RegExp(r'\s'), '')
            .toUpperCase();
        if (!RegExp(r'^[A-Z2-7]{8}$').hasMatch(normalized)) {
          error = '请输入 8 位迁移码';
          return;
        }
        final random = Random.secure();
        raw = jsonEncode({
          'code': normalized,
          'receiver': base64UrlEncode(
            List.generate(32, (_) => random.nextInt(256)),
          ).replaceAll('=', ''),
        });
        await store.write(incomingKey, raw);
      }
      incoming = true;
      final pending = jsonDecode(raw) as Map<String, dynamic>;
      final response = await api.postJson(
        '/v1/auth/transfer/redeem',
        {'code': pending['code'], 'receiver': pending['receiver']},
        expectedStatuses: const {200},
      );
      final next = Session.fromEnvelope({'session': response['session']});
      final snapshot = response['snapshot'];
      if (snapshot is! String) throw const FormatException('missing snapshot');
      final normalized = ScratchController.validateTransfer(snapshot);
      await scratchStore.write(normalized);
      final restored = await session.importSession(
        next,
        beforePublish: () async {
          await store.delete(incomingKey);
          _retryJournalRestore = false;
          incoming = false;
        },
      );
      if (!restored) throw StateError('credential storage failed');
    } on ApiError catch (e) {
      error = transferMessage(e);
      if (e.code == 'transfer_invalid') {
        try {
          await store.delete(incomingKey);
          incoming = false;
          if (session.status == SessionStatus.restoring) {
            await session.restore();
          }
        } catch (_) {
          error = '无法更新迁移进度，请重试';
        }
      }
    } catch (_) {
      error = '无法恢复迁移进度，请重试';
    } finally {
      busy = false;
      _changed();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

String transferMessage(ApiError e) => switch (e.code) {
  'transfer_invalid' => '迁移码无效、已过期或已使用',
  'transfer_limited' => '尝试次数过多，请稍后再试',
  'network_error' || 'timeout' => '连接失败，请检查网络后重试',
  'unauthorized' => '登录状态已更新，请重试',
  _ => '暂时无法迁移，请重试',
};
