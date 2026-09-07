import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/design_system/gamebox_theme.dart';
import 'package:gamebox/features/scratch/scratch_controller.dart';
import 'package:gamebox/features/scratch/scratch_page.dart';
import 'package:gamebox/features/scratch/scratch_surface.dart';

import 'scratch_controller_test.dart' show MemoryScratchStore;

void main() {
  for (final (roll, tier) in [(0.0, 0), (.8, 1), (.96, 2), (.999, 3)]) {
    testWidgets(
      'rarity $tier appears only after claiming and clears on next ticket',
      (tester) async {
        final controller = ScratchController(
          store: MemoryScratchStore(),
          random: () => roll,
        );
        await controller.load();
        await tester.pumpWidget(
          MaterialApp(
            theme: GameboxTheme.light(),
            home: ScratchPage(controller: controller),
          ),
        );
        expect(find.byKey(const Key('scratch-rarity-banner')), findsNothing);
        await controller.changeMode(ScratchMode.career);
        await controller.open(0);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('scratch-rarity-banner')), findsNothing);
        await controller.open(1);
        await tester.pumpAndSettle();
        final banner = tester.widget<DecoratedBox>(
          find.byKey(const Key('scratch-rarity-banner')),
        );
        expect(
          (banner.decoration as BoxDecoration).color,
          ScratchArt.rarityColors[tier],
        );
        expect(find.text('${scratchRarities[tier]}收藏'), findsOneWidget);
        await controller.next();
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('scratch-rarity-banner')), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      },
    );
  }

  for (final size in [const Size(360, 640), const Size(412, 891)]) {
    for (final dark in [false, true]) {
      testWidgets(
        'phone $size dark=$dark keeps ticket and action visible in all modes',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
          addTearDown(tester.view.reset);
          final controller = ScratchController(
            store: MemoryScratchStore(),
            random: () => 0,
          );
          await controller.load();
          await tester.pumpWidget(
            MaterialApp(
              theme: dark ? GameboxTheme.dark() : GameboxTheme.light(),
              home: ScratchPage(controller: controller),
            ),
          );
          await tester.pumpAndSettle();
          for (final mode in ScratchMode.values) {
            await tester.tap(find.text(mode.label));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            final button = tester.getRect(
              find.byKey(const Key('scratch-primary')),
            );
            expect(button.top, greaterThan(24));
            expect(button.bottom, lessThan(size.height - 24));
            final surface = tester.getRect(find.byType(ScratchSurface).first);
            expect(surface.top, greaterThan(24));
            expect(surface.bottom, lessThan(button.top));
            if (mode == ScratchMode.career) {
              expect(surface.width, greaterThanOrEqualTo(100));
            }
          }
          await tester.tap(find.byKey(const Key('scratch-primary')));
          await tester.pumpAndSettle();
          expect(controller.total, 1);
          expect(find.text('再来一张'), findsOneWidget);
          await tester.tap(find.byKey(const Key('scratch-detail')));
          await tester.pumpAndSettle();
          expect(find.text('面包师 · 小麦'), findsNWidgets(2));
          await tester.tap(find.byKey(const Key('scratch-favorite')));
          await tester.pumpAndSettle();
          expect(controller.favorites, [0]);
          await tester.tap(find.byTooltip('关闭详情'));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('scratch-tab-album')));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.tap(find.byKey(const Key('scratch-tab-showcase')));
          await tester.pumpAndSettle();
          expect(find.text('面包师'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          controller.dispose();
        },
      );
    }
  }

  testWidgets(
    'real pointer strokes reveal once; partial strokes survive tab navigation',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = MemoryScratchStore();
      final controller = ScratchController(store: store, random: () => 0);
      await controller.load();
      await tester.pumpWidget(
        MaterialApp(
          theme: GameboxTheme.light(),
          home: ScratchPage(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      final r = tester.getRect(find.byType(ScratchSurface));
      await tester.dragFrom(
        Offset(r.left + r.width * .1, r.top + r.height * .1),
        Offset(r.width * .8, 0),
      );
      await tester.pumpAndSettle();
      expect(controller.masks[0].coverage, greaterThan(0));
      expect(controller.total, 0);
      final before = controller.masks[0].coverage;
      await tester.tap(find.byKey(const Key('scratch-tab-album')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('scratch-tab-play')));
      await tester.pumpAndSettle();
      expect(controller.masks[0].coverage, before);
      for (var y = .25; y < 1 && !controller.claimed; y += .13) {
        await tester.dragFrom(
          Offset(r.left + r.width * .06, r.top + r.height * y),
          Offset(r.width * .88, 0),
        );
        await tester.pumpAndSettle();
      }
      expect(controller.total, 1);
      expect(find.byType(ScratchSurface), findsNothing);
      final restored = ScratchController(store: store);
      await restored.load();
      expect(restored.total, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      restored.dispose();
    },
  );
}
