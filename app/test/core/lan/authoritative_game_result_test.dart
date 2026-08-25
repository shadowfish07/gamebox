import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/core/lan/lan_models.dart';

void main() {
  test('shared canonical result round trips without source metadata', () async {
    final bytes = await File('../protocol/fixtures/game_result.json')
        .readAsBytes();
    final result = AuthoritativeGameResult.fromJsonBytes(bytes);

    expect(result.finalRevision, 2);
    expect(result.players.map((player) => player.nickname), ['玩家甲', '玩家乙']);
    expect(result.toJson().containsKey('source'), isFalse);
    expect(
      AuthoritativeGameResult.fromJsonBytes(utf8.encode(result.encode()))
          .encode(),
      result.encode(),
    );
  });

  test('rejects unknown fields, revision gaps and duplicate actions', () async {
    final fixture = jsonDecode(
      await File('../protocol/fixtures/game_result.json').readAsString(),
    ) as Map<String, Object?>;
    final unknown = Map<String, Object?>.from(fixture)..['source'] = 'lan';
    expect(
      () => AuthoritativeGameResult.fromObject(unknown),
      throwsFormatException,
    );
    final gap = _copy(fixture);
    (gap['events']! as List<Object?>)[0] = Map<String, Object?>.from(
      (gap['events']! as List<Object?>)[0]! as Map<String, Object?>,
    )..['revision'] = 2;
    expect(
      () => AuthoritativeGameResult.fromObject(gap),
      throwsFormatException,
    );
    final duplicate = _copy(fixture);
    final events = duplicate['events']! as List<Object?>;
    events[1] = Map<String, Object?>.from(events[1]! as Map<String, Object?>)
      ..['actionId'] = (events[0]! as Map<String, Object?>)['actionId'];
    expect(
      () => AuthoritativeGameResult.fromObject(duplicate),
      throwsFormatException,
    );
  });
}

Map<String, Object?> _copy(Map<String, Object?> source) =>
    jsonDecode(jsonEncode(source)) as Map<String, Object?>;
