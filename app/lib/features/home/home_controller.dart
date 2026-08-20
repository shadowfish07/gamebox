import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/api/api_error.dart';
import '../../core/platform/game_launcher.dart';
import '../gomoku/gomoku_models.dart';
import '../gomoku/gomoku_repository.dart';

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
    required GomokuRepository repository,
    HomePollScheduler? scheduler,
    DateTime Function()? now,
  }) : _repository = repository,
       _scheduler = scheduler ?? const TimerHomePollScheduler(),
       _now = now ?? DateTime.now;

  static const pollInterval = Duration(seconds: 10);

  final GomokuRepository _repository;
  final HomePollScheduler _scheduler;
  final DateTime Function() _now;

  GomokuStatus? _status;
  ApiError? _lastError;
  DateTime? _lastUpdatedAt;
  HomeScheduledCall? _polling;
  Future<ApiError?>? _createInFlight;
  Future<ApiError?>? _launchInFlight;
  Future<ApiError?>? _cancelInFlight;
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
  bool get canCancel =>
      _status is GomokuActiveStatus &&
      (_status as GomokuActiveStatus).match.revision == 0 &&
      !_cancelling;

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

  Future<ApiError?> openActiveMatch() {
    final existing = _launchInFlight;
    if (existing != null) return existing;
    final current = _status;
    if (current is! GomokuActiveStatus) {
      return Future<ApiError?>.value(_invalidState);
    }
    late final Future<ApiError?> operation;
    operation = _performOpen(current.match.id).whenComplete(() {
      if (identical(_launchInFlight, operation)) _launchInFlight = null;
    });
    _launchInFlight = operation;
    return operation;
  }

  Future<ApiError?> createAndOpen(String opponentId) {
    final existing = _createInFlight;
    if (existing != null) return existing;
    late final Future<ApiError?> operation;
    operation = _performCreate(opponentId).whenComplete(() {
      if (identical(_createInFlight, operation)) _createInFlight = null;
    });
    _createInFlight = operation;
    return operation;
  }

  Future<ApiError?> cancelActiveMatch() {
    final existing = _cancelInFlight;
    if (existing != null) return existing;
    final current = _status;
    if (current is! GomokuActiveStatus || current.match.revision != 0) {
      return Future<ApiError?>.value(_invalidState);
    }
    late final Future<ApiError?> operation;
    operation = _performCancel(current.match.id).whenComplete(() {
      if (identical(_cancelInFlight, operation)) _cancelInFlight = null;
    });
    _cancelInFlight = operation;
    return operation;
  }

  Future<ApiError?> _performOpen(String matchId) async {
    final generation = ++_generation;
    _launching = true;
    _lastError = null;
    _notify();
    ApiError? error;
    try {
      await _repository.openMatch(matchId);
    } catch (caught) {
      error = _safeActionError(caught);
    }
    await _refreshForGeneration(generation);
    if (!_disposed) {
      _launching = false;
      _notify();
    }
    return error;
  }

  Future<ApiError?> _performCreate(String opponentId) async {
    final generation = ++_generation;
    _creating = true;
    _lastError = null;
    _notify();
    ApiError? error;
    try {
      await _repository.createAndOpen(opponentId);
    } catch (caught) {
      error = _safeActionError(caught);
    }
    await _refreshForGeneration(generation);
    if (!_disposed) {
      _creating = false;
      _notify();
    }
    return error;
  }

  Future<ApiError?> _performCancel(String matchId) async {
    final generation = ++_generation;
    _cancelling = true;
    _lastError = null;
    _notify();
    ApiError? error;
    try {
      await _repository.cancelMatch(matchId);
      await _refreshForGeneration(generation);
    } catch (caught) {
      error = _safeActionError(caught);
    }
    if (!_disposed) {
      _cancelling = false;
      _notify();
    }
    return error;
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
      if (_disposed || !_foreground || _creating || _launching || _cancelling) {
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
    _createInFlight = null;
    _launchInFlight = null;
    _cancelInFlight = null;
    super.dispose();
  }

  static const _invalidState = ApiError(
    code: 'invalid_state',
    message: '当前无法执行此操作',
  );
}
