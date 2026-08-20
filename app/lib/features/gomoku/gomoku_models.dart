import '../../core/api/strict_json.dart';

const gomokuGameId = 'gomoku';

enum GomokuColor { black, white }

enum OpponentAvailability { idle, busy }

enum OpponentPresence { online, offline }

sealed class GomokuStatus {
  const GomokuStatus();

  factory GomokuStatus.fromEnvelope(Map<String, Object?> envelope) {
    final state = envelope['state'];
    if (state == 'idle' && hasExactJsonKeys(envelope, const {'state'})) {
      return const GomokuIdleStatus();
    }
    if (state != 'active' ||
        !hasExactJsonKeys(envelope, const {'state', 'match'})) {
      throw const FormatException('Invalid gomoku status');
    }
    return GomokuActiveStatus(
      match: GomokuActiveMatch.fromJson(_object(envelope['match'])),
    );
  }
}

final class GomokuIdleStatus extends GomokuStatus {
  const GomokuIdleStatus();
}

final class GomokuActiveStatus extends GomokuStatus {
  const GomokuActiveStatus({required this.match});

  final GomokuActiveMatch match;
}

final class GomokuActiveMatch {
  const GomokuActiveMatch({
    required this.id,
    required this.opponent,
    required this.color,
    required this.revision,
  });

  factory GomokuActiveMatch.fromJson(Map<String, Object?> json) {
    if (!hasExactJsonKeys(json, const {
      'id',
      'opponent',
      'color',
      'revision',
    })) {
      throw const FormatException('Invalid active match');
    }
    final id = _uuid(json['id']);
    final opponent = GomokuOpponentIdentity.fromJson(_object(json['opponent']));
    final color = switch (json['color']) {
      'black' => GomokuColor.black,
      'white' => GomokuColor.white,
      _ => throw const FormatException('Invalid match color'),
    };
    final revision = json['revision'];
    if (revision is! int || revision < 0) {
      throw const FormatException('Invalid match revision');
    }
    return GomokuActiveMatch(
      id: id,
      opponent: opponent,
      color: color,
      revision: revision,
    );
  }

  final String id;
  final GomokuOpponentIdentity opponent;
  final GomokuColor color;
  final int revision;
}

final class GomokuOpponentIdentity {
  const GomokuOpponentIdentity({required this.id, required this.nickname});

  factory GomokuOpponentIdentity.fromJson(Map<String, Object?> json) {
    if (!hasExactJsonKeys(json, const {'id', 'nickname'})) {
      throw const FormatException('Invalid opponent');
    }
    return GomokuOpponentIdentity(
      id: _uuid(json['id']),
      nickname: _nickname(json['nickname']),
    );
  }

  final String id;
  final String nickname;
}

final class GomokuOpponent {
  const GomokuOpponent({
    required this.id,
    required this.nickname,
    required this.availability,
    required this.presence,
  });

  factory GomokuOpponent.fromJson(Map<String, Object?> json) {
    if (!hasExactJsonKeys(json, const {
      'id',
      'nickname',
      'availability',
      'presence',
    })) {
      throw const FormatException('Invalid opponent');
    }
    final availability = switch (json['availability']) {
      'idle' => OpponentAvailability.idle,
      'busy' => OpponentAvailability.busy,
      _ => throw const FormatException('Invalid opponent availability'),
    };
    final presence = switch (json['presence']) {
      'online' => OpponentPresence.online,
      'offline' => OpponentPresence.offline,
      _ => throw const FormatException('Invalid opponent presence'),
    };
    return GomokuOpponent(
      id: _uuid(json['id']),
      nickname: _nickname(json['nickname']),
      availability: availability,
      presence: presence,
    );
  }

  static List<GomokuOpponent> listFromEnvelope(Map<String, Object?> envelope) {
    if (!hasExactJsonKeys(envelope, const {'opponents'})) {
      throw const FormatException('Invalid opponents response');
    }
    final rows = envelope['opponents'];
    if (rows is! List<Object?>) {
      throw const FormatException('Invalid opponents response');
    }
    return List<GomokuOpponent>.unmodifiable(
      rows.map((row) => GomokuOpponent.fromJson(_object(row))),
    );
  }

  final String id;
  final String nickname;
  final OpponentAvailability availability;
  final OpponentPresence presence;
}

final class CreatedGomokuMatch {
  const CreatedGomokuMatch({required this.id, required this.gameId});

  factory CreatedGomokuMatch.fromEnvelope(Map<String, Object?> envelope) {
    if (!hasExactJsonKeys(envelope, const {'match'})) {
      throw const FormatException('Invalid created match');
    }
    final match = _object(envelope['match']);
    if (!hasExactJsonKeys(match, const {'id', 'gameId', 'state'}) ||
        match['gameId'] != gomokuGameId ||
        match['state'] != 'active') {
      throw const FormatException('Invalid created match');
    }
    return CreatedGomokuMatch(id: _uuid(match['id']), gameId: gomokuGameId);
  }

  final String id;
  final String gameId;
}

final class GomokuLaunchTicket {
  const GomokuLaunchTicket({
    required this.matchId,
    required this.gameId,
    required this.launchTicket,
    required this.expiresAt,
  });

  factory GomokuLaunchTicket.fromEnvelope(Map<String, Object?> envelope) {
    if (!hasExactJsonKeys(envelope, const {
      'matchId',
      'gameId',
      'launchTicket',
      'expiresAt',
    })) {
      throw const FormatException('Invalid launch ticket');
    }
    final gameId = envelope['gameId'];
    final credential = envelope['launchTicket'];
    final timestamp = envelope['expiresAt'];
    if (gameId != gomokuGameId ||
        credential is! String ||
        !_isCredential(credential) ||
        timestamp is! int ||
        timestamp <= 0) {
      throw const FormatException('Invalid launch ticket');
    }
    late final DateTime expiresAt;
    try {
      expiresAt = DateTime.fromMillisecondsSinceEpoch(timestamp, isUtc: true);
    } on RangeError {
      throw const FormatException('Invalid launch ticket');
    }
    return GomokuLaunchTicket(
      matchId: _uuid(envelope['matchId']),
      gameId: gomokuGameId,
      launchTicket: credential,
      expiresAt: expiresAt,
    );
  }

  final String matchId;
  final String gameId;
  final String launchTicket;
  final DateTime expiresAt;

  @override
  String toString() =>
      'GomokuLaunchTicket(matchId: $matchId, gameId: $gameId, '
      'launchTicket: <redacted>, expiresAt: $expiresAt)';
}

bool isCanonicalGameboxUuid(String value) =>
    value != '00000000-0000-0000-0000-000000000000' &&
    _canonicalUuid.hasMatch(value);

final RegExp _canonicalUuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

String _uuid(Object? value) {
  if (value is! String || !isCanonicalGameboxUuid(value)) {
    throw const FormatException('Invalid UUID');
  }
  return value;
}

String _nickname(Object? value) {
  if (value is! String) {
    throw const FormatException('Invalid nickname');
  }
  final runes = value.runes;
  if (value != value.trim() ||
      runes.length < 2 ||
      runes.length > 16 ||
      runes.any((rune) => rune < 0x20 || rune == 0x7f)) {
    throw const FormatException('Invalid nickname');
  }
  return value;
}

Map<String, Object?> _object(Object? value) {
  if (value is! Map<String, Object?>) {
    throw const FormatException('Expected object');
  }
  return value;
}

bool _isCredential(String value) =>
    value.isNotEmpty &&
    value.length <= 4096 &&
    value.codeUnits.every((unit) => unit >= 0x21 && unit <= 0x7e);
