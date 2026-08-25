import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/core/lan/lan_api.dart';
import 'package:gamebox/core/lan/lan_credential_store.dart';
import 'package:gamebox/core/lan/lan_models.dart';
import 'package:gamebox/core/platform/game_results_platform.dart';
import 'package:gamebox/features/history/game_history_controller.dart';
import 'package:gamebox/features/history/game_history_page.dart';
import 'package:gamebox/features/history/game_history_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets('mixed history renders local outcomes without source labels', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'gamebox-history-page-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final original = AuthoritativeGameResult.fromJsonBytes(
      File('../protocol/fixtures/game_result.json').readAsBytesSync(),
    );
    final second = AuthoritativeGameResult(
      schemaVersion: 1,
      matchId: '66666666-6666-4666-8666-666666666666',
      gameId: original.gameId,
      players: original.players,
      winnerUserId: original.winnerUserId,
      result: original.result,
      startedAt: original.startedAt,
      finishedAt: original.finishedAt + 1,
      finalRevision: original.finalRevision,
      events: [
        ...original.events.take(original.events.length - 1),
        AuthoritativeEvent(
          revision: original.events.last.revision,
          type: original.events.last.type,
          actionId: original.events.last.actionId,
          actorId: original.events.last.actorId,
          payload: original.events.last.payload,
          committedAt: original.finishedAt + 1,
        ),
      ],
    );
    final store = GameHistoryStore(directory: () async => directory);
    File('${directory.path}/${original.matchId}.json').writeAsStringSync(
      GameHistoryRecord(
        authoritative: original,
        source: GameResultSource.public,
        localUserId: original.players.first.userId,
      ).encode(),
    );
    File('${directory.path}/${second.matchId}.json').writeAsStringSync(
      GameHistoryRecord(
        authoritative: second,
        source: GameResultSource.lan,
        localUserId: second.players.last.userId,
      ).encode(),
    );
    final api = LanApi(
      client: MockClient((_) async => http.Response('{}', 500)),
    );
    addTearDown(api.close);
    final controller = GameHistoryController(
      platform: _EmptyPlatform(),
      store: store,
      lanApi: api,
      credentials: LanCredentialStore(storage: _MemoryStorage()),
    );
    addTearDown(controller.dispose);
    await tester.runAsync(controller.refresh);

    await tester.pumpWidget(
      MaterialApp(home: GameHistoryPage(controller: controller)),
    );
    for (var attempt = 0; attempt < 20; attempt += 1) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.textContaining('胜利').evaluate().isNotEmpty) break;
    }

    expect(find.textContaining('胜利'), findsOneWidget);
    expect(find.textContaining('失败'), findsOneWidget);
    expect(find.textContaining('公网'), findsNothing);
    expect(find.textContaining('局域网'), findsNothing);
    expect(find.textContaining('public'), findsNothing);
    expect(find.textContaining('lan'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

final class _EmptyPlatform implements GameResultsPlatform {
  @override
  Future<void> completePending(String matchId, String expectedSha256) async {}
  @override
  Future<List<CommittedGameResult>> listCommitted() async => const [];
  @override
  Future<List<PendingGameResultRecord>> listPending() async => const [];
  @override
  Future<String> persistRecovered(AuthoritativeGameResult result) async =>
      'a' * 64;
  @override
  Future<bool> quarantine(String matchId) async => false;
}

final class _MemoryStorage implements LanKeyValueStorage {
  @override
  Future<void> delete(String key) async {}
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
}
