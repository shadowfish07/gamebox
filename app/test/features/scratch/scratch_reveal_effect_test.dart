import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/features/scratch/scratch_reveal_effect.dart';
import 'package:gamebox/features/scratch/scratch_controller.dart';
import 'package:gamebox/features/scratch/scratch_page.dart';

import 'scratch_controller_test.dart' show MemoryScratchStore;
import 'scratch_social_test.dart' show FakeSocial;

void main() {
  for (var tier = 0; tier < 4; tier++) {
    testWidgets('production page binds fresh tier $tier to its celebration', (
      tester,
    ) async {
      var draw = 0;
      final controller = ScratchController(
        store: MemoryScratchStore(),
        random: () => draw++ % 3 == 1 ? [0.0, .8, .96, .999][tier] : 0,
      );
      await controller.load();
      await tester.pumpWidget(
        MaterialApp(
          home: ScratchPage(
            controller: controller,
            socialApi: FakeSocial()..canSync = false,
          ),
        ),
      );
      expect(find.byKey(const Key('scratch-reveal-burst')), findsNothing);
      await tester.tap(find.byKey(const Key('scratch-primary')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        tester
            .widget<ScratchRevealEffect>(find.byType(ScratchRevealEffect))
            .rarity,
        tier,
      );
      expect(find.byKey(const Key('scratch-reveal-burst')), findsOneWidget);
      await tester.tap(find.byKey(const Key('scratch-primary')));
      await tester.pumpAndSettle();
      expect(controller.claimed, isFalse);
      expect(find.byKey(const Key('scratch-reveal-burst')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });
  }
  for (var tier = 0; tier < 4; tier++) {
    testWidgets('tier $tier celebrates once and never blocks input', (
      tester,
    ) async {
      var taps = 0;
      Widget page(bool revealed, {int serial = 1}) => MaterialApp(
        home: Center(
          child: SizedBox(
            width: 280,
            height: 280,
            child: ScratchRevealEffect(
              key: ValueKey(serial),
              revealed: revealed,
              rarity: tier,
              child: GestureDetector(
                onTap: () => taps++,
                child: const ColoredBox(color: Colors.white),
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(page(false));
      expect(find.byKey(const Key('scratch-reveal-burst')), findsNothing);
      await tester.pumpWidget(page(true));
      await tester.pump(const Duration(milliseconds: 180));
      expect(find.byKey(const Key('scratch-reveal-burst')), findsOneWidget);
      await tester.tap(find.byType(ScratchRevealEffect));
      expect(taps, 1);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('scratch-reveal-burst')), findsNothing);
      await tester.pumpWidget(page(true));
      expect(find.byKey(const Key('scratch-reveal-burst')), findsNothing);
      await tester.pumpWidget(page(false, serial: 2));
      expect(find.byKey(const Key('scratch-reveal-burst')), findsNothing);
      await tester.pumpWidget(page(true, serial: 2));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpWidget(page(false, serial: 3));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('scratch-reveal-burst')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('restored result does not replay celebration', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: ScratchRevealEffect(
          revealed: true,
          rarity: 3,
          child: SizedBox(width: 200, height: 200),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const Key('scratch-reveal-burst')), findsNothing);
  });
}
