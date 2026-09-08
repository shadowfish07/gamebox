import 'dart:async';

import 'package:flutter/foundation.dart';

import 'scratch_controller.dart';
import 'scratch_social_api.dart';

/// Uploads only durable collection changes, serializing requests and retrying
/// failures without interrupting offline scratching. Reopening retries the
/// latest local snapshot, so no separate volatile upload queue is needed.
final class ScratchCollectionSync {
  ScratchCollectionSync(this.collection, this.api) {
    collection.addListener(_changed);
    unawaited(sync());
  }
  final ScratchController collection;
  final ScratchSocialApi api;
  List<int>? _sent;
  Future<void>? _active;
  Timer? _retry;
  int _retrySeconds = 2;
  bool _disposed = false;
  void _changed() => unawaited(sync());
  bool get _ready =>
      !_disposed &&
      api.canSync &&
      collection.interactive &&
      !collection.unsaved;

  Future<void> sync() {
    if (_active != null) return _active!;
    if (!_ready || listEquals(_sent, collection.counts)) {
      return Future.value();
    }
    _retry?.cancel();
    final task = _upload();
    _active = task;
    return task.whenComplete(() => _active = null);
  }

  Future<void> _upload() async {
    try {
      while (_ready && !listEquals(_sent, collection.counts)) {
        final counts = List<int>.of(collection.counts);
        await api.sync(counts);
        _sent = counts;
        _retrySeconds = 2;
      }
    } catch (_) {
      if (_disposed) return;
      _retry = Timer(Duration(seconds: _retrySeconds), _changed);
      _retrySeconds = (_retrySeconds * 2).clamp(2, 60);
    }
  }

  void dispose() {
    _disposed = true;
    _retry?.cancel();
    collection.removeListener(_changed);
  }
}
