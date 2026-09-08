import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/design_system/gamebox_theme.dart';
import 'package:gamebox/features/scratch/scratch_compare_page.dart';
import 'package:gamebox/features/scratch/scratch_compare_player_picker.dart';
import 'package:gamebox/features/scratch/scratch_controller.dart';
import 'package:gamebox/features/scratch/scratch_page.dart';
import 'package:gamebox/features/scratch/scratch_social_api.dart';

import 'scratch_controller_test.dart' show MemoryScratchStore;

List<int> counts(Map<int, int> values) =>
    List.generate(48, (i) => values[i] ?? 0);
ScratchPlayer player(String name, Map<int, int> values) => ScratchPlayer(
  userId: name,
  nickname: name,
  counts: counts(values),
  updatedAt: DateTime(2026),
);

class CompareApi implements ScratchSocialApi {
  @override
  bool get canSync => false;
  final first = player('小满', {0: 3, 1: 1, 24: 2});
  final second = player('阿树', {2: 1, 25: 1});
  bool failNext = false;
  Completer<void>? pending;
  final calls = <String>[];
  @override
  Future<void> sync(List<int> counts) async {}
  @override
  Future<ScratchPlayerPage> list([String after = '', int? card]) async {
    calls.add(after);
    await pending?.future;
    if (after.isNotEmpty && failNext) {
      failNext = false;
      throw Exception('offline');
    }
    return after.isEmpty
        ? ScratchPlayerPage([first], 'next')
        : ScratchPlayerPage([second], '');
  }
}

Future<void> tap(WidgetTester t, String key) async {
  await t.tap(find.byKey(Key(key)));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('search covers later pages and can retry without losing query', (
    t,
  ) async {
    final api = CompareApi()..failNext = true;
    await t.pumpWidget(MaterialApp(home: ScratchComparePlayerPicker(api: api)));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), '阿树');
    await t.pumpAndSettle();
    expect(find.text('暂时无法读取玩家'), findsOneWidget);
    await tap(t, 'compare-players-retry');
    expect(find.text('阿树'), findsWidgets);
    expect(api.calls, ['', 'next', 'next']);
    expect(find.byKey(const Key('compare-player-阿树')), findsOneWidget);
    expect(find.byKey(const Key('compare-player-小满')), findsNothing);
  });
  testWidgets('closing while players load is safe', (t) async {
    final api = CompareApi()..pending = Completer<void>();
    await t.pumpWidget(MaterialApp(home: ScratchComparePlayerPicker(api: api)));
    await t.pump();
    await t.pumpWidget(const SizedBox());
    api.pending!.complete();
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });
  testWidgets(
    'picker excludes self, and clearing search restores loaded players',
    (t) async {
      final api = CompareApi();
      await t.pumpWidget(
        MaterialApp(
          home: ScratchComparePlayerPicker(api: api, excludeUserId: '小满'),
        ),
      );
      await t.pumpAndSettle();
      expect(find.byKey(const Key('compare-player-小满')), findsNothing);
      await t.enterText(find.byType(TextField), '阿树');
      await t.pumpAndSettle();
      expect(find.byKey(const Key('compare-player-阿树')), findsOneWidget);
      await t.enterText(find.byType(TextField), '不存在');
      await t.pumpAndSettle();
      expect(find.text('没有找到这位好友'), findsOneWidget);
      await t.enterText(find.byType(TextField), '');
      await t.pumpAndSettle();
      expect(find.byKey(const Key('compare-player-阿树')), findsOneWidget);
    },
  );
  testWidgets('all cards hides artwork neither player owns', (t) async {
    final api = CompareApi();
    await t.pumpWidget(
      MaterialApp(
        home: ScratchComparePage(
          api: api,
          player: player('空收藏', {}),
          mine: counts({}),
          groupId: 'cats',
        ),
      ),
    );
    await t.pumpAndSettle();
    await tap(t, 'compare-filter-all');
    final tile = t.widget<InkWell>(find.byKey(const Key('compare-card-0')));
    expect(tile.onTap, isNull);
    expect(find.byIcon(Icons.lock_outline), findsWidgets);
    expect(find.text('面包师 · 小麦'), findsNothing);
  });
  for (final dark in [false, true]) {
    testWidgets('difference, series, player and quantities dark=$dark', (
      t,
    ) async {
      t.view.physicalSize = const Size(360, 780);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final api = CompareApi();
      await t.pumpWidget(
        MaterialApp(
          theme: dark ? GameboxTheme.dark() : GameboxTheme.light(),
          home: ScratchComparePage(
            api: api,
            player: api.first,
            mine: counts({0: 1, 2: 2, 25: 1}),
            groupId: 'cats',
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.byKey(const Key('compare-card-1')), findsOneWidget);
      expect(find.byKey(const Key('compare-card-0')), findsNothing);
      await tap(t, 'compare-filter-both');
      await tap(t, 'compare-card-0');
      expect(find.text('我 1 张'), findsWidgets);
      expect(find.text('小满 3 张'), findsWidgets);
      await tap(t, 'compare-detail-close');
      await tap(t, 'compare-filter-only');
      await tap(t, 'compare-group');
      await tap(t, 'compare-group-dogs');
      expect(find.byKey(const Key('compare-card-25')), findsOneWidget);
      await tap(t, 'compare-friend');
      await t.enterText(find.byType(TextField), '阿树');
      await t.pumpAndSettle();
      await tap(t, 'compare-player-阿树');
      expect(find.text('狗狗百业'), findsOneWidget);
      expect(find.text('这里还没有卡片'), findsOneWidget);
      await tap(t, 'compare-filter-both');
      expect(find.byKey(const Key('compare-card-25')), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }
  for (final selectedGroup in [false, true]) {
    testWidgets(
      'album entry preserves filters and handles series cancellation selected=$selectedGroup',
      (t) async {
        final c = ScratchController(store: MemoryScratchStore());
        await c.load();
        final api = CompareApi();
        await t.pumpWidget(
          MaterialApp(
            theme: GameboxTheme.light(),
            home: ScratchPage(controller: c, socialApi: api),
          ),
        );
        await t.pumpAndSettle();
        expect(find.byKey(const Key('scratch-compare')), findsNothing);
        await tap(t, 'scratch-tab-album');
        if (selectedGroup) {
          await t.tap(find.text('狗狗百业 0/24'));
          await t.pumpAndSettle();
        }
        await tap(t, 'scratch-compare');
        await tap(t, 'compare-player-小满');
        if (!selectedGroup) {
          expect(find.text('选择卡片集'), findsOneWidget);
          await t.binding.handlePopRoute();
          await t.pumpAndSettle();
          expect(find.text('收藏图鉴'), findsOneWidget);
          await tap(t, 'scratch-compare');
          await tap(t, 'compare-player-小满');
          await tap(t, 'compare-group-cats');
        }
        expect(find.text('收藏对比'), findsOneWidget);
        expect(find.text(selectedGroup ? '狗狗百业' : '猫猫百业'), findsOneWidget);
        await t.binding.handlePopRoute();
        await t.pumpAndSettle();
        expect(find.text('收藏图鉴'), findsOneWidget);
        expect(
          t.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
          1,
        );
        if (selectedGroup) {
          expect(
            t
                .widget<ChoiceChip>(
                  find.ancestor(
                    of: find.text('狗狗百业 0/24'),
                    matching: find.byType(ChoiceChip),
                  ),
                )
                .selected,
            isTrue,
          );
        }
        await t.pumpWidget(const SizedBox());
        c.dispose();
      },
    );
  }
}
