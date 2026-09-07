import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/design_system/gamebox_theme.dart';
import 'package:gamebox/features/scratch/scratch_card_detail.dart';
import 'package:gamebox/features/scratch/scratch_controller.dart';

import 'scratch_card_owners_test.dart' show OwnersApi;
import 'scratch_controller_test.dart' show MemoryScratchStore;

void main() {
  for (final dark in [false, true]) {
    testWidgets('detail lazily loads owners and preserves scroll ($dark)', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(360, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = ScratchController(store: MemoryScratchStore());
      await controller.load();
      controller.counts[13] = 1000000000;
      controller.firstFound[13] = '2026-09-08T00:00:00Z';
      final api = OwnersApi()..error = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: dark ? GameboxTheme.dark() : GameboxTheme.light(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  showDragHandle: true,
                  useSafeArea: true,
                  builder: (_) => ScratchCardDetail(
                    cat: scratchCollectibles[13],
                    controller: controller,
                    api: api,
                    beforeLoad: () async {},
                    onDraw: () {},
                  ),
                ),
                child: const Text('打开详情'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开详情'));
      await tester.pumpAndSettle();
      expect(api.queries, isEmpty);
      expect(find.text('1000000000 张'), findsOneWidget);
      final entry = find.byKey(const Key('scratch-view-owners'));
      await tester.ensureVisible(entry);
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('查看持有玩家')).dx,
        tester.getTopLeft(find.text('我的收藏')).dx,
      );
      expect(find.byIcon(Icons.collections_bookmark_outlined), findsNothing);
      expect(find.byIcon(Icons.people_outline), findsNothing);
      expect(
        tester.getRect(find.byKey(const Key('scratch-owned-count'))).right,
        tester.getRect(entry).right,
      );
      expect(
        tester.getRect(find.byIcon(Icons.chevron_right)).right,
        tester.getRect(entry).right,
      );
      expect(
        tester.getCenter(find.byIcon(Icons.chevron_right)).dy,
        tester.getCenter(find.text('查看持有玩家')).dy,
      );
      final before = tester.getTopLeft(entry);
      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(find.text('玩家甲'), findsOneWidget);
      expect(find.text('7 张'), findsOneWidget);
      expect(find.byKey(const Key('scratch-owned-count')), findsNothing);
      await tester.tap(find.text('玩家甲'));
      await tester.pumpAndSettle();
      expect(find.text('玩家甲的收藏'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('玩家甲'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(entry), before);
      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(api.queries, ['13:']);
      await tester.tap(find.byTooltip('返回卡片详情'));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(entry), before);
      expect(tester.takeException(), isNull);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('卡片详情'), findsNothing);
    });
  }
  testWidgets('unowned detail has collection entry and draw action', (
    tester,
  ) async {
    final controller = ScratchController(store: MemoryScratchStore());
    await controller.load();
    var draws = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ScratchCardDetail(
            cat: scratchCollectibles.first,
            controller: controller,
            api: OwnersApi(),
            beforeLoad: () async {},
            onDraw: () => draws++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('尚未收藏'), findsOneWidget);
    expect(find.textContaining('首次相遇'), findsNothing);
    await tester.ensureVisible(find.text('去抽一张'));
    await tester.tap(find.text('去抽一张'));
    expect(draws, 1);
  });
}
