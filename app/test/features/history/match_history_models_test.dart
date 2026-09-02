import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/features/gomoku/gomoku_models.dart';
import 'package:gamebox/features/history/match_history_models.dart';

void main() {
  const firstMatchId = '11111111-1111-4111-8111-111111111111';
  const secondMatchId = '22222222-2222-4222-8222-222222222222';
  const thirdMatchId = '33333333-3333-4333-8333-333333333333';
  const fourthMatchId = '44444444-4444-4444-8444-444444444444';

  test('decodes exact immutable history data with every outcome and color', () {
    final page = MatchHistoryPageData.fromEnvelope(
      _validEnvelope(
        matches: [
          _match(id: firstMatchId, outcome: 'win', color: 'black'),
          _match(id: secondMatchId, outcome: 'loss', color: 'white'),
          _match(id: thirdMatchId, outcome: 'draw', color: 'black'),
          _match(id: fourthMatchId, outcome: 'abandoned', color: 'white'),
        ],
      ),
    );

    expect(page.statistics.validMatches, 3);
    expect(page.statistics.wins, 1);
    expect(page.statistics.losses, 1);
    expect(page.statistics.draws, 1);
    expect(page.statistics.winRate, 1 / 3);
    expect(page.nextCursor, isNull);
    expect(page.matches.map((entry) => entry.outcome), [
      MatchOutcome.win,
      MatchOutcome.loss,
      MatchOutcome.draw,
      MatchOutcome.abandoned,
    ]);
    expect(page.matches.first.color, GomokuColor.black);
    expect(page.matches[1].color, GomokuColor.white);
    expect(page.matches.first.finishedAt, DateTime.utc(2026, 8, 25, 12));
    expect(page.matches.first.finishedAt.isUtc, isTrue);
    expect(page.matches.first.moveCount, 42);
    expect(() => page.matches.clear(), throwsUnsupportedError);
  });

  test('retains a non-null opaque next cursor', () {
    final page = MatchHistoryPageData.fromEnvelope(
      _validEnvelope(nextCursor: 'a+/= cursor?still-opaque'),
    );

    expect(page.nextCursor, 'a+/= cursor?still-opaque');
  });

  test('decodes Chinese checkers history without an RPS format', () {
    final page = MatchHistoryPageData.fromEnvelope(
      _validEnvelope(),
      game: MatchHistoryGame.chineseCheckers,
    );

    expect(MatchHistoryGame.chineseCheckers.id, 'chinese_checkers');
    expect(MatchHistoryGame.chineseCheckers.pageTitle, '跳棋战绩');
    expect(MatchHistoryGame.chineseCheckers.countUnit, '手');
    expect(page.matches.single.color, GomokuColor.black);
    expect(page.matches.single.rpsFormat, isNull);
  });

  test('rejects every non-exact history object layer', () {
    final valid = _validEnvelope();
    final cases = <String, Map<String, Object?>>{
      'root extra': {...valid, 'extra': true},
      'root missing': {
        'statistics': valid['statistics'],
        'matches': valid['matches'],
      },
      'statistics extra': {
        ...valid,
        'statistics': {
          ...valid['statistics']! as Map<String, Object?>,
          'extra': 0,
        },
      },
      'statistics missing': {
        ...valid,
        'statistics': {'validMatches': 3, 'wins': 1, 'losses': 1, 'draws': 1},
      },
      'entry extra': {
        ...valid,
        'matches': [
          {..._match(id: firstMatchId), 'extra': 0},
        ],
      },
      'entry missing': {
        ...valid,
        'matches': [
          {
            'id': firstMatchId,
            'outcome': 'win',
            'opponentNickname': '棋手',
            'color': 'black',
            'finishedAt': DateTime.utc(2026, 8, 25, 12).millisecondsSinceEpoch,
          },
        ],
      },
    };

    for (final entry in cases.entries) {
      expect(
        () => MatchHistoryPageData.fromEnvelope(entry.value),
        throwsFormatException,
        reason: entry.key,
      );
    }
  });

  test('rejects invalid history values and unsafe numeric boundaries', () {
    final valid = _validEnvelope();
    final cases = <String, Map<String, Object?>>{
      'invalid UUID': _withMatch(valid, {..._match(id: 'not-a-uuid')}),
      'invalid nickname': _withMatch(valid, {
        ..._match(id: firstMatchId, nickname: ' x '),
      }),
      'invalid color': _withMatch(valid, {
        ..._match(id: firstMatchId, color: 'red'),
      }),
      'invalid outcome': _withMatch(valid, {
        ..._match(id: firstMatchId, outcome: 'cancelled'),
      }),
      'negative move count': _withMatch(valid, {
        ..._match(id: firstMatchId, moveCount: -1),
      }),
      'overflow finished at': _withMatch(valid, {
        ..._match(id: firstMatchId, finishedAt: 9007199254740991),
      }),
      'negative valid matches': _withStatistics(valid, {
        ..._statistics(),
        'validMatches': -1,
      }),
      'negative wins': _withStatistics(valid, {..._statistics(), 'wins': -1}),
      'negative losses': _withStatistics(valid, {
        ..._statistics(),
        'losses': -1,
      }),
      'negative draws': _withStatistics(valid, {..._statistics(), 'draws': -1}),
      'unsafe count': _withStatistics(valid, {
        ..._statistics(),
        'validMatches': 9007199254740992,
      }),
      'not finite win rate': _withStatistics(valid, {
        ..._statistics(),
        'winRate': double.nan,
      }),
      'win rate above one': _withStatistics(valid, {
        ..._statistics(),
        'winRate': 1.000001,
      }),
      'win rate below zero': _withStatistics(valid, {
        ..._statistics(),
        'winRate': -0.000001,
      }),
      'outcomes do not add up': _withStatistics(valid, {
        'validMatches': 3,
        'wins': 1,
        'losses': 0,
        'draws': 1,
        'winRate': 1 / 3,
      }),
      'wrong nonzero win rate': _withStatistics(valid, {
        'validMatches': 3,
        'wins': 1,
        'losses': 1,
        'draws': 1,
        'winRate': 0.5,
      }),
      'zero denominator nonzero rate': _withStatistics(valid, {
        'validMatches': 0,
        'wins': 0,
        'losses': 0,
        'draws': 0,
        'winRate': 1,
      }),
      'near-safe counts exceed valid matches': _withStatistics(valid, {
        'validMatches': 9007199254740991,
        'wins': 9007199254740991,
        'losses': 1,
        'draws': 0,
        'winRate': 1,
      }),
      'duplicate match ID': {
        ...valid,
        'matches': [
          _match(id: firstMatchId),
          _match(id: firstMatchId, outcome: 'loss', color: 'white'),
        ],
      },
    };

    for (final entry in cases.entries) {
      expect(
        () => MatchHistoryPageData.fromEnvelope(entry.value),
        throwsFormatException,
        reason: entry.key,
      );
    }
  });
}

Map<String, Object?> _validEnvelope({
  List<Map<String, Object?>>? matches,
  String? nextCursor,
}) => {
  'statistics': _statistics(),
  'matches': matches ?? [_match(id: '11111111-1111-4111-8111-111111111111')],
  'nextCursor': nextCursor,
};

Map<String, Object?> _statistics() => {
  'validMatches': 3,
  'wins': 1,
  'losses': 1,
  'draws': 1,
  'winRate': 1 / 3,
};

Map<String, Object?> _match({
  required String id,
  String outcome = 'win',
  String nickname = '棋手',
  String color = 'black',
  int? finishedAt,
  int moveCount = 42,
}) => {
  'id': id,
  'outcome': outcome,
  'opponentNickname': nickname,
  'color': color,
  'finishedAt':
      finishedAt ?? DateTime.utc(2026, 8, 25, 12).millisecondsSinceEpoch,
  'moveCount': moveCount,
};

Map<String, Object?> _withMatch(
  Map<String, Object?> envelope,
  Map<String, Object?> match,
) => {
  ...envelope,
  'matches': [match],
};

Map<String, Object?> _withStatistics(
  Map<String, Object?> envelope,
  Map<String, Object?> statistics,
) => {...envelope, 'statistics': statistics};
