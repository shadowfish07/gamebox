import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/design_system/gamebox_theme.dart';
import 'package:gamebox/features/scratch/scratch_card_detail.dart';
import 'package:gamebox/features/scratch/scratch_controller.dart';
import 'package:gamebox/features/scratch/scratch_page.dart';

import 'scratch_controller_test.dart' show MemoryScratchStore;
import 'scratch_social_test.dart' show FakeSocial;

void main() {
  for (final systemBack in [true, false]) {
    testWidgets('series Back returns to draw before lobby system=$systemBack', (
      tester,
    ) async {
      final c = ScratchController(store: MemoryScratchStore(), random: () => 0);
      await c.load();
      await c.draw();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          theme: GameboxTheme.light(),
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
      await tester.tap(find.text('查看故事'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('scratch-view-series')));
      await tester.pumpAndSettle();
      expect(find.text('收藏图鉴'), findsOneWidget);
      Future<void> back() async {
        if (systemBack) {
          await tester.binding.handlePopRoute();
        } else {
          await tester.tap(find.byKey(const Key('scratch-back')));
        }
        await tester.pumpAndSettle();
      }

      await back();
      expect(find.byType(ScratchPage), findsOneWidget);
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        0,
      );
      expect(find.text('查看故事'), findsOneWidget);
      expect(c.total, 1);
      await back();
      expect(find.text('Lobby'), findsOneWidget);
      expect(find.byType(ScratchPage), findsNothing);
      c.dispose();
    });
  }
  for (final destination in ['album', 'players']) {
    testWidgets('Back from $destination retains unsaved progress', (
      tester,
    ) async {
      final store = MemoryScratchStore();
      final c = ScratchController(store: store, random: () => 0);
      await c.load();
      store.fail = true;
      await c.draw();
      await tester.pumpWidget(
        MaterialApp(
          theme: GameboxTheme.light(),
          home: ScratchPage(
            controller: c,
            socialApi: FakeSocial()..canSync = false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('scratch-tab-$destination')));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        0,
      );
      expect(find.byType(AlertDialog), findsNothing);
      expect(c.unsaved, isTrue);
      expect(c.total, 1);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('离开并放弃未保存的进度？'), findsOneWidget);
      await tester.tap(find.text('留下重试'));
      await tester.pumpAndSettle();
      expect(find.byType(ScratchPage), findsOneWidget);
      expect(c.unsaved, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    });
  }
  for (final cardIndex in [0, 24]) {
    for (final fromDraw in [false, true]) {
      testWidgets(
        'series link opens full group $cardIndex fromDraw=$fromDraw',
        (tester) async {
          tester.view.physicalSize = const Size(360, 640);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          var roll = 0;
          final c = ScratchController(
            store: MemoryScratchStore(),
            random: () => [0.0, 0.0, cardIndex == 0 ? 0.0 : .5][roll++ % 3],
          );
          await c.load();
          await c.draw();
          await tester.pumpWidget(
            MaterialApp(
              theme: fromDraw ? GameboxTheme.dark() : GameboxTheme.light(),
              home: ScratchPage(
                controller: c,
                socialApi: FakeSocial()..canSync = false,
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('scratch-tab-album')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('已拥有'));
          await tester.tap(find.widgetWithText(ChoiceChip, '普通'));
          await tester.pumpAndSettle();
          if (fromDraw) {
            await tester.tap(find.byKey(const Key('scratch-tab-play')));
            await tester.pumpAndSettle();
            await tester.tap(find.text('查看故事'));
          } else {
            await tester.tap(find.byKey(ValueKey('scratch-cat-$cardIndex')));
          }
          await tester.pumpAndSettle();
          expect(find.byType(ScratchCardDetail), findsOneWidget);
          final link = find.byKey(const Key('scratch-view-series'));
          final seriesCenter = tester.getCenter(link);
          await tester.tapAt(seriesCenter);
          await tester.tapAt(seriesCenter);
          await tester.pumpAndSettle();
          expect(find.byType(ScratchCardDetail), findsNothing);
          expect(
            tester
                .widget<NavigationBar>(find.byType(NavigationBar))
                .selectedIndex,
            1,
          );
          final group = cardIndex == 0 ? '猫猫百业' : '狗狗百业';
          final selected = tester
              .widgetList<ChoiceChip>(find.byType(ChoiceChip))
              .where((chip) => chip.selected);
          expect(
            selected.map((chip) => (chip.label as Text).data),
            containsAll(['$group 1/24', '全部']),
          );
          final groupBounds = tester.getRect(
            find.widgetWithText(ChoiceChip, '$group 1/24'),
          );
          expect(groupBounds.left, greaterThanOrEqualTo(0));
          expect(groupBounds.right, lessThanOrEqualTo(360));
          expect(
            tester.widget<FilterChip>(find.byType(FilterChip)).selected,
            isFalse,
          );
          expect(
            find.byKey(ValueKey('scratch-cat-$cardIndex')),
            findsOneWidget,
          );
          expect(
            find.byKey(ValueKey('scratch-cat-${cardIndex + 1}')),
            findsOneWidget,
          );
          expect(
            find.byKey(ValueKey('scratch-cat-${cardIndex == 0 ? 24 : 0}')),
            findsNothing,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          c.dispose();
        },
      );
    }
  }
}
