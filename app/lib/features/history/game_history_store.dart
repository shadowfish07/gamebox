import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../../core/api/strict_json.dart';
import '../../core/lan/lan_models.dart';

enum GameResultSource { public, lan }

enum LocalGameOutcome { win, loss, draw }

final class GameHistoryRecord {
  GameHistoryRecord({
    required this.authoritative,
    required this.source,
    required this.localUserId,
  }) {
    if (!authoritative.players.any((player) => player.userId == localUserId)) {
      throw ArgumentError.value(localUserId, 'localUserId');
    }
  }

  factory GameHistoryRecord.fromJsonBytes(List<int> bytes) {
    final object = decodeStrictJsonObject(Uint8List.fromList(bytes));
    if (!hasExactJsonKeys(object, const {
          'schemaVersion',
          'source',
          'localUserId',
          'authoritative',
        }) ||
        object['schemaVersion'] != 1 ||
        object['source'] is! String ||
        object['localUserId'] is! String ||
        object['authoritative'] is! Map<String, Object?>) {
      throw const FormatException('invalid_history_result');
    }
    final source = switch (object['source']) {
      'public' => GameResultSource.public,
      'lan' => GameResultSource.lan,
      _ => throw const FormatException('invalid_history_result'),
    };
    try {
      return GameHistoryRecord(
        authoritative: AuthoritativeGameResult.fromObject(
          object['authoritative']! as Map<String, Object?>,
        ),
        source: source,
        localUserId: object['localUserId']! as String,
      );
    } on ArgumentError {
      throw const FormatException('invalid_history_result');
    }
  }

  final AuthoritativeGameResult authoritative;
  final GameResultSource source;
  final String localUserId;

  AuthoritativePlayerSnapshot get localPlayer => authoritative.players
      .singleWhere((player) => player.userId == localUserId);

  AuthoritativePlayerSnapshot get opponent => authoritative.players.singleWhere(
    (player) => player.userId != localUserId,
  );

  LocalGameOutcome get outcome => authoritative.result == 'draw'
      ? LocalGameOutcome.draw
      : authoritative.winnerUserId == localUserId
      ? LocalGameOutcome.win
      : LocalGameOutcome.loss;

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'source': source.name,
    'localUserId': localUserId,
    'authoritative': authoritative.toJson(),
  };

  String encode() => jsonEncode(toJson());
}

final class GameHistoryStore {
  GameHistoryStore({Future<Directory> Function()? directory})
    : _directory = directory ?? _defaultDirectory;

  final Future<Directory> Function() _directory;
  int lastCorruptCount = 0;

  Future<bool> contains(String matchId) async {
    final directory = await _directory();
    return File('${directory.path}/$matchId.json').exists();
  }

  Future<List<GameHistoryRecord>> load() async {
    final directory = await _directory();
    if (!await directory.exists()) return const [];
    final records = <GameHistoryRecord>[];
    var corruptCount = 0;
    for (final entity in directory.listSync()) {
      if (entity is! File ||
          entity.path.endsWith('/index.json') ||
          !entity.path.endsWith('.json')) {
        continue;
      }
      try {
        final record = GameHistoryRecord.fromJsonBytes(
          await entity.readAsBytes(),
        );
        if (entity.uri.pathSegments.last !=
            '${record.authoritative.matchId}.json') {
          throw const FormatException('history_filename_mismatch');
        }
        records.add(record);
      } on Object {
        corruptCount += 1;
      }
    }
    lastCorruptCount = corruptCount;
    records.sort((a, b) {
      final byTime = b.authoritative.finishedAt.compareTo(
        a.authoritative.finishedAt,
      );
      return byTime != 0
          ? byTime
          : a.authoritative.matchId.compareTo(b.authoritative.matchId);
    });
    await _writeIndex(directory, records);
    return List.unmodifiable(records);
  }

  Future<void> import(GameHistoryRecord record) async {
    final directory = await _directory();
    await directory.create(recursive: true);
    final resultFile = File(
      '${directory.path}/${record.authoritative.matchId}.json',
    );
    if (await resultFile.exists()) {
      final existing = GameHistoryRecord.fromJsonBytes(
        await resultFile.readAsBytes(),
      );
      if (existing.encode() != record.encode()) {
        throw const FormatException('history_result_conflict');
      }
      return;
    }
    await _replace(resultFile, utf8.encode(record.encode()));
    await load();
  }

  Future<void> _writeIndex(
    Directory directory,
    List<GameHistoryRecord> records,
  ) => _replace(
    File('${directory.path}/index.json'),
    utf8.encode(
      jsonEncode({
        'schemaVersion': 1,
        'matches': records
            .map((record) => record.authoritative.matchId)
            .toList(growable: false),
      }),
    ),
  );

  Future<void> _replace(File destination, List<int> bytes) async {
    final temporary = File(
      '${destination.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(destination.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  static Future<Directory> _defaultDirectory() async => Directory(
    '${(await getApplicationSupportDirectory()).path}/game_history_v1',
  );
}
