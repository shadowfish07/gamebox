import 'dart:math';

import '../gomoku/gomoku_models.dart' show isCanonicalGameboxUuid;

const fleetLengths = [5, 4, 3, 3, 2];
const fleetNames = ['航空母舰', '战列舰', '巡洋舰', '潜艇', '驱逐舰'];
String coordinate(int cell) =>
    '${String.fromCharCode(65 + cell ~/ 10)}${cell % 10 + 1}';
String battleshipId() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

final class FleetShip {
  const FleetShip(this.id, this.cell, this.vertical);
  final int id, cell;
  final bool vertical;
  List<int> get cells =>
      List.generate(fleetLengths[id], (i) => cell + i * (vertical ? 10 : 1));
  Map<String, Object?> toJson() => {
    'id': id,
    'cell': cell,
    'vertical': vertical,
  };
  factory FleetShip.parse(Object? raw) {
    final j = _map(raw);
    final ship = FleetShip(
      _int(j['id'], 0, 4),
      _int(j['cell'], 0, 99),
      _bool(j['vertical']),
    );
    if (!validFleet([ship])) throw const FormatException();
    return ship;
  }
}

bool validFleet(List<FleetShip> ships) {
  final ids = <int>{}, cells = <int>{};
  for (final ship in ships) {
    if (ship.id < 0 ||
        ship.id > 4 ||
        !ids.add(ship.id) ||
        ship.cell < 0 ||
        ship.cell > 99) {
      return false;
    }
    for (final c in ship.cells) {
      if (c > 99 ||
          (!ship.vertical && c ~/ 10 != ship.cell ~/ 10) ||
          !cells.add(c)) {
        return false;
      }
    }
  }
  return true;
}

final class FleetShot {
  const FleetShot(this.cell, this.hit);
  final int cell;
  final bool hit;
  factory FleetShot.parse(Object? raw) {
    final j = _map(raw);
    return FleetShot(_int(j['cell'], 0, 99), _bool(j['hit']));
  }
}

final class SeaMatch {
  SeaMatch(Map<String, Object?> j)
    : id = _id(j['id']),
      revision = _int(j['revision'], 0, 1 << 53),
      opponentId = _id(j['opponentId']),
      opponentName = _text(j['opponentName']),
      phase = _text(j['phase']),
      yourTurn = _bool(j['yourTurn']),
      ready = _bool(j['ready']),
      enemyReady = _bool(j['enemyReady']),
      ownShips = _ships(j['ownShips']),
      enemyShips = _ships(j['enemyShips']),
      shots = _shots(j['shots']),
      incoming = _shots(j['incoming']),
      winner = _optionalId(j['winner']),
      endOffer = _optionalId(j['endOffer']),
      rematchRequested = _bool(j['rematchRequested']),
      enemyRematchRequested = _bool(j['enemyRematchRequested']),
      nextMatchId = _optionalId(j['nextMatchId']) {
    if (!['placement', 'battle', 'finished', 'cancelled'].contains(phase) ||
        (ready && ownShips.length != 5) ||
        (yourTurn && phase != 'battle') ||
        (phase == 'battle' && (!ready || !enemyReady))) {
      throw const FormatException();
    }
  }
  final String id,
      opponentId,
      opponentName,
      phase,
      winner,
      endOffer,
      nextMatchId;
  final int revision;
  final bool yourTurn,
      ready,
      enemyReady,
      rematchRequested,
      enemyRematchRequested;
  final List<FleetShip> ownShips, enemyShips;
  final List<FleetShot> shots, incoming;
  bool get ended => phase == 'finished' || phase == 'cancelled';
  int get sunkCount => enemyShips
      .where(
        (s) => s.cells.every((c) => shots.any((h) => h.cell == c && h.hit)),
      )
      .length;
  String status(String user) => switch (phase) {
    'placement' => ready ? '等待对方布阵' : '布置舰队',
    'battle' => yourTurn ? '轮到你了' : '等待对方出手',
    'cancelled' => '对局已取消',
    _ => winner == user ? '你赢了' : '你输了',
  };
}

Map<String, Object?> _map(Object? v) {
  if (v is! Map<String, Object?>) throw const FormatException();
  return v;
}

int _int(Object? v, int min, int max) {
  if (v is! int || v < min || v > max) throw const FormatException();
  return v;
}

bool _bool(Object? v) {
  if (v is! bool) throw const FormatException();
  return v;
}

String _text(Object? v) {
  if (v is! String ||
      v.trim().isEmpty ||
      v.length > 100 ||
      v.runes.any((c) => c < 32)) {
    throw const FormatException();
  }
  return v;
}

String _id(Object? v) {
  if (v is! String || !isCanonicalGameboxUuid(v)) throw const FormatException();
  return v;
}

String _optionalId(Object? v) => v == '' ? '' : _id(v);
List<FleetShip> _ships(Object? v) {
  if (v is! List || v.length > 5) throw const FormatException();
  final ships = v.map(FleetShip.parse).toList();
  if (!validFleet(ships)) throw const FormatException();
  return List.unmodifiable(ships);
}

List<FleetShot> _shots(Object? v) {
  if (v is! List || v.length > 100) throw const FormatException();
  final shots = v.map(FleetShot.parse).toList();
  if (shots.map((s) => s.cell).toSet().length != shots.length) {
    throw const FormatException();
  }
  return List.unmodifiable(shots);
}
