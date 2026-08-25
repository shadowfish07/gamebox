import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/core/api/api_error.dart';
import 'package:gamebox/features/gomoku/gomoku_models.dart';
import 'package:gamebox/features/history/match_history_api.dart';
import 'package:gamebox/features/history/match_history_controller.dart';
import 'package:gamebox/features/history/match_history_models.dart';

void main() {
  test(
    'initial load publishes immutable data and a next page cursor',
    () async {
      final pending = Completer<MatchHistoryPageData>();
      final api = _FakeMatchHistoryApi()..onFetch = (_) => pending.future;
      final controller = MatchHistoryController(api: api);
      final page = _page(
        matches: [_entry('11111111-1111-4111-8111-111111111111')],
        nextCursor: 'next',
      );

      final loading = controller.load();

      expect(controller.isInitialLoading, isTrue);
      pending.complete(page);
      await loading;

      expect(controller.statistics, same(page.statistics));
      expect(controller.matches, orderedEquals(page.matches));
      expect(controller.hasMore, isTrue);
      expect(
        () => controller.matches.add(
          _entry('22222222-2222-4222-8222-222222222222'),
        ),
        throwsUnsupportedError,
      );
    },
  );

  test(
    'retry replaces an initial ApiError with the first successful page',
    () async {
      const error = ApiError(code: 'offline', message: '网络不可用');
      final successful = _page(
        matches: [_entry('11111111-1111-4111-8111-111111111111')],
      );
      var attempts = 0;
      final api = _FakeMatchHistoryApi()
        ..onFetch = (_) => switch (attempts++) {
          0 => Future.error(error),
          _ => Future.value(successful),
        };
      final controller = MatchHistoryController(api: api);

      await controller.load();

      expect(controller.initialError, same(error));
      expect(controller.matches, isEmpty);
      expect(controller.isInitialLoading, isFalse);

      await controller.retry();

      expect(controller.initialError, isNull);
      expect(controller.matches, orderedEquals(successful.matches));
      expect(controller.statistics, same(successful.statistics));
      expect(api.cursors, [null, null]);
    },
  );

  test('an empty first page is data without a follow-up request', () async {
    final page = _page(matches: const [], nextCursor: null);
    final api = _FakeMatchHistoryApi()..onFetch = (_) async => page;
    final controller = MatchHistoryController(api: api);

    await controller.load();
    await controller.loadMore();

    expect(controller.initialError, isNull);
    expect(controller.statistics, same(page.statistics));
    expect(controller.matches, isEmpty);
    expect(controller.hasMore, isFalse);
    expect(api.cursors, [null]);
  });

  test('load more appends unseen rows and replaces statistics', () async {
    final first = _page(
      matches: [
        _entry('11111111-1111-4111-8111-111111111111'),
        _entry('22222222-2222-4222-8222-222222222222'),
      ],
      nextCursor: 'cursor-1',
      wins: 1,
    );
    final second = _page(
      matches: [
        _entry('22222222-2222-4222-8222-222222222222'),
        _entry('33333333-3333-4333-8333-333333333333'),
      ],
      nextCursor: 'cursor-2',
      wins: 2,
    );
    var call = 0;
    final api = _FakeMatchHistoryApi()
      ..onFetch = (_) => Future.value(call++ == 0 ? first : second);
    final controller = MatchHistoryController(api: api);

    await controller.load();
    await controller.loadMore();

    expect(controller.matches.map((entry) => entry.id), [
      '11111111-1111-4111-8111-111111111111',
      '22222222-2222-4222-8222-222222222222',
      '33333333-3333-4333-8333-333333333333',
    ]);
    expect(controller.statistics, same(second.statistics));
    expect(controller.hasMore, isTrue);
    expect(api.cursors, [null, 'cursor-1']);
  });

  test('only one load-more request is active for a cursor', () async {
    final pending = Completer<MatchHistoryPageData>();
    final first = _page(
      matches: [_entry('11111111-1111-4111-8111-111111111111')],
      nextCursor: 'cursor-1',
    );
    final api = _FakeMatchHistoryApi()
      ..onFetch = (cursor) =>
          cursor == null ? Future.value(first) : pending.future;
    final controller = MatchHistoryController(api: api);
    await controller.load();

    final firstLoadMore = controller.loadMore();
    final secondLoadMore = controller.loadMore();

    expect(controller.isLoadingMore, isTrue);
    expect(api.cursors, [null, 'cursor-1']);
    pending.complete(_page(matches: const [], nextCursor: null));
    await Future.wait([firstLoadMore, secondLoadMore]);

    expect(controller.isLoadingMore, isFalse);
    expect(api.cursors, [null, 'cursor-1']);
  });

  test(
    'a load-more ApiError preserves loaded data and remains retryable',
    () async {
      const error = ApiError(code: 'offline', message: '网络不可用');
      final first = _page(
        matches: [_entry('11111111-1111-4111-8111-111111111111')],
        nextCursor: 'cursor-1',
        wins: 1,
      );
      final recovered = _page(
        matches: [_entry('22222222-2222-4222-8222-222222222222')],
        nextCursor: null,
        wins: 2,
      );
      var call = 0;
      final api = _FakeMatchHistoryApi()
        ..onFetch = (_) => switch (call++) {
          0 => Future.value(first),
          1 => Future.error(error),
          _ => Future.value(recovered),
        };
      final controller = MatchHistoryController(api: api);
      await controller.load();

      await controller.loadMore();

      expect(controller.loadMoreError, same(error));
      expect(controller.matches, orderedEquals(first.matches));
      expect(controller.statistics, same(first.statistics));
      expect(controller.hasMore, isTrue);

      await controller.retry();

      expect(controller.loadMoreError, isNull);
      expect(
        controller.matches,
        orderedEquals([...first.matches, ...recovered.matches]),
      );
      expect(controller.statistics, same(recovered.statistics));
      expect(controller.hasMore, isFalse);
      expect(api.cursors, [null, 'cursor-1', 'cursor-1']);
    },
  );

  test(
    'a null next cursor stops further page requests after data exists',
    () async {
      final page = _page(
        matches: [_entry('11111111-1111-4111-8111-111111111111')],
        nextCursor: null,
      );
      final api = _FakeMatchHistoryApi()..onFetch = (_) async => page;
      final controller = MatchHistoryController(api: api);

      await controller.load();
      await controller.loadMore();

      expect(controller.matches, orderedEquals(page.matches));
      expect(controller.hasMore, isFalse);
      expect(api.cursors, [null]);
    },
  );

  test(
    'a programming error from the API is not converted to an ApiError',
    () async {
      final api = _FakeMatchHistoryApi()
        ..onFetch = (_) => Future.error(StateError('unexpected failure'));
      final controller = MatchHistoryController(api: api);

      await expectLater(controller.load(), throwsStateError);

      expect(controller.initialError, isNull);
      expect(controller.isInitialLoading, isFalse);
    },
  );

  test(
    'dispose prevents a late page from mutating state or notifying',
    () async {
      final pending = Completer<MatchHistoryPageData>();
      final api = _FakeMatchHistoryApi()..onFetch = (_) => pending.future;
      final controller = MatchHistoryController(api: api);
      var notifications = 0;
      controller.addListener(() => notifications += 1);

      final loading = controller.load();
      final beforeDispose = notifications;
      controller.dispose();
      pending.complete(
        _page(matches: [_entry('11111111-1111-4111-8111-111111111111')]),
      );
      await loading;

      expect(notifications, beforeDispose);
      expect(controller.statistics, isNull);
      expect(controller.matches, isEmpty);
      expect(controller.isInitialLoading, isTrue);
    },
  );
}

MatchHistoryPageData _page({
  required List<MatchHistoryEntry> matches,
  String? nextCursor,
  int wins = 0,
}) {
  return MatchHistoryPageData(
    statistics: MatchHistoryStatistics(
      validMatches: wins,
      wins: wins,
      losses: 0,
      draws: 0,
      winRate: wins == 0 ? 0 : 1,
    ),
    matches: matches,
    nextCursor: nextCursor,
  );
}

MatchHistoryEntry _entry(String id) {
  return MatchHistoryEntry(
    id: id,
    outcome: MatchOutcome.win,
    opponentNickname: '对手昵称',
    color: GomokuColor.black,
    finishedAt: DateTime.utc(2026, 8, 25),
    moveCount: 24,
  );
}

final class _FakeMatchHistoryApi implements MatchHistoryApi {
  Future<MatchHistoryPageData> Function(String? cursor) onFetch = (_) =>
      Future.error(StateError('Unexpected fetch'));
  final cursors = <String?>[];

  @override
  Future<MatchHistoryPageData> fetchPage({String? cursor, int limit = 20}) {
    cursors.add(cursor);
    return onFetch(cursor);
  }
}
