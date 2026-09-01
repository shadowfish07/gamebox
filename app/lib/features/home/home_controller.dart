import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/api/api_error.dart';
import '../../core/platform/game_launcher.dart';
import '../gomoku/gomoku_models.dart';
import '../gomoku/gomoku_repository.dart';
import '../../core/lan/lan_models.dart';

abstract interface class HomeScheduledCall {
  void cancel();
}

abstract interface class HomePollScheduler {
  HomeScheduledCall schedulePeriodic(Duration period, void Function() callback);
}

final class TimerHomePollScheduler implements HomePollScheduler {
  const TimerHomePollScheduler();

  @override
  HomeScheduledCall schedulePeriodic(
    Duration period,
    void Function() callback,
  ) => _TimerScheduledCall(Timer.periodic(period, (_) => callback()));
}

final class _TimerScheduledCall implements HomeScheduledCall {
  const _TimerScheduledCall(this._timer);

  final Timer _timer;

  @override
  void cancel() => _timer.cancel();
}

final class HomeController extends ChangeNotifier {
  HomeController({
    required this._repository,
    HomePollScheduler? scheduler,
    DateTime Function()? now,
  }) : _scheduler = scheduler ?? const TimerHomePollScheduler(),
       _now = now ?? DateTime.now;

  static const pollInterval = Duration(seconds: 10);

  final GomokuRepository _repository;
  final HomePollScheduler _scheduler;
  final DateTime Function() _now;

  GomokuStatus? _status;
  ApiError? _lastError;
  DateTime? _lastUpdatedAt;
  HomeScheduledCall? _polling;
  Future<ApiError?>? _mutationInFlight;
  _HomeMutationKey? _mutationKey;
  var _generation = 0;
  var _started = false;
  var _foreground = false;
  var _loading = false;
  var _creating = false;
  var _launching = false;
  var _cancelling = false;
  var _disposed = false;

  GomokuStatus? get status => _status;
  ApiError? get lastError => _lastError;
  DateTime? get lastUpdatedAt => _lastUpdatedAt;
  bool get isLoading => _loading;
  bool get isCreating => _creating;
  bool get isLaunching => _launching;
  bool get isCancelling => _cancelling;
  bool get isMutating => _creating || _launching || _cancelling;
  bool get canCancel =>
      _status is GomokuActiveStatus &&
      (_status as GomokuActiveStatus).match.revision == 0 &&
      !isMutating;

  void start() {
    if (_disposed || _started) return;
    _started = true;
    _foreground = true;
    _restartPolling();
    unawaited(refresh());
  }

  void pauseForeground() {
    if (_disposed) return;
    _foreground = false;
    _polling?.cancel();
    _polling = null;
  }

  void resumeForeground() {
    if (_disposed) return;
    _started = true;
    _foreground = true;
    _restartPolling();
    unawaited(refresh());
  }

  Future<void> refresh() async {
    if (_disposed) return;
    final generation = ++_generation;
    _loading = _status == null;
    _lastError = null;
    _notify();
    await _refreshForGeneration(generation);
  }

  Future<List<GomokuOpponent>> fetchOpponents() => _repository.fetchOpponents();

  Future<AuthoritativeGameResult> fetchResult(String matchId) =>
      _repository.fetchResult(matchId);

  Future<ApiError?> openActiveMatch() {
    if (_disposed) return Future<ApiError?>.value(_invalidState);
    final key = (kind: _HomeMutationKind.launch, id: _activeMatchId ?? '');
    final existing = _existingMutation(key);
    if (existing != null) return existing;
    final current = _status;
    if (current is! GomokuActiveStatus) {
      return Future<ApiError?>.value(_invalidState);
    }
    return _beginMutation((
      kind: _HomeMutationKind.launch,
      id: current.match.id,
    ), () => _performOpen(current.match.id));
  }

  Future<ApiError?> createAndOpen(String opponentId) {
    if (_disposed) return Future<ApiError?>.value(_invalidState);
    final key = (kind: _HomeMutationKind.create, id: opponentId);
    final existing = _existingMutation(key);
    if (existing != null) return existing;
    return _beginMutation(key, () => _performCreate(opponentId));
  }

  Future<ApiError?> cancelActiveMatch() {
    if (_disposed) return Future<ApiError?>.value(_invalidState);
    final key = (kind: _HomeMutationKind.cancel, id: _activeMatchId ?? '');
    final existing = _existingMutation(key);
    if (existing != null) return existing;
    final current = _status;
    if (current is! GomokuActiveStatus || current.match.revision != 0) {
      return Future<ApiError?>.value(_invalidState);
    }
    return _beginMutation((
      kind: _HomeMutationKind.cancel,
      id: current.match.id,
    ), () => _performCancel(current.match.id));
  }

  String? get _activeMatchId => switch (_status) {
    GomokuActiveStatus active => active.match.id,
    _ => null,
  };

  Future<ApiError?>? _existingMutation(_HomeMutationKey key) {
    final existing = _mutationInFlight;
    if (existing == null) return null;
    return _mutationKey == key
        ? existing
        : Future<ApiError?>.value(_operationInProgress);
  }

  Future<ApiError?> _beginMutation(
    _HomeMutationKey key,
    Future<ApiError?> Function() perform,
  ) {
    final completer = Completer<ApiError?>();
    final operation = completer.future;
    _mutationKey = key;
    _mutationInFlight = operation;
    unawaited(_completeMutation(operation, completer, perform));
    return operation;
  }

  Future<void> _completeMutation(
    Future<ApiError?> operation,
    Completer<ApiError?> completer,
    Future<ApiError?> Function() perform,
  ) async {
    try {
      completer.complete(await perform());
    } catch (error, stackTrace) {
      completer.completeError(error, stackTrace);
    } finally {
      if (identical(_mutationInFlight, operation)) {
        _mutationInFlight = null;
        _mutationKey = null;
      }
    }
  }

  Future<ApiError?> _performOpen(String matchId) async {
    _generation += 1;
    _launching = true;
    _lastError = null;
    _notify();
    ApiError? error;
    try {
      await _repository.openMatch(matchId);
    } catch (caught) {
      error = _safeActionError(caught);
    }
    await _refreshAfterAction();
    if (!_disposed) {
      _launching = false;
      _notify();
    }
    return error;
  }

  Future<ApiError?> _performCreate(String opponentId) async {
    _generation += 1;
    _creating = true;
    _lastError = null;
    _notify();
    ApiError? error;
    try {
      await _repository.createAndOpen(opponentId);
    } catch (caught) {
      error = _safeActionError(caught);
    }
    await _refreshAfterAction();
    if (!_disposed) {
      _creating = false;
      _notify();
    }
    return error;
  }

  Future<ApiError?> _performCancel(String matchId) async {
    _generation += 1;
    _cancelling = true;
    _lastError = null;
    _notify();
    ApiError? error;
    try {
      await _repository.cancelMatch(matchId);
    } catch (caught) {
      error = _safeActionError(caught);
    }
    await _refreshAfterAction();
    if (!_disposed) {
      _cancelling = false;
      _notify();
    }
    return error;
  }

  Future<void> _refreshAfterAction() async {
    if (_disposed) return;
    final generation = ++_generation;
    _loading = _status == null;
    await _refreshForGeneration(generation);
  }

  Future<void> _refreshForGeneration(int generation) async {
    try {
      final next = await _repository.fetchStatus();
      if (!_isCurrent(generation)) return;
      _status = next;
      _lastError = null;
      _lastUpdatedAt = _now().toUtc();
    } catch (caught) {
      if (!_isCurrent(generation)) return;
      _lastError = _safeRefreshError(caught);
    }
    if (_isCurrent(generation)) {
      _loading = false;
      _notify();
    }
  }

  void _restartPolling() {
    _polling?.cancel();
    _polling = _scheduler.schedulePeriodic(pollInterval, () {
      if (_disposed || !_foreground || isMutating) {
        return;
      }
      unawaited(refresh());
    });
  }

  static ApiError _safeActionError(Object caught) => switch (caught) {
    ApiError error => error,
    GameLaunchException _ => const ApiError(
      code: 'launch_failed',
      message: '无法启动游戏，请重试',
    ),
    GomokuLaunchConfigurationException _ => const ApiError(
      code: 'invalid_response',
      message: '服务器响应无效',
    ),
    _ => const ApiError(code: 'internal_error', message: '操作失败，请稍后重试'),
  };

  static ApiError _safeRefreshError(Object caught) => switch (caught) {
    ApiError error => error,
    _ => const ApiError(code: 'internal_error', message: '刷新失败，请稍后重试'),
  };

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation += 1;
    _polling?.cancel();
    _polling = null;
    _mutationInFlight = null;
    _mutationKey = null;
    super.dispose();
  }

  static const _invalidState = ApiError(
    code: 'invalid_state',
    message: '当前无法执行此操作',
  );

  static const _operationInProgress = ApiError(
    code: 'operation_in_progress',
    message: '已有操作正在进行，请稍后重试',
  );
}

enum _HomeMutationKind { create, launch, cancel }

typedef _HomeMutationKey = ({_HomeMutationKind kind, String id});
