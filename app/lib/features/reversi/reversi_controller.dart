import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../core/platform/game_launch_request.dart';
import 'reversi_models.dart';
import 'reversi_transport.dart';

enum ReversiConnection { connecting, ready, reconnecting, failed, paused }

final class ReversiController extends ChangeNotifier {
  ReversiController({
    required this.request,
    required this.freshTicket,
    Future<ReversiTransport> Function(String)? connect,
  }) : _connect = connect ?? connectReversi;
  final GameLaunchRequest request;
  final Future<String> Function() freshTicket;
  final Future<ReversiTransport> Function(String) _connect;
  ReversiTransport? _transport;
  StreamSubscription<Object?>? _subscription;
  Timer? _deadline, _retry;
  String? _resumeToken, _initialTicket;
  var _started = false,
      _disposed = false,
      _paused = false,
      _generation = 0,
      _attempt = 0;
  ReversiSnapshot? snapshot;
  ReversiConnection connection = ReversiConnection.connecting;
  String? userId, error;
  int? pendingCell;
  bool pending = false;
  bool get canAct =>
      connection == ReversiConnection.ready &&
      !pending &&
      snapshot?.active == true;
  bool get myTurn => userId != null && snapshot?.isTurn(userId!) == true;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _initialTicket = request.launchTicket;
    await reconnect();
  }

  Future<void> reconnect() async {
    if (_disposed || _paused) return;
    final generation = ++_generation;
    _retry?.cancel();
    _deadline?.cancel();
    _detach();
    connection = snapshot == null
        ? ReversiConnection.connecting
        : ReversiConnection.reconnecting;
    pending = false;
    pendingCell = null;
    error = null;
    notifyListeners();
    try {
      final credential = _resumeToken ?? _initialTicket ?? await freshTicket();
      if (!_current(generation)) return;
      final transport = await _connect(request.wsUrl);
      if (!_current(generation)) {
        unawaited(transport.close());
        return;
      }
      _transport = transport;
      _subscription = transport.messages.listen(
        (data) => _receive(generation, data),
        onError: (Object e) => _lost(generation),
        onDone: () => _lost(generation),
      );
      _send('platform.connect', {
        _resumeToken != null ? 'resumeToken' : 'launchTicket': credential,
      }, bound: false);
      _initialTicket = null;
      _deadline = Timer(const Duration(seconds: 10), () => _lost(generation));
    } catch (_) {
      _lost(generation);
    }
  }

  bool _current(int generation) =>
      !_disposed && !_paused && generation == _generation;
  void _detach() {
    final subscription = _subscription;
    _subscription = null;
    unawaited(subscription?.cancel());
    final transport = _transport;
    _transport = null;
    unawaited(transport?.close());
  }

  void _lost(int generation) {
    if (!_current(generation)) return;
    ++_generation;
    _deadline?.cancel();
    _detach();
    pending = false;
    pendingCell = null;
    connection = ReversiConnection.reconnecting;
    if (++_attempt > 5) {
      connection = ReversiConnection.failed;
      error = '连接失败，请重试';
    } else {
      _retry = Timer(Duration(seconds: min(8, 1 << (_attempt - 1))), reconnect);
    }
    notifyListeners();
  }

  void _receive(int generation, Object? data) {
    if (!_current(generation)) return;
    try {
      if (data is! String || data.length > 65536) throw const FormatException();
      final envelope = jsonDecode(data) as Map<String, dynamic>;
      if (envelope['protocolVersion'] != 1) throw const FormatException();
      final type = envelope['type'];
      final payload = envelope['payload'] as Map<String, dynamic>;
      if (type == 'platform.error' && envelope['matchId'] == null) {
        _resumeToken = null;
        _lost(generation);
        return;
      }
      if (envelope['gameId'] != reversiGameId ||
          envelope['matchId'] != request.matchId) {
        throw const FormatException();
      }
      if (type == 'platform.ping') {
        _send('platform.pong', {'nonce': payload['nonce']});
        return;
      }
      if (type == 'platform.connected') {
        userId = payload['userId'] as String;
        _resumeToken = payload['resumeToken'] as String;
        return;
      }
      if (type == 'platform.snapshot') {
        final next = ReversiSnapshot.fromJson(
          envelope['revision'] as int,
          payload,
        );
        if (userId != next.blackUserId && userId != next.whiteUserId) {
          throw const FormatException();
        }
        if (snapshot != null && next.revision < snapshot!.revision) return;
        // An old snapshot cannot acknowledge a newly submitted action.
        if (pending &&
            snapshot != null &&
            next.revision <= snapshot!.revision) {
          return;
        }
        snapshot = next;
        pending = false;
        pendingCell = null;
        connection = ReversiConnection.ready;
        _attempt = 0;
        _deadline?.cancel();
        notifyListeners();
        return;
      }
      if (type == 'platform.error') {
        pending = false;
        pendingCell = null;
        error = switch (payload['code']) {
          'not_your_turn' => '还没轮到你',
          'stale_revision' => '棋盘已更新，请重新落子',
          _ => '操作未完成，请重试',
        };
        _synchronize();
        notifyListeners();
        return;
      }
      if (type == 'reversi.move.accepted' ||
          type == 'reversi.resigned' ||
          type == 'platform.match.cancelled' ||
          type == 'platform.match.abandoned') {
        _synchronize();
        notifyListeners();
      }
    } catch (_) {
      error = '连接异常，请重试';
      _lost(generation);
    }
  }

  void _synchronize() {
    connection = ReversiConnection.reconnecting;
    _send('platform.snapshot.requested', {
      'currentRevision': snapshot?.revision ?? 0,
    });
    _deadline?.cancel();
    final generation = _generation;
    _deadline = Timer(const Duration(seconds: 10), () => _lost(generation));
  }

  void move(int cell) {
    if (!canAct || !myTurn || snapshot?.legalMoves.contains(cell) != true) {
      return;
    }
    pendingCell = cell;
    _action('reversi.move.requested', {'x': cell % 8, 'y': cell ~/ 8});
  }

  void resign() {
    if (!canAct || snapshot!.revision == 0) return;
    _action('reversi.resign.requested', {});
  }

  void _action(String type, Map<String, Object?> payload) {
    pending = true;
    error = null;
    _send(type, payload, action: true);
    _deadline?.cancel();
    final generation = _generation;
    _deadline = Timer(const Duration(seconds: 10), () => _lost(generation));
    notifyListeners();
  }

  void _send(
    String type,
    Map<String, Object?> payload, {
    bool bound = true,
    bool action = false,
  }) {
    try {
      _transport?.send(
        jsonEncode({
          'protocolVersion': 1,
          'type': type,
          'payload': payload,
          if (bound) ...{'gameId': reversiGameId, 'matchId': request.matchId},
          if (action) ...{
            'actionId': _uuid(),
            'expectedRevision': snapshot!.revision,
          },
        }),
      );
    } catch (_) {
      _lost(_generation);
    }
  }

  void pause() {
    if (_disposed || _paused) return;
    _paused = true;
    ++_generation;
    _retry?.cancel();
    _deadline?.cancel();
    _detach();
    connection = ReversiConnection.paused;
    pending = false;
    pendingCell = null;
    notifyListeners();
  }

  void resume() {
    if (!_paused || _disposed) return;
    _paused = false;
    _attempt = 0;
    unawaited(reconnect());
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    _retry?.cancel();
    _deadline?.cancel();
    _detach();
    super.dispose();
  }
}

String _uuid() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 15) | 64;
  b[8] = (b[8] & 63) | 128;
  final h = b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}
