import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/design_system/gamebox_theme.dart';
import 'package:gamebox/features/scratch/scratch_controller.dart';
import 'package:gamebox/features/scratch/scratch_page.dart';
import 'package:gamebox/features/scratch/card_draw_play.dart';

import 'scratch_controller_test.dart' show MemoryScratchStore;
import 'scratch_social_test.dart' show FakeSocial;

void main() {
  testWidgets('miss shows no reward, continues and keeps album unchanged', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final c = ScratchController(store: MemoryScratchStore(), random: () => .9);
    await c.load();
    await tester.pumpWidget(
      MaterialApp(
        theme: GameboxTheme.light(),
        home: ScratchPage(controller: c),
      ),
    );
    await tester.tap(find.byKey(const Key('scratch-primary')));
    await tester.pumpAndSettle();
    expect(find.text('空白卡'), findsOneWidget);
    expect(find.text('NEW'), findsNothing);
    expect(find.byKey(const Key('scratch-rarity-banner')), findsNothing);
    expect(find.textContaining('每抽必得'), findsNothing);
    expect(c.total, 0);
    await tester.tap(find.byKey(const Key('scratch-primary')));
    await tester.pumpAndSettle();
    expect(c.serial, 2);
    expect(c.total, 0);
    expect(find.byKey(const Key('draw-recent')), findsNothing);
    expect(tester.takeException(), isNull);
  });
  for (final (roll, tier) in [(0.0, 0), (.8, 1), (.96, 2), (.999, 3)]) {
    testWidgets('one tap flips tier $tier and next tap draws directly', (
      tester,
    ) async {
      var calls = 0;
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = MemoryScratchStore();
      final c = ScratchController(
        store: store,
        random: () => [0.0, roll, 0.0][calls++ % 3],
      );
      await c.load();
      await tester.pumpWidget(
        MaterialApp(
          theme: GameboxTheme.light(),
          home: ScratchPage(
            controller: c,
            socialApi: FakeSocial()..canSync = false,
          ),
        ),
      );
      expect(find.byKey(const Key('draw-card-back')), findsOneWidget);
      for (final transform in tester.widgetList<Transform>(
        find.descendant(
          of: find.byType(CardDrawStage),
          matching: find.byType(Transform),
        ),
      )) {
        expect(
          transform.transform.entry(0, 0),
          greaterThan(0),
          reason: 'A resting card back must not mirror its lettering',
        );
      }
      expect(find.byKey(const Key('scratch-rarity-banner')), findsNothing);
      expect(find.text('全部刮开'), findsNothing);
      await tester.tap(find.byKey(const Key('scratch-primary')));
      await tester.pump();
      await tester.pump(cardRevealDuration(tier) * .45);
      expect(find.byKey(const Key('draw-card-front')), findsOneWidget);
      await tester.pumpAndSettle();
      expect(c.total, 1);
      expect(find.text('${scratchRarities[tier]}收藏'), findsOneWidget);
      expect(find.text('NEW'), findsOneWidget);
      await tester.tap(find.byKey(const Key('scratch-primary')));
      await tester.pumpAndSettle();
      expect(c.total, 2);
      expect(find.text('共 2 张'), findsOneWidget);
      expect(
        find.text('已收藏').evaluate().length +
            find.text('已收进收藏').evaluate().length,
        1,
      );
      expect(find.textContaining(' → '), findsNothing);
      await tester.tap(find.byKey(const Key('draw-view-story')));
      await tester.pumpAndSettle();
      expect(find.text(c.cat.story), findsOneWidget);
      await tester.tap(find.byTooltip('关闭详情'));
      await tester.pumpAndSettle();
      expect(find.text('共 2 张'), findsOneWidget);
      expect(c.total, 2);
      expect(find.byKey(const Key('draw-recent')), findsOneWidget);
      await tester.tap(find.byKey(const Key('scratch-tab-album')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('scratch-tab-play')));
      await tester.pumpAndSettle();
      expect(c.total, 2);
      expect(tester.takeException(), isNull);
      store.fail = true;
      await tester.tap(find.byKey(const Key('scratch-primary')));
      await tester.pumpAndSettle();
      expect(c.error, isNotNull);
      expect(tester.takeException(), isNull);
      store.fail = false;
      await tester.tap(find.byKey(const Key('scratch-retry')));
      await tester.pumpAndSettle();
      expect(c.total, 3);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    });
  }
  for (final size in [const Size(360, 640), const Size(412, 891)]) {
    for (final dark in [false, true]) {
      testWidgets('phone $size dark=$dark keeps manual draw controls usable', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
        addTearDown(tester.view.reset);
        final c = ScratchController(
          store: MemoryScratchStore(),
          random: () => 0,
        );
        await c.load();
        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? GameboxTheme.dark() : GameboxTheme.light(),
            home: ScratchPage(
              controller: c,
              socialApi: FakeSocial()..canSync = false,
            ),
          ),
        );
        expect(find.text('连抽 10 张'), findsNothing);
        expect(find.byKey(const Key('draw-summary')), findsNothing);
        for (var i = 0; i < 3; i++) {
          await tester.tap(find.byKey(const Key('scratch-primary')));
          await tester.pumpAndSettle();
        }
        expect(c.total, 3);
        expect(find.byKey(const Key('draw-recent')), findsOneWidget);
        expect(
          tester.getBottomRight(find.byKey(const Key('scratch-primary'))).dy,
          lessThan(size.height - 24),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        c.dispose();
      });
    }
  }
  testWidgets(
    'leaving during a pending draw cancels queued tap; retry never duplicates',
    (tester) async {
      final store = MemoryScratchStore();
      final c = ScratchController(store: store, random: () => 0);
      await c.load();
      await tester.pumpWidget(
        MaterialApp(
          home: ScratchPage(
            controller: c,
            socialApi: FakeSocial()..canSync = false,
          ),
        ),
      );
      store.pending = Completer<void>();
      await tester.tap(find.byKey(const Key('scratch-primary')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('scratch-primary')));
      await tester.tap(find.byKey(const Key('scratch-tab-album')));
      await tester.pump();
      store.pending!.complete();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 10));
      expect(c.total, 1);
      await tester.tap(find.byKey(const Key('scratch-tab-play')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('draw-card-front')), findsOneWidget);
      store.pending = null;
      store.fail = true;
      await tester.tap(find.byKey(const Key('scratch-primary')));
      await tester.pumpAndSettle();
      expect(c.total, 2);
      expect(find.text('收藏尚未保存，请重试后继续。'), findsOneWidget);
      store.fail = false;
      await tester.tap(find.byKey(const Key('scratch-retry')));
      await tester.pumpAndSettle();
      expect(c.total, 2);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    },
  );
}
