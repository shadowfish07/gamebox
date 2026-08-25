import '../../core/api/strict_json.dart';
import '../gomoku/gomoku_models.dart';

const _maximumSafeInteger = 9007199254740991;

enum MatchOutcome { win, loss, draw, abandoned }

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
    return MatchHistoryStatistics(
      validMatches: _nonnegativeSafeInt(json['validMatches']),
      wins: _nonnegativeSafeInt(json['wins']),
      losses: _nonnegativeSafeInt(json['losses']),
      draws: _nonnegativeSafeInt(json['draws']),
      winRate: winRate.toDouble(),
    );
  }

  final int validMatches;
  final int wins;
  final int losses;
  final int draws;
  final double winRate;
}

final class MatchHistoryEntry {
  const MatchHistoryEntry({
    required this.id,
    required this.outcome,
    required this.opponentNickname,
    required this.color,
    required this.finishedAt,
    required this.moveCount,
  });

  factory MatchHistoryEntry.fromJson(Map<String, Object?> json) {
    if (!hasExactJsonKeys(json, const {
      'id',
      'outcome',
      'opponentNickname',
      'color',
      'finishedAt',
      'moveCount',
    })) {
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
    );
  }

  final String id;
  final MatchOutcome outcome;
  final String opponentNickname;
  final GomokuColor color;
  final DateTime finishedAt;
  final int moveCount;
}

final class MatchHistoryPageData {
  const MatchHistoryPageData({
    required this.statistics,
    required this.matches,
    required this.nextCursor,
  });

  factory MatchHistoryPageData.fromEnvelope(Map<String, Object?> envelope) {
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
        .map((row) => MatchHistoryEntry.fromJson(_object(row)))
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
