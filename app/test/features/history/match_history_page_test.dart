import 'dart:async';
import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/core/api/api_error.dart';
import 'package:gamebox/design_system/components/gamebox_async_panel.dart';
import 'package:gamebox/design_system/gamebox_theme.dart';
import 'package:gamebox/features/gomoku/gomoku_models.dart';
import 'package:gamebox/features/history/match_history_api.dart';
import 'package:gamebox/features/history/match_history_controller.dart';
import 'package:gamebox/features/history/match_history_models.dart';
import 'package:gamebox/features/history/match_history_page.dart';
import 'package:gamebox/features/rps/rps_models.dart';

void main() {
  testWidgets('initial request keeps a stable loading panel visible', (
    tester,
  ) async {
    final pending = Completer<MatchHistoryPageData>();
    addTearDown(() {
      if (!pending.isCompleted) pending.complete(_emptyPage());
    });
    final api = _FakeMatchHistoryApi()..responses.add((_) => pending.future);

    await _pumpPage(tester, api);
    await tester.pump();

    expect(find.byKey(const Key('match-history-page')), findsOneWidget);
    expect(find.bySemanticsIdentifier('match-history-loading'), findsOneWidget);
    expect(find.byType(GameboxAsyncPanel), findsOneWidget);
    expect(find.text('正在加载战绩'), findsOneWidget);
    expect(find.byKey(const Key('match-history-statistics')), findsNothing);
  });

  testWidgets('empty response shows statistics and the explicit empty state', (
    tester,
  ) async {
    final api = _FakeMatchHistoryApi()
      ..responses.add((_) async => _emptyPage());

    await _pumpPage(tester, api);
    await _flush(tester);

    expect(find.byKey(const Key('match-history-statistics')), findsOneWidget);
    expect(find.text('胜率 0%'), findsOneWidget);
    expect(find.text('有效对局 0'), findsOneWidget);
    expect(find.bySemanticsIdentifier('match-history-empty'), findsOneWidget);
    expect(find.text('还没有已结束的对局'), findsOneWidget);
    expect(find.byKey(const Key('match-history-list')), findsNothing);
    expect(find.byKey(const Key('match-history-load-more')), findsNothing);
  });

  testWidgets('initial failure stays inline and retry replaces it with data', (
    tester,
  ) async {
    final api = _FakeMatchHistoryApi()
      ..responses.add(
        (_) async => throw const ApiError(
          code: 'network_error',
          message: '网络连接失败，请稍后重试',
        ),
      )
      ..responses.add((_) async => _emptyPage());

    await _pumpPage(tester, api);
    await _flush(tester);

    expect(find.bySemanticsIdentifier('match-history-error'), findsOneWidget);
    expect(find.byType(GameboxAsyncPanel), findsOneWidget);
    expect(find.text('网络连接失败，请稍后重试'), findsOneWidget);
    expect(find.bySemanticsIdentifier('retry-match-history'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(GameboxAsyncPanel),
        matching: find.byKey(const Key('retry-match-history')),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('retry-match-history')));
    await _flush(tester);

    expect(find.byKey(const Key('match-history-empty')), findsOneWidget);
    expect(find.byKey(const Key('match-history-error')), findsNothing);
  });

  testWidgets(
    'RPS page shows its title, format and round count without color',
    (tester) async {
      final api = _FakeMatchHistoryApi()
        ..responses.add(
          (_) async => MatchHistoryPageData(
            statistics: _statistics(1),
            matches: [
              _entry(
                '11111111-1111-4111-8111-111111111111',
                outcome: MatchOutcome.win,
                nickname: '猜拳玩家',
                color: GomokuColor.black,
                hour: 20,
                moveCount: 3,
                rpsFormat: RpsFormat.bestOfThree,
              ),
            ],
            nextCursor: null,
          ),
        );

      await _pumpPage(tester, api, game: MatchHistoryGame.rps);
      await _flush(tester);

      expect(find.text('石头剪刀布战绩'), findsOneWidget);
      expect(find.text('三局两胜'), findsOneWidget);
      expect(find.text('3 局'), findsOneWidget);
      expect(find.text('黑方'), findsNothing);
      expect(find.text('3 手'), findsNothing);
      expect(api.games, [MatchHistoryGame.rps]);
    },
  );

  testWidgets('Chinese checkers page shows turn order and move count', (
    tester,
  ) async {
    final api = _FakeMatchHistoryApi()
      ..responses.add(
        (_) async => MatchHistoryPageData(
          statistics: _statistics(1),
          matches: [
            _entry(
              '11111111-1111-4111-8111-111111111111',
              outcome: MatchOutcome.win,
              nickname: '跳棋玩家',
              color: GomokuColor.black,
              hour: 20,
              moveCount: 27,
            ),
            _entry(
              '22222222-2222-4222-8222-222222222222',
              outcome: MatchOutcome.loss,
              nickname: '另一位跳棋玩家',
              color: GomokuColor.white,
              hour: 19,
              moveCount: 28,
            ),
          ],
          nextCursor: null,
        ),
      );

    await _pumpPage(tester, api, game: MatchHistoryGame.chineseCheckers);
    await _flush(tester);

    expect(find.text('跳棋战绩'), findsOneWidget);
    expect(find.text('先手'), findsOneWidget);
    expect(find.text('后手'), findsOneWidget);
    expect(find.text('27 手'), findsOneWidget);
    expect(find.text('28 手'), findsOneWidget);
    expect(find.text('黑方'), findsNothing);
    expect(api.games, [MatchHistoryGame.chineseCheckers]);
  });

  testWidgets(
    'data rows expose compact result status and metadata without tap',
    (tester) async {
      final entries = [
        _entry(
          '11111111-1111-4111-8111-111111111111',
          outcome: MatchOutcome.win,
          nickname: '棋手乙',
          color: GomokuColor.black,
          hour: 20,
          minute: 30,
          moveCount: 57,
        ),
        _entry(
          '22222222-2222-4222-8222-222222222222',
          outcome: MatchOutcome.loss,
          nickname: '棋手丙',
          color: GomokuColor.white,
          hour: 19,
          moveCount: 42,
        ),
        _entry(
          '33333333-3333-4333-8333-333333333333',
          outcome: MatchOutcome.draw,
          nickname: '棋手丁',
          color: GomokuColor.black,
          hour: 18,
          moveCount: 80,
        ),
        _entry(
          '44444444-4444-4444-8444-444444444444',
          outcome: MatchOutcome.abandoned,
          nickname: '棋手戊',
          color: GomokuColor.white,
          hour: 17,
          moveCount: 12,
        ),
      ];
      final api = _FakeMatchHistoryApi()
        ..responses.add(
          (_) async => MatchHistoryPageData(
            statistics: const MatchHistoryStatistics(
              validMatches: 3,
              wins: 1,
              losses: 1,
              draws: 1,
              winRate: 1 / 3,
            ),
            matches: entries,
            nextCursor: null,
          ),
        );

      await _pumpPage(tester, api);
      await _flush(tester);

      expect(find.byKey(const Key('match-history-list')), findsOneWidget);
      expect(find.text('胜率 33%'), findsOneWidget);
      expect(find.text('有效对局 3'), findsOneWidget);
      expect(find.text('胜 1'), findsOneWidget);
      expect(find.text('负 1'), findsOneWidget);
      expect(find.text('和 1'), findsOneWidget);

      final scheme = Theme.of(
        tester.element(find.byKey(const Key('match-history-page'))),
      ).colorScheme;
      final expectedColors = {
        entries[0].id: scheme.primaryContainer,
        entries[1].id: scheme.surfaceContainerHighest,
        entries[2].id: scheme.tertiaryContainer,
        entries[3].id: scheme.surfaceContainer,
      };
      final expectedLabels = {
        entries[0].id: '胜利',
        entries[1].id: '失利',
        entries[2].id: '平局',
        entries[3].id: '作废',
      };
      final expectedIcons = {
        entries[0].id: Icons.check_rounded,
        entries[1].id: Icons.close_rounded,
        entries[2].id: Icons.remove_rounded,
        entries[3].id: Icons.block_rounded,
      };
      for (final entry in entries) {
        final finder = find.byKey(Key('match-history-entry-${entry.id}'));
        await tester.scrollUntilVisible(
          finder,
          300,
          scrollable: find.byType(Scrollable),
        );
        expect(finder, findsOneWidget);
        expect(
          tester
              .getSemantics(finder)
              .getSemanticsData()
              .hasAction(SemanticsAction.tap),
          isFalse,
        );
        final outcomeFinder = find.descendant(
          of: finder,
          matching: find.byKey(Key('match-history-entry-${entry.id}-outcome')),
        );
        expect(outcomeFinder, findsOneWidget);
        expect(
          tester.widget<ColoredBox>(outcomeFinder).color,
          expectedColors[entry.id],
        );
        expect(
          find.descendant(
            of: finder,
            matching: find.text(expectedLabels[entry.id]!),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: finder,
            matching: find.byIcon(expectedIcons[entry.id]!),
          ),
          findsOneWidget,
        );
      }
      expect(find.byType(Chip), findsNothing);
      expect(
        tester.getSemantics(
          find.byKey(
            const Key(
              'match-history-entry-11111111-1111-4111-8111-111111111111',
            ),
          ),
        ),
        matchesSemantics(
          identifier:
              'match-history-entry-11111111-1111-4111-8111-111111111111',
          label: '胜利，对手棋手乙，黑方，结束于 Aug 25, 2026 20:30，57 手',
        ),
      );
      expect(find.byType(RefreshIndicator), findsNothing);
    },
  );

  testWidgets('near-bottom scroll loads more and preserves data on retry', (
    tester,
  ) async {
    final more = Completer<MatchHistoryPageData>();
    final retryPage = MatchHistoryPageData(
      statistics: _statistics(19),
      matches: [
        _entry(
          '99999999-9999-4999-8999-999999999999',
          outcome: MatchOutcome.win,
          nickname: '新对手',
          color: GomokuColor.black,
          hour: 1,
          moveCount: 9,
        ),
      ],
      nextCursor: null,
    );
    final initialEntries = List.generate(
      18,
      (index) => _entry(
        '${(index + 1).toString().padLeft(8, '0')}-1111-4111-8111-111111111111',
        outcome: MatchOutcome.win,
        nickname: '对手${index.toString().padLeft(2, '0')}',
        color: GomokuColor.black,
        hour: 20,
        moveCount: index,
      ),
    );
    final api = _FakeMatchHistoryApi()
      ..responses.add(
        (_) async => MatchHistoryPageData(
          statistics: _statistics(18),
          matches: initialEntries,
          nextCursor: 'older-page',
        ),
      )
      ..responses.add((cursor) => more.future)
      ..responses.add((_) async => retryPage);

    await _pumpPage(tester, api);
    await _flush(tester);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -5000));
    await tester.pump();

    expect(api.cursors, [null, 'older-page']);
    expect(
      find.bySemanticsIdentifier('match-history-load-more'),
      findsOneWidget,
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    more.completeError(
      const ApiError(code: 'network_error', message: '无法加载更早的对局'),
    );
    await _flush(tester);

    expect(find.text('无法加载更早的对局'), findsOneWidget);
    expect(
      find.bySemanticsIdentifier('retry-match-history-more'),
      findsOneWidget,
    );
    await tester.ensureVisible(
      find.byKey(const Key('retry-match-history-more')),
    );
    await tester.pump();
    expect(api.cursors, [null, 'older-page']);
    await tester.tap(find.byKey(const Key('retry-match-history-more')));
    await _flush(tester);

    expect(api.cursors, [null, 'older-page', 'older-page']);
    expect(
      find.byKey(
        const Key('match-history-entry-99999999-9999-4999-8999-999999999999'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('match-history-load-more')), findsNothing);
  });

  testWidgets('history rows are built lazily as they enter the viewport', (
    tester,
  ) async {
    final entries = List.generate(
      100,
      (index) => _entry(
        '${(index + 1).toString().padLeft(8, '0')}-1111-4111-8111-111111111111',
        outcome: MatchOutcome.win,
        nickname: '对手$index',
        color: GomokuColor.black,
        hour: 20,
        moveCount: index,
      ),
    );
    final api = _FakeMatchHistoryApi()
      ..responses.add(
        (_) async => MatchHistoryPageData(
          statistics: _statistics(entries.length),
          matches: entries,
          nextCursor: null,
        ),
      );

    await _pumpPage(tester, api);
    await _flush(tester);

    expect(
      find.byKey(Key('match-history-entry-${entries.first.id}')),
      findsOneWidget,
    );
    expect(
      find.byKey(Key('match-history-entry-${entries.last.id}')),
      findsNothing,
    );

    await tester.scrollUntilVisible(
      find.byKey(Key('match-history-entry-${entries.last.id}')),
      500,
      scrollable: find.byType(Scrollable),
    );

    expect(
      find.byKey(Key('match-history-entry-${entries.last.id}')),
      findsOneWidget,
    );
  });

  for (final brightness in Brightness.values) {
    testWidgets('320dp ${brightness.name} layout wraps a long nickname', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 640);
      addTearDown(tester.view.reset);
      final api = _FakeMatchHistoryApi()
        ..responses.add(
          (_) async => MatchHistoryPageData(
            statistics: _statistics(1),
            matches: [
              _entry(
                '11111111-1111-4111-8111-111111111111',
                outcome: MatchOutcome.win,
                nickname: '一位名字非常非常长的对手',
                color: GomokuColor.white,
                hour: 20,
                moveCount: 57,
              ),
            ],
            nextCursor: null,
          ),
        );

      await _pumpPage(tester, api, dark: brightness == Brightness.dark);
      await _flush(tester);

      final page = find.byKey(const Key('match-history-page'));
      expect(Theme.of(tester.element(page)).brightness, brightness);
      expect(find.text('一位名字非常非常长的对手'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}

Future<void> _pumpPage(
  WidgetTester tester,
  MatchHistoryApi api, {
  bool dark = false,
  MatchHistoryGame game = MatchHistoryGame.gomoku,
}) {
  return tester.pumpWidget(
    MaterialApp(
      theme: GameboxTheme.light(),
      darkTheme: GameboxTheme.dark(),
      themeMode: dark ? ThemeMode.dark : ThemeMode.light,
      home: MatchHistoryPage(
        controller: MatchHistoryController(api: api, game: game),
      ),
    ),
  );
}

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

MatchHistoryPageData _emptyPage() => MatchHistoryPageData(
  statistics: _statistics(0),
  matches: const [],
  nextCursor: null,
);

MatchHistoryStatistics _statistics(int wins) => MatchHistoryStatistics(
  validMatches: wins,
  wins: wins,
  losses: 0,
  draws: 0,
  winRate: wins == 0 ? 0 : 1,
);

MatchHistoryEntry _entry(
  String id, {
  required MatchOutcome outcome,
  required String nickname,
  required GomokuColor color,
  required int hour,
  int minute = 0,
  required int moveCount,
  RpsFormat? rpsFormat,
}) => MatchHistoryEntry(
  id: id,
  outcome: outcome,
  opponentNickname: nickname,
  color: color,
  finishedAt: DateTime(2026, 8, 25, hour, minute).toUtc(),
  moveCount: moveCount,
  rpsFormat: rpsFormat,
);

final class _FakeMatchHistoryApi implements MatchHistoryApi {
  final responses = <Future<MatchHistoryPageData> Function(String? cursor)>[];
  final cursors = <String?>[];
  final games = <MatchHistoryGame>[];

  @override
  Future<MatchHistoryPageData> fetchPage({
    MatchHistoryGame game = MatchHistoryGame.gomoku,
    String? cursor,
    int limit = 20,
  }) {
    cursors.add(cursor);
    games.add(game);
    if (responses.isEmpty) {
      return Future.error(StateError('Unexpected history request'));
    }
    return responses.removeAt(0)(cursor);
  }
}
