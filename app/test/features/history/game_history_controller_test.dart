import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/core/lan/lan_api.dart';
import 'package:gamebox/core/lan/lan_credential_store.dart';
import 'package:gamebox/core/lan/lan_models.dart';
import 'package:gamebox/core/platform/game_results_platform.dart';
import 'package:gamebox/features/history/game_history_controller.dart';
import 'package:gamebox/features/history/game_history_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'imports native committed results and completes public pending',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'gamebox-history-controller-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final result = AuthoritativeGameResult.fromJsonBytes(
        await File('../protocol/fixtures/game_result.json').readAsBytes(),
      );
      final platform = _FakeResultsPlatform(
        committed: [CommittedGameResult(result: result, sha256: 'a' * 64)],
        pending: [
          PendingGameResultRecord(
            matchId: result.matchId,
            gameId: result.gameId,
            source: 'public',
            endpointKind: 'public',
          ),
        ],
      );
      final controller = GameHistoryController(
        platform: platform,
        store: GameHistoryStore(directory: () async => directory),
        lanApi: LanApi(),
        credentials: LanCredentialStore(storage: _MemoryLanStorage()),
        fetchPublicResult: (_) async => result,
        publicUserId: result.players.first.userId,
      );
      addTearDown(controller.dispose);

      await controller.refresh();
      expect(controller.results.single.authoritative.matchId, result.matchId);
      expect(platform.completed, [result.matchId]);
      expect(controller.pending, isEmpty);
      expect(controller.errorCode, isNull);
    },
  );

  test('LAN import sends ack before credential and pending deletion', () async {
    final directory = await Directory.systemTemp.createTemp(
      'gamebox-history-controller-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final result = AuthoritativeGameResult.fromJsonBytes(
      await File('../protocol/fixtures/game_result.json').readAsBytes(),
    );
    final events = <String>[];
    final storage = _MemoryLanStorage(events: events);
    storage.values['${LanCredentialStore.keyPrefix}${result.matchId}'] =
        jsonEncode({
          'schemaVersion': 1,
          'kind': 'credential',
          'roomId': result.matchId,
          'playerId': result.players.first.userId,
          'joinAttemptId': '44444444-4444-4444-8444-444444444444',
          'token': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
          'endpoint': '10.0.2.2:50000',
        });
    final platform = _FakeResultsPlatform(
      committed: [CommittedGameResult(result: result, sha256: 'a' * 64)],
      pending: [
        PendingGameResultRecord(
          matchId: result.matchId,
          gameId: result.gameId,
          source: 'lan',
          endpointKind: 'lan',
        ),
      ],
      events: events,
    );
    final api = LanApi(
      client: MockClient((request) async {
        events.add(request.method);
        if (request.method == 'GET') {
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'schemaVersion': 1,
                'resultHash': 'b' * 64,
                'result': result.toJson(),
              }),
            ),
            200,
          );
        }
        return http.Response(
          jsonEncode({'schemaVersion': 1, 'acknowledged': true}),
          200,
        );
      }),
    );
    final controller = GameHistoryController(
      platform: platform,
      store: GameHistoryStore(directory: () async => directory),
      lanApi: api,
      credentials: LanCredentialStore(storage: storage),
    );
    addTearDown(controller.dispose);

    final credential = await LanCredentialStore(storage: storage)
        .readCredential(result.matchId);
    expect(credential, isNotNull);
    expect(
      (await api.fetchResult(credential!.endpoint, credential)).result.encode(),
      result.encode(),
    );
    events.clear();

    await controller.refresh();

    expect(events, ['GET', 'POST', 'delete', 'complete']);
    expect(controller.results.single.source, GameResultSource.lan);
    expect(controller.pending, isEmpty);
  });

  test('finishes an in-flight refresh quietly after disposal', () async {
    final directory = await Directory.systemTemp.createTemp(
      'gamebox-history-controller-dispose-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final gate = Completer<void>();
    final platform = _FakeResultsPlatform(
      committed: [],
      pending: [],
      listPendingGate: gate,
    );
    final controller = GameHistoryController(
      platform: platform,
      store: GameHistoryStore(directory: () async => directory),
      lanApi: LanApi(),
      credentials: LanCredentialStore(storage: _MemoryLanStorage()),
    );

    final refresh = controller.refresh();
    controller.dispose();
    gate.complete();

    await expectLater(refresh, completes);
  });
}

final class _FakeResultsPlatform implements GameResultsPlatform {
  _FakeResultsPlatform({
    required this.committed,
    required this.pending,
    this.events,
    this.listPendingGate,
  });
  final List<CommittedGameResult> committed;
  final List<PendingGameResultRecord> pending;
  final List<String> completed = [];
  final List<String>? events;
  final Completer<void>? listPendingGate;

  @override
  Future<void> completePending(String matchId, String expectedSha256) async {
    expect(expectedSha256, 'a' * 64);
    completed.add(matchId);
    events?.add('complete');
    pending.removeWhere((item) => item.matchId == matchId);
  }

  @override
  Future<List<CommittedGameResult>> listCommitted() async => committed;

  @override
  Future<List<PendingGameResultRecord>> listPending() async {
    await listPendingGate?.future;
    return List.unmodifiable(pending);
  }

  @override
  Future<String> persistRecovered(AuthoritativeGameResult result) async =>
      'a' * 64;

  @override
  Future<bool> quarantine(String matchId) async => false;
}

final class _MemoryLanStorage implements LanKeyValueStorage {
  _MemoryLanStorage({this.events});
  final values = <String, String>{};
  final List<String>? events;
  @override
  Future<void> delete(String key) async {
    values.remove(key);
    events?.add('delete');
  }

  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}
