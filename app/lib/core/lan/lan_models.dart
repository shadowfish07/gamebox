import 'dart:convert';
import 'dart:typed_data';

import '../api/strict_json.dart';
import 'private_ipv4.dart';

final RegExp canonicalLanUuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
final RegExp canonicalLanCredential = RegExp(r'^[A-Za-z0-9_-]{43}$');

bool isCanonicalLanUuid(String value) =>
    value != '00000000-0000-0000-0000-000000000000' &&
    canonicalLanUuid.hasMatch(value);

bool isCanonicalLanCredential(String value) {
  if (!canonicalLanCredential.hasMatch(value)) return false;
  try {
    return base64Url.decode('$value=').length == 32 &&
        base64Url.encode(base64Url.decode('$value=')).replaceAll('=', '') ==
            value;
  } on FormatException {
    return false;
  }
}

final class LanEndpoint {
  LanEndpoint({required this.host, required this.port}) {
    if (port < 1 || port > 65535) {
      throw ArgumentError.value(port, 'port');
    }
  }

  factory LanEndpoint.parse(String value) {
    final separator = value.lastIndexOf(':');
    if (separator <= 0 || separator == value.length - 1) {
      throw const FormatException('invalid_endpoint');
    }
    final portText = value.substring(separator + 1);
    if (!RegExp(r'^[1-9][0-9]{0,4}$').hasMatch(portText)) {
      throw const FormatException('invalid_endpoint');
    }
    return LanEndpoint(
      host: PrivateIpv4.parse(value.substring(0, separator)),
      port: int.parse(portText),
    );
  }

  final PrivateIpv4 host;
  final int port;

  Uri resolve(String path) =>
      Uri(scheme: 'http', host: host.address, port: port, path: path);

  Uri get webSocketUri => resolve('/lan/v1/ws').replace(scheme: 'ws');

  String get encoded => '${host.address}:$port';

  @override
  bool operator ==(Object other) =>
      other is LanEndpoint && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);
}

final class LanJoinCandidate {
  const LanJoinCandidate({
    required this.roomId,
    required this.joinAttemptId,
    required this.candidateResumeToken,
    required this.endpoint,
  });

  final String roomId;
  final String joinAttemptId;
  final String candidateResumeToken;
  final LanEndpoint endpoint;

  @override
  String toString() =>
      'LanJoinCandidate(roomId: $roomId, credentials: <redacted>)';
}

final class LanCredential {
  const LanCredential({
    required this.roomId,
    required this.playerId,
    required this.joinAttemptId,
    required this.resumeToken,
    required this.endpoint,
  });

  final String roomId;
  final String playerId;
  final String joinAttemptId;
  final String resumeToken;
  final LanEndpoint endpoint;

  @override
  String toString() =>
      'LanCredential(roomId: $roomId, credentials: <redacted>)';
}

final class LanLaunchReceipt {
  const LanLaunchReceipt({
    required this.matchId,
    required this.gameId,
    required this.playerId,
    required this.launchTicket,
    required this.resumeToken,
    required this.expiresAt,
  });

  final String matchId;
  final String gameId;
  final String playerId;
  final String launchTicket;
  final String resumeToken;
  final DateTime expiresAt;

  @override
  String toString() =>
      'LanLaunchReceipt(matchId: $matchId, credentials: <redacted>)';
}

typedef LanJoinReceipt = LanLaunchReceipt;

final class AuthoritativePlayerSnapshot {
  const AuthoritativePlayerSnapshot({
    required this.userId,
    required this.nickname,
    required this.seat,
    required this.color,
  });

  final String userId;
  final String nickname;
  final int seat;
  final String color;

  Map<String, Object?> toJson() => {
    'userId': userId,
    'nickname': nickname,
    'seat': seat,
    'color': color,
  };
}

final class AuthoritativeEvent {
  const AuthoritativeEvent({
    required this.revision,
    required this.type,
    required this.actionId,
    required this.actorId,
    required this.payload,
    required this.committedAt,
  });

  final int revision;
  final String type;
  final String? actionId;
  final String? actorId;
  final Map<String, Object?> payload;
  final int committedAt;

  Map<String, Object?> toJson() => {
    'revision': revision,
    'type': type,
    'actionId': actionId,
    'actorId': actorId,
    'payload': payload,
    'committedAt': committedAt,
  };
}

final class AuthoritativeGameResult {
  const AuthoritativeGameResult({
    required this.schemaVersion,
    required this.matchId,
    required this.gameId,
    required this.players,
    required this.winnerUserId,
    required this.result,
    required this.startedAt,
    required this.finishedAt,
    required this.finalRevision,
    required this.events,
  });

  factory AuthoritativeGameResult.fromJsonBytes(List<int> bytes) {
    final object = decodeStrictJsonObject(Uint8List.fromList(bytes));
    return AuthoritativeGameResult.fromObject(object);
  }

  factory AuthoritativeGameResult.fromObject(Map<String, Object?> object) {
    const keys = {
      'schemaVersion',
      'matchId',
      'gameId',
      'players',
      'winnerUserId',
      'result',
      'startedAt',
      'finishedAt',
      'finalRevision',
      'events',
    };
    if (!hasExactJsonKeys(object, keys) ||
        object['schemaVersion'] != 1 ||
        object['matchId'] is! String ||
        object['gameId'] != 'gomoku' ||
        object['players'] is! List<Object?> ||
        object['winnerUserId'] is! String? ||
        object['result'] is! String ||
        object['startedAt'] is! int ||
        object['finishedAt'] is! int ||
        object['finalRevision'] is! int ||
        object['events'] is! List<Object?>) {
      throw const FormatException('invalid_game_result');
    }
    final matchId = object['matchId']! as String;
    final winner = object['winnerUserId'] as String?;
    final result = object['result']! as String;
    final started = object['startedAt']! as int;
    final finished = object['finishedAt']! as int;
    final finalRevision = object['finalRevision']! as int;
    if (!isCanonicalLanUuid(matchId) ||
        winner != null && !isCanonicalLanUuid(winner) ||
        !const {'five', 'resignation', 'draw'}.contains(result) ||
        started <= 0 ||
        finished < started ||
        finalRevision <= 0 ||
        finalRevision > 226) {
      throw const FormatException('invalid_game_result');
    }
    final players = (object['players']! as List<Object?>)
        .map(_parsePlayer)
        .toList(growable: false);
    if (players.length != 2 ||
        players.map((p) => p.userId).toSet().length != 2 ||
        players.map((p) => p.seat).toSet().length != 2 ||
        !_sameSet(players.map((p) => p.color).toSet(), const {
          'black',
          'white',
        }) ||
        winner != null && !players.any((p) => p.userId == winner) ||
        result == 'draw' && winner != null ||
        result != 'draw' && winner == null) {
      throw const FormatException('invalid_game_result');
    }
    final events = (object['events']! as List<Object?>)
        .map(_parseEvent)
        .toList(growable: false);
    final actionIds = events
        .map((event) => event.actionId)
        .whereType<String>()
        .toList(growable: false);
    if (events.length != finalRevision ||
        events.indexed.any((item) => item.$2.revision != item.$1 + 1) ||
        events.first.committedAt < started ||
        events.last.committedAt != finished ||
        events.indexed
            .skip(1)
            .any(
              (item) => item.$2.committedAt < events[item.$1 - 1].committedAt,
            ) ||
        events.any(
          (event) =>
              event.committedAt > finished ||
              event.actorId != null &&
                  !players.any((player) => player.userId == event.actorId),
        ) ||
        actionIds.toSet().length != actionIds.length) {
      throw const FormatException('invalid_game_result');
    }
    return AuthoritativeGameResult(
      schemaVersion: 1,
      matchId: matchId,
      gameId: 'gomoku',
      players: players,
      winnerUserId: winner,
      result: result,
      startedAt: started,
      finishedAt: finished,
      finalRevision: finalRevision,
      events: events,
    );
  }

  final int schemaVersion;
  final String matchId;
  final String gameId;
  final List<AuthoritativePlayerSnapshot> players;
  final String? winnerUserId;
  final String result;
  final int startedAt;
  final int finishedAt;
  final int finalRevision;
  final List<AuthoritativeEvent> events;

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'matchId': matchId,
    'gameId': gameId,
    'players': players.map((item) => item.toJson()).toList(growable: false),
    'winnerUserId': winnerUserId,
    'result': result,
    'startedAt': startedAt,
    'finishedAt': finishedAt,
    'finalRevision': finalRevision,
    'events': events.map((item) => item.toJson()).toList(growable: false),
  };

  String encode() => jsonEncode(toJson());

  static AuthoritativePlayerSnapshot _parsePlayer(Object? raw) {
    if (raw is! Map<String, Object?> ||
        !hasExactJsonKeys(raw, const {'userId', 'nickname', 'seat', 'color'}) ||
        raw['userId'] is! String ||
        raw['nickname'] is! String ||
        raw['seat'] is! int ||
        raw['color'] is! String) {
      throw const FormatException('invalid_player');
    }
    final player = AuthoritativePlayerSnapshot(
      userId: raw['userId']! as String,
      nickname: raw['nickname']! as String,
      seat: raw['seat']! as int,
      color: raw['color']! as String,
    );
    if (!isCanonicalLanUuid(player.userId) ||
        player.nickname.isEmpty ||
        utf8.encode(player.nickname).length > 80 ||
        player.seat < 0 ||
        player.seat > 1 ||
        !const {'black', 'white'}.contains(player.color)) {
      throw const FormatException('invalid_player');
    }
    return player;
  }

  static AuthoritativeEvent _parseEvent(Object? raw) {
    if (raw is! Map<String, Object?> ||
        !hasExactJsonKeys(raw, const {
          'revision',
          'type',
          'actionId',
          'actorId',
          'payload',
          'committedAt',
        }) ||
        raw['revision'] is! int ||
        raw['type'] is! String ||
        raw['actionId'] is! String? ||
        raw['actorId'] is! String? ||
        raw['payload'] is! Map<String, Object?> ||
        raw['committedAt'] is! int) {
      throw const FormatException('invalid_event');
    }
    final actionId = raw['actionId'] as String?;
    final actorId = raw['actorId'] as String?;
    if (actionId != null && !isCanonicalLanUuid(actionId) ||
        actorId != null && !isCanonicalLanUuid(actorId) ||
        (raw['type']! as String).isEmpty ||
        (raw['type']! as String).length > 128) {
      throw const FormatException('invalid_event');
    }
    return AuthoritativeEvent(
      revision: raw['revision']! as int,
      type: raw['type']! as String,
      actionId: actionId,
      actorId: actorId,
      payload: Map<String, Object?>.unmodifiable(
        raw['payload']! as Map<String, Object?>,
      ),
      committedAt: raw['committedAt']! as int,
    );
  }

  static bool _sameSet<T>(Set<T> left, Set<T> right) =>
      left.length == right.length && left.containsAll(right);
}

final class LanException implements Exception {
  const LanException(this.code, {this.authoritative = false});

  final String code;
  final bool authoritative;

  @override
  String toString() => 'LanException($code)';
}
