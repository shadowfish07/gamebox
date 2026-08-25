import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/api/api_error.dart';
import '../../core/platform/game_launcher.dart';
import '../gomoku/gomoku_models.dart';
import 'rps_models.dart';
import 'rps_repository.dart';

final class RpsController extends ChangeNotifier {
  RpsController({required this.repository});

  final RpsRepository repository;

  RpsStatus? _status;
  ApiError? _lastError;
  Timer? _polling;
  Future<ApiError?>? _mutation;
  var _loading = false;
  var _creating = false;
  var _launching = false;
  var _cancelling = false;
  var _disposed = false;
  var _generation = 0;

  RpsStatus? get status => _status;
  ApiError? get lastError => _lastError;
  bool get isLoading => _loading;
  bool get isCreating => _creating;
  bool get isLaunching => _launching;
  bool get isCancelling => _cancelling;
  bool get isMutating => _mutation != null;
  bool get canCancel => switch (_status) {
    RpsActiveStatus(:final match) => match.revision == 0,
    _ => false,
  };

  void start() => resumeForeground();

  void resumeForeground() {
    if (_disposed) return;
    _polling?.cancel();
    _polling = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!_disposed && !isMutating) unawaited(refresh());
    });
    unawaited(refresh());
  }

  void pauseForeground() {
    _polling?.cancel();
    _polling = null;
  }

  Future<void> refresh() async {
    if (_disposed) return;
    final generation = ++_generation;
    _loading = _status == null;
    _lastError = null;
    _notify();
    try {
      final next = await repository.fetchStatus();
      if (_current(generation)) {
        _status = next;
      }
    } catch (error) {
      if (_current(generation)) {
        _lastError = _safeError(error, refreshing: true);
      }
    }
    if (_current(generation)) {
      _loading = false;
      _notify();
    }
  }

  Future<List<GomokuOpponent>> fetchOpponents() => repository.fetchOpponents();

  Future<ApiError?> createAndOpen(String opponentId, RpsFormat format) =>
      _mutate(() async {
        _creating = true;
        await repository.createAndOpen(opponentId, format);
      });

  Future<ApiError?> openActiveMatch() {
    final current = _status;
    if (current is! RpsActiveStatus) {
      return Future.value(_invalidState);
    }
    return _mutate(() async {
      _launching = true;
      await repository.openMatch(current.match.id);
    });
  }

  Future<ApiError?> cancelActiveMatch() {
    final current = _status;
    if (current is! RpsActiveStatus || current.match.revision != 0) {
      return Future.value(_invalidState);
    }
    return _mutate(() async {
      _cancelling = true;
      await repository.cancelMatch(current.match.id);
    });
  }

  Future<ApiError?> _mutate(Future<void> Function() operation) {
    if (_disposed) return Future.value(_invalidState);
    if (_mutation != null) return Future.value(_operationInProgress);
    final completer = Completer<ApiError?>();
    _mutation = completer.future;
    unawaited(() async {
      _generation++;
      _lastError = null;
      _notify();
      ApiError? error;
      try {
        await operation();
      } catch (caught) {
        error = _safeError(caught);
      }
      await refresh();
      if (!_disposed) {
        _creating = false;
        _launching = false;
        _cancelling = false;
        _mutation = null;
        _notify();
      }
      completer.complete(error);
    }());
    return completer.future;
  }

  static ApiError _safeError(Object error, {bool refreshing = false}) =>
      switch (error) {
        ApiError value => value,
        GameLaunchException _ || RpsLaunchConfigurationException _ =>
          const ApiError(code: 'launch_failed', message: '无法启动游戏，请重试'),
        _ => ApiError(
          code: 'internal_error',
          message: refreshing ? '刷新失败，请稍后重试' : '操作失败，请稍后重试',
        ),
      };

  bool _current(int generation) => !_disposed && generation == _generation;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    pauseForeground();
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
