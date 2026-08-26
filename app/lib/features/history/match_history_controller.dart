import 'package:flutter/foundation.dart';

import '../../core/api/api_error.dart';
import 'match_history_api.dart';
import 'match_history_models.dart';

final class MatchHistoryController extends ChangeNotifier {
  MatchHistoryController({required this.api});

  final MatchHistoryApi api;

  List<MatchHistoryEntry> _matches = const [];
  MatchHistoryStatistics? _statistics;
  String? _nextCursor;
  ApiError? _initialError;
  ApiError? _loadMoreError;
  var _hasLoaded = false;
  var _isInitialLoading = false;
  var _isLoadingMore = false;
  var _disposed = false;

  List<MatchHistoryEntry> get matches => _matches;
  MatchHistoryStatistics? get statistics => _statistics;
  ApiError? get initialError => _initialError;
  ApiError? get loadMoreError => _loadMoreError;
  bool get isInitialLoading => _isInitialLoading;
  bool get isLoadingMore => _isLoadingMore;
  bool get hasMore => _nextCursor != null;

  Future<void> load() async {
    if (_disposed || _hasLoaded || _isInitialLoading) return;

    _isInitialLoading = true;
    _initialError = null;
    notifyListeners();
    try {
      final page = await api.fetchPage();
      if (_disposed) return;
      _matches = List<MatchHistoryEntry>.unmodifiable(page.matches);
      _statistics = page.statistics;
      _nextCursor = page.nextCursor;
      _hasLoaded = true;
    } on ApiError catch (error) {
      if (!_disposed) _initialError = error;
    } finally {
      if (!_disposed) {
        _isInitialLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> loadMore() async {
    final cursor = _nextCursor;
    if (_disposed ||
        !_hasLoaded ||
        _isInitialLoading ||
        _isLoadingMore ||
        cursor == null) {
      return;
    }

    _isLoadingMore = true;
    _loadMoreError = null;
    notifyListeners();
    try {
      final page = await api.fetchPage(cursor: cursor);
      if (_disposed) return;
      final seen = _matches.map((entry) => entry.id).toSet();
      _matches = List<MatchHistoryEntry>.unmodifiable([
        ..._matches,
        ...page.matches.where((entry) => seen.add(entry.id)),
      ]);
      _statistics = page.statistics;
      _nextCursor = page.nextCursor;
    } on ApiError catch (error) {
      if (!_disposed) _loadMoreError = error;
    } finally {
      if (!_disposed) {
        _isLoadingMore = false;
        notifyListeners();
      }
    }
  }

  Future<void> retry() {
    if (_disposed) return Future<void>.value();
    if (_initialError != null) {
      _initialError = null;
      return load();
    }
    if (_loadMoreError != null) return loadMore();
    return Future<void>.value();
  }

  Future<void> refresh() {
    if (_disposed || _isInitialLoading || _isLoadingMore) {
      return Future<void>.value();
    }
    _matches = const [];
    _statistics = null;
    _nextCursor = null;
    _initialError = null;
    _loadMoreError = null;
    _hasLoaded = false;
    return load();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    super.dispose();
  }
}
