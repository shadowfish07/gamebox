import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:gamebox/core/api/api_client.dart';
import 'package:gamebox/core/api/api_error.dart';
import 'package:gamebox/design_system/gamebox_theme.dart';
import 'package:gamebox/features/scratch/scratch_controller.dart';
import 'package:gamebox/features/scratch/scratch_players_page.dart';
import 'package:gamebox/features/scratch/scratch_social_api.dart';

import 'package:gamebox/features/scratch/scratch_surface.dart';

import 'scratch_controller_test.dart' show MemoryScratchStore;

class FakeSocial implements ScratchSocialApi {
  @override
  bool canSync = true;
  bool fail = false;
  List<int>? published;
  int calls = 0;
  Completer<void>? pending;
  @override
  Future<ScratchPlayerPage> list([String after = '']) async {
    calls++;
    await pending?.future;
    if (fail) throw const ApiError(code: 'network_error', message: '连接失败');
    return ScratchPlayerPage([
      ScratchPlayer(
        userId: '11111111-1111-4111-8111-111111111111',
        nickname: '玩家甲',
        counts: List.generate(24, (i) => i == 13 ? 2 : 0),
        updatedAt: DateTime(2026, 9, 7),
      ),
    ], '');
  }

  @override
  Future<void> sync(List<int> counts) async {
    published = counts;
  }
}

void main() {
  for (final dark in [false, true]) {
    testWidgets('players loading error retry inspect dark=$dark', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final api = FakeSocial()..fail = true;
      final collection = ScratchController(
        store: MemoryScratchStore(),
        random: () => 0,
      );
      await collection.load();
      await collection.revealAll();
      await tester.pumpWidget(
        MaterialApp(
          theme: dark ? GameboxTheme.dark() : GameboxTheme.light(),
          home: Scaffold(body: ScratchPlayersPage(api: api)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('连接失败'), findsOneWidget);
      api.fail = false;
      api.pending = Completer<void>();
      await tester.tap(find.text('重试'));
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      api.pending!.complete();
      await tester.pumpAndSettle();
      expect(find.text('玩家甲'), findsOneWidget);
      await tester.tap(find.text('玩家甲'));
      await tester.pumpAndSettle();
      expect(find.text('玩家甲的收藏'), findsOneWidget);
      expect(find.text('已收集 1/24'), findsOneWidget);
      expect(find.text('猫猫百业 · 1/24'), findsOneWidget);
      expect(find.text('魔术师'), findsOneWidget);
      final art = tester.getSize(find.byType(CollectibleArtwork));
      expect(art.width, art.height);
      expect(find.text('稀有'), findsOneWidget);
      expect(find.text('×2'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('scratch-publish')), findsNothing);
      expect(find.text('取消公开'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      collection.dispose();
    });
  }
  testWidgets('guest can browse but cannot publish', (tester) async {
    final api = FakeSocial()..canSync = false;
    final collection = ScratchController(store: MemoryScratchStore());
    await collection.load();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ScratchPlayersPage(api: api)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('玩家甲'), findsOneWidget);
    expect(find.byKey(const Key('scratch-publish')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    collection.dispose();
  });
  test('HTTP collection response validates IDs counts cursor and preserves request path', () async {
    var body = <String, Object?>{
      'players': [
        {
          'userId': '11111111-1111-4111-8111-111111111111',
          'nickname': '甲',
          'counts': List.filled(24, 1),
          'updatedAt': 1788739200000,
        },
      ],
      'nextCursor': '',
    };
    final client = ApiClient(
      baseUri: Uri.parse('http://localhost:1234'),
      httpClient: MockClient((request) async {
        expect(request.url.path, '/v1/scratch/collections');
        return http.Response(
          jsonEncode(body),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final api = HttpScratchSocialApi(client);
    expect((await api.list()).players.single.collected, 24);
    body = {
      'players': [
        {
          'userId': 'bad',
          'nickname': '甲',
          'counts': [-1],
          'updatedAt': 0,
        },
      ],
      'nextCursor': '',
    };
    await expectLater(api.list(), throwsA(isA<ApiError>()));
    client.close();
  });
}
