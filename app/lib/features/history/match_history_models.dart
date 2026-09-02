import '../../core/api/strict_json.dart';
import '../gomoku/gomoku_models.dart';
import '../rps/rps_models.dart';

const _maximumSafeInteger = 9007199254740991;

enum MatchOutcome { win, loss, draw, abandoned }

enum MatchHistoryGame {
  gomoku('gomoku', '五子棋', '手'),
  rps('rps', '石头剪刀布', '局');

  const MatchHistoryGame(this.id, this.title, this.countUnit);

  final String id;
  final String title;
  final String countUnit;

  String get pageTitle => '$title战绩';
  String get emptyMessage => '完成一局$title后，战绩会显示在这里。';
}

final class MatchHistoryStatistics {
  const MatchHistoryStatistics({
    required this.validMatches,
    required this.wins,
    required this.losses,
    required this.draws,
    required this.winRate,
  });

  factory MatchHistoryStatistics.fromJson(Map<String, Object?> json) {
    if (!hasExactJsonKeys(json, const {
      'validMatches',
      'wins',
      'losses',
      'draws',
      'winRate',
    })) {
      throw const FormatException('Invalid match history statistics');
    }
    final winRate = json['winRate'];
    if (winRate is! num || !winRate.isFinite || winRate < 0 || winRate > 1) {
      throw const FormatException('Invalid match history statistics');
    }
    final validMatches = _nonnegativeSafeInt(json['validMatches']);
    final wins = _nonnegativeSafeInt(json['wins']);
    final losses = _nonnegativeSafeInt(json['losses']);
    final draws = _nonnegativeSafeInt(json['draws']);
    final rate = winRate.toDouble();
    if (!_hasConsistentStatistics(
      validMatches: validMatches,
      wins: wins,
      losses: losses,
      draws: draws,
      winRate: rate,
    )) {
      throw const FormatException('Invalid match history statistics');
    }
    return MatchHistoryStatistics(
      validMatches: validMatches,
      wins: wins,
      losses: losses,
      draws: draws,
      winRate: rate,
    );
  }

  final int validMatches;
  final int wins;
  final int losses;
  final int draws;
  final double winRate;
}

bool _hasConsistentStatistics({
  required int validMatches,
  required int wins,
  required int losses,
  required int draws,
  required double winRate,
}) {
  if (validMatches == 0) {
    return wins == 0 && losses == 0 && draws == 0 && winRate == 0;
  }
  if (wins > validMatches) {
    return false;
  }
  final afterWins = validMatches - wins;
  if (losses > afterWins) {
    return false;
  }
  return draws == afterWins - losses && winRate == wins / validMatches;
}

final class MatchHistoryEntry {
  const MatchHistoryEntry({
    required this.id,
    required this.outcome,
    required this.opponentNickname,
    required this.color,
    required this.finishedAt,
    required this.moveCount,
    this.rpsFormat,
  });

  factory MatchHistoryEntry.fromJson(
    Map<String, Object?> json, {
    MatchHistoryGame game = MatchHistoryGame.gomoku,
  }) {
    final baseKeys = <String>{
      'id',
      'outcome',
      'opponentNickname',
      'color',
      'finishedAt',
      'moveCount',
    };
    if (game == MatchHistoryGame.rps) baseKeys.add('format');
    if (!hasExactJsonKeys(json, baseKeys)) {
      throw const FormatException('Invalid match history entry');
    }
    return MatchHistoryEntry(
      id: _uuid(json['id']),
      outcome: switch (json['outcome']) {
        'win' => MatchOutcome.win,
        'loss' => MatchOutcome.loss,
        'draw' => MatchOutcome.draw,
        'abandoned' => MatchOutcome.abandoned,
        _ => throw const FormatException('Invalid match outcome'),
      },
      opponentNickname: _nickname(json['opponentNickname']),
      color: switch (json['color']) {
        'black' => GomokuColor.black,
        'white' => GomokuColor.white,
        _ => throw const FormatException('Invalid match color'),
      },
      finishedAt: _timestamp(json['finishedAt']),
      moveCount: _nonnegativeSafeInt(json['moveCount']),
      rpsFormat: game == MatchHistoryGame.rps
          ? RpsFormat.parse(json['format'])
          : null,
    );
  }

  final String id;
  final MatchOutcome outcome;
  final String opponentNickname;
  final GomokuColor color;
  final DateTime finishedAt;
  final int moveCount;
  final RpsFormat? rpsFormat;
}

final class MatchHistoryPageData {
  const MatchHistoryPageData({
    required this.statistics,
    required this.matches,
    required this.nextCursor,
  });

  factory MatchHistoryPageData.fromEnvelope(
    Map<String, Object?> envelope, {
    MatchHistoryGame game = MatchHistoryGame.gomoku,
  }) {
    if (!hasExactJsonKeys(envelope, const {
      'statistics',
      'matches',
      'nextCursor',
    })) {
      throw const FormatException('Invalid match history response');
    }
    final rows = envelope['matches'];
    final cursor = envelope['nextCursor'];
    if (rows is! List<Object?> || (cursor != null && cursor is! String)) {
      throw const FormatException('Invalid match history response');
    }
    final matches = rows
        .map((row) => MatchHistoryEntry.fromJson(_object(row), game: game))
        .toList(growable: false);
    if (matches.map((match) => match.id).toSet().length != matches.length) {
      throw const FormatException('Duplicate match history entry');
    }
    return MatchHistoryPageData(
      statistics: MatchHistoryStatistics.fromJson(
        _object(envelope['statistics']),
      ),
      matches: List<MatchHistoryEntry>.unmodifiable(matches),
      nextCursor: cursor as String?,
    );
  }

  final MatchHistoryStatistics statistics;
  final List<MatchHistoryEntry> matches;
  final String? nextCursor;
}

int _nonnegativeSafeInt(Object? value) {
  if (value is! int || value < 0 || value > _maximumSafeInteger) {
    throw const FormatException('Invalid nonnegative count');
  }
  return value;
}

DateTime _timestamp(Object? value) {
  if (value is! int || value.abs() > _maximumSafeInteger) {
    throw const FormatException('Invalid match finish time');
  }
  try {
    return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
  } on RangeError {
    throw const FormatException('Invalid match finish time');
  }
}

String _uuid(Object? value) {
  if (value is! String || !isCanonicalGameboxUuid(value)) {
    throw const FormatException('Invalid match ID');
  }
  return value;
}

String _nickname(Object? value) {
  if (value is! String) {
    throw const FormatException('Invalid opponent nickname');
  }
  final runes = value.runes;
  if (value != value.trim() ||
      runes.length < 2 ||
      runes.length > 16 ||
      runes.any((rune) => rune < 0x20 || rune == 0x7f)) {
    throw const FormatException('Invalid opponent nickname');
  }
  return value;
}

Map<String, Object?> _object(Object? value) {
  if (value is! Map<String, Object?>) {
    throw const FormatException('Expected object');
  }
  return value;
}
