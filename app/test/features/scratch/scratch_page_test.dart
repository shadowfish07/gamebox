import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/design_system/gamebox_theme.dart';
import 'package:gamebox/features/scratch/scratch_controller.dart';
import 'package:gamebox/features/scratch/scratch_page.dart';
import 'package:gamebox/features/scratch/card_draw_play.dart';
import 'package:gamebox/features/scratch/scratch_reveal_effect.dart';

import 'scratch_controller_test.dart' show MemoryScratchStore;
import 'scratch_social_test.dart' show FakeSocial;

Future<void> waitForDrawReady(WidgetTester tester) async {
  for (var i = 0; i < 60; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    final finder = find.byKey(const Key('scratch-primary'));
    if (finder.evaluate().isEmpty) continue;
    final button = tester.widget<FilledButton>(finder);
    if (button.onPressed != null) {
      await tester.pumpAndSettle();
      return;
    }
  }
  fail('Draw button did not unlock after presentation');
}

void main() {
  testWidgets('story stays locked through reveal and success transition', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(412, 891);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = ScratchController(store: MemoryScratchStore(), random: () => 0);
    await c.load();
    await tester.pumpWidget(
      MaterialApp(
        theme: GameboxTheme.light(),
        home: ScratchPage(controller: c, socialApi: FakeSocial()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('scratch-primary')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(
      tester.widget<CardDrawStage>(find.byType(CardDrawStage)).onStory,
      isNull,
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      tester.widget<CardDrawStage>(find.byType(CardDrawStage)).onStory,
      isNull,
    );
    await waitForDrawReady(tester);
    expect(
      tester.widget<CardDrawStage>(find.byType(CardDrawStage)).onStory,
      isNotNull,
    );
    await tester.tap(find.byKey(const Key('draw-view-story')));
    await tester.pumpAndSettle();
    expect(find.text(c.cat.story), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });

  testWidgets('predictive back can cancel and commit after drawing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(412, 891);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = ScratchController(store: MemoryScratchStore(), random: () => 0);
    await c.load();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: GameboxTheme.light().copyWith(platform: TargetPlatform.android),
        home: const Scaffold(body: Text('Lobby')),
      ),
    );
    navigator.currentState!.push<void>(
      MaterialPageRoute(
        builder: (_) => ScratchPage(
          controller: c,
          socialApi: FakeSocial()..canSync = false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('scratch-primary')));
    await waitForDrawReady(tester);
    final total = c.total;
    Future<void> backEvent(String method, [double? progress]) async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        SystemChannels.backGesture.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall(
            method,
            progress == null
                ? null
                : <String, Object>{
                    'touchOffset': <double>[10 + progress * 200, 400],
                    'progress': progress,
                    'swipeEdge': 0,
                  },
          ),
        ),
        (_) {},
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    }

    await backEvent('startBackGesture', 0);
    await backEvent('updateBackGestureProgress', .4);
    await backEvent('cancelBackGesture');
    await tester.pumpAndSettle();
    expect(find.byType(ScratchPage), findsOneWidget);
    expect(c.total, total);
    await backEvent('startBackGesture', 0);
    await backEvent('updateBackGestureProgress', .7);
    await backEvent('commitBackGesture');
    await tester.pumpAndSettle();
    expect(find.text('Lobby'), findsOneWidget);
    expect(find.byType(ScratchPage), findsNothing);
    expect(c.total, total);
    c.dispose();
  });
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
    expect(find.text('偶得一句'), findsOneWidget);
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
      await waitForDrawReady(tester);
      final buttonRect = tester.getRect(
        find.byKey(const Key('scratch-primary')),
      );
      await tester.tap(find.byKey(const Key('scratch-primary')));
      await tester.pump();
      await tester.pump(cardRevealDuration(tier) * .45);
      expect(find.byKey(const Key('draw-card-front')), findsOneWidget);
      expect(
        find.ancestor(
          of: find.byKey(const Key('draw-card-front')),
          matching: find.byType(ScratchRevealEffect),
        ),
        findsOneWidget,
        reason:
            'Reveal light belongs around the whole card, not over the portrait',
      );
      expect(find.text('抽取中'), findsOneWidget);
      expect(find.text('正在翻牌'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('scratch-primary')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const Key('scratch-primary')));
      await tester.tap(find.byType(CardDrawStage));
      expect(c.serial, 1);
      await tester.pump(cardRevealDuration(tier));
      await tester.pumpAndSettle();
      expect(find.text('恭喜抽中'), findsOneWidget);
      expect(find.byKey(const Key('scratch-primary')), findsNothing);
      expect(
        tester.getRect(find.byKey(const Key('draw-congratulations'))),
        buttonRect,
      );
      expect(
        find.ancestor(
          of: find.text('恭喜抽中'),
          matching: find.byType(FilledButton),
        ),
        findsNothing,
      );
      await tester.tap(find.text('恭喜抽中'));
      expect(c.serial, 1);
      await waitForDrawReady(tester);
      expect(find.text('恭喜抽中'), findsNothing);
      expect(c.total, 1);
      expect(find.text('${scratchRarities[tier]}收藏'), findsOneWidget);
      expect(find.text('NEW'), findsOneWidget);
      await waitForDrawReady(tester);
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
      await waitForDrawReady(tester);
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
      await waitForDrawReady(tester);
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
          await waitForDrawReady(tester);
          await tester.tap(find.byKey(const Key('scratch-primary')));
          await tester.pumpAndSettle();
        }
        await waitForDrawReady(tester);
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
    'leaving during a pending draw ignores repeated taps; retry never duplicates',
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
      await waitForDrawReady(tester);
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
      await waitForDrawReady(tester);
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
