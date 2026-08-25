import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/core/lan/lan_models.dart';
import 'package:gamebox/features/history/game_history_store.dart';

void main() {
  test(
    'imports idempotently and preserves invisible source and identity',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'gamebox-history-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = GameHistoryStore(directory: () async => directory);
      final result = AuthoritativeGameResult.fromJsonBytes(
        await File('../protocol/fixtures/game_result.json').readAsBytes(),
      );

      final record = GameHistoryRecord(
        authoritative: result,
        source: GameResultSource.lan,
        localUserId: result.players.first.userId,
      );
      await store.import(record);
      await store.import(record);

      final loaded = await store.load();
      expect(loaded, hasLength(1));
      expect(loaded.single.authoritative.encode(), result.encode());
      expect(loaded.single.source, GameResultSource.lan);
      expect(loaded.single.outcome, LocalGameOutcome.win);
      expect(
        directory.listSync().whereType<File>().map((file) => file.path),
        everyElement(isNot(endsWith('.tmp'))),
      );
    },
  );

  test('rebuilds a corrupt index and skips corrupt result evidence', () async {
    final directory = await Directory.systemTemp.createTemp('gamebox-history-');
    addTearDown(() => directory.delete(recursive: true));
    final store = GameHistoryStore(directory: () async => directory);
    await File('${directory.path}/index.json').writeAsString('{"matches":[]}');
    final corrupt = File(
      '${directory.path}/11111111-1111-4111-8111-111111111111.json',
    );
    await corrupt.writeAsString('corrupt');

    expect(await store.load(), isEmpty);
    expect(store.lastCorruptCount, 1);
    expect(await File('${directory.path}/index.json').exists(), isTrue);
    expect(await corrupt.exists(), isTrue);
  });
}
