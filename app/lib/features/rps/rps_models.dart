import '../../core/api/strict_json.dart';
import '../gomoku/gomoku_models.dart';

const rpsGameId = 'rps';

enum RpsFormat {
  singleRound('single_round', '一局定胜负'),
  bestOfThree('best_of_three', '三局两胜');

  const RpsFormat(this.wireValue, this.label);

  final String wireValue;
  final String label;

  static RpsFormat parse(Object? value) => switch (value) {
    'single_round' => RpsFormat.singleRound,
    'best_of_three' => RpsFormat.bestOfThree,
    _ => throw const FormatException('Invalid RPS format'),
  };
}

sealed class RpsStatus {
  const RpsStatus();

  factory RpsStatus.fromEnvelope(Map<String, Object?> envelope) {
    if (envelope['state'] == 'idle' &&
        hasExactJsonKeys(envelope, const {'state'})) {
      return const RpsIdleStatus();
    }
    if (envelope['state'] != 'active' ||
        !hasExactJsonKeys(envelope, const {'state', 'match'})) {
      throw const FormatException('Invalid RPS status');
    }
    final raw = envelope['match'];
    if (raw is! Map<String, Object?>) {
      throw const FormatException('Invalid RPS match');
    }
    return RpsActiveStatus(match: RpsActiveMatch.fromJson(raw));
  }
}

final class RpsIdleStatus extends RpsStatus {
  const RpsIdleStatus();
}

final class RpsActiveStatus extends RpsStatus {
  const RpsActiveStatus({required this.match});

  final RpsActiveMatch match;
}

final class RpsActiveMatch {
  const RpsActiveMatch({
    required this.id,
    required this.opponent,
    required this.revision,
    required this.format,
  });

  factory RpsActiveMatch.fromJson(Map<String, Object?> json) {
    if (!hasExactJsonKeys(json, const {
      'id',
      'opponent',
      'color',
      'revision',
      'format',
    })) {
      throw const FormatException('Invalid RPS match');
    }
    final id = json['id'];
    final opponent = json['opponent'];
    final revision = json['revision'];
    if (id is! String ||
        !isCanonicalGameboxUuid(id) ||
        opponent is! Map<String, Object?> ||
        revision is! int ||
        revision < 0 ||
        (json['color'] != 'black' && json['color'] != 'white')) {
      throw const FormatException('Invalid RPS match');
    }
    return RpsActiveMatch(
      id: id,
      opponent: GomokuOpponentIdentity.fromJson(opponent),
      revision: revision,
      format: RpsFormat.parse(json['format']),
    );
  }

  final String id;
  final GomokuOpponentIdentity opponent;
  final int revision;
  final RpsFormat format;
}

final class CreatedRpsMatch {
  const CreatedRpsMatch({required this.id, required this.format});

  factory CreatedRpsMatch.fromEnvelope(Map<String, Object?> envelope) {
    if (!hasExactJsonKeys(envelope, const {'match'})) {
      throw const FormatException('Invalid created RPS match');
    }
    final match = envelope['match'];
    if (match is! Map<String, Object?> ||
        !hasExactJsonKeys(match, const {'id', 'gameId', 'state', 'format'}) ||
        match['gameId'] != rpsGameId ||
        match['state'] != 'active' ||
        match['id'] is! String ||
        !isCanonicalGameboxUuid(match['id']! as String)) {
      throw const FormatException('Invalid created RPS match');
    }
    return CreatedRpsMatch(
      id: match['id']! as String,
      format: RpsFormat.parse(match['format']),
    );
  }

  final String id;
  final RpsFormat format;
}

final class RpsLaunchTicket {
  const RpsLaunchTicket({
    required this.matchId,
    required this.launchTicket,
    required this.expiresAt,
  });

  factory RpsLaunchTicket.fromEnvelope(Map<String, Object?> envelope) {
    if (!hasExactJsonKeys(envelope, const {
      'matchId',
      'gameId',
      'launchTicket',
      'expiresAt',
    })) {
      throw const FormatException('Invalid RPS launch ticket');
    }
    final matchId = envelope['matchId'];
    final token = envelope['launchTicket'];
    final expiresAt = envelope['expiresAt'];
    if (matchId is! String ||
        !isCanonicalGameboxUuid(matchId) ||
        envelope['gameId'] != rpsGameId ||
        token is! String ||
        token.isEmpty ||
        token.length > 4096 ||
        expiresAt is! int ||
        expiresAt <= 0) {
      throw const FormatException('Invalid RPS launch ticket');
    }
    return RpsLaunchTicket(
      matchId: matchId,
      launchTicket: token,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(expiresAt, isUtc: true),
    );
  }

  final String matchId;
  final String launchTicket;
  final DateTime expiresAt;
}
