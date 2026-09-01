import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/core/lan/lan_models.dart';
import 'package:gamebox/core/platform/method_channel_game_results_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test.game-results');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('decodes committed and pending native records exactly', () async {
    final fixture = await File('../protocol/fixtures/game_result.json')
        .readAsString();
    messenger.setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        'listCommitted' => [
          {'result': fixture, 'sha256': 'a' * 64},
        ],
        'listPending' => [
          {
            'matchId': '11111111-1111-4111-8111-111111111111',
            'gameId': 'gomoku',
            'source': 'lan',
            'endpointKind': 'lan',
            'localUserId': '22222222-2222-4222-8222-222222222222',
          },
        ],
        _ => null,
      };
    });
    final platform = MethodChannelGameResultsPlatform(channel: channel);

    final committed = (await platform.listCommitted()).single;
    expect(committed.result.players.first.nickname, '玩家甲');
    expect(committed.sha256, 'a' * 64);
    final pending = (await platform.listPending()).single;
    expect(pending.source, 'lan');
    expect(pending.matchId, '11111111-1111-4111-8111-111111111111');
    expect(pending.localUserId, '22222222-2222-4222-8222-222222222222');
  });

  test('persists recovery then completes by exact native hash', () async {
    final fixture = await File('../protocol/fixtures/game_result.json')
        .readAsBytes();
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'persistRecovered' ? 'b' * 64 : null;
    });
    final platform = MethodChannelGameResultsPlatform(channel: channel);
    final result = AuthoritativeGameResult.fromJsonBytes(fixture);

    final hash = await platform.persistRecovered(result);
    await platform.completePending(result.matchId, hash);

    expect(calls.map((call) => call.method), [
      'persistRecovered',
      'completePending',
    ]);
    expect(calls.last.arguments, {
      'matchId': result.matchId,
      'expectedSha256': 'b' * 64,
    });
  });
}
