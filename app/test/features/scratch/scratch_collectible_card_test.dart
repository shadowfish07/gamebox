import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/features/scratch/scratch_collectible_card.dart';
import 'package:gamebox/features/scratch/scratch_catalog.dart';
import 'package:gamebox/features/scratch/scratch_surface.dart';
import 'package:gamebox/design_system/gamebox_theme.dart';

void main() {
  for (final dark in [false, true]) {
    testWidgets(
      'tier footer and attached quantity tab; hidden artwork dark=$dark',
      (tester) async {
        for (var tier = 0; tier < 4; tier++) {
          final item = scratchCollectibles.firstWhere((c) => c.rarity == tier);
          var tapped = false;
          await tester.pumpWidget(
            MaterialApp(
              theme: dark ? GameboxTheme.dark() : GameboxTheme.light(),
              home: Center(
                child: SizedBox(
                  width: 156,
                  height: 156 / .74,
                  child: ScratchCollectibleCard(
                    item: item,
                    count: 12,
                    onTap: () => tapped = true,
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final material = tester.widget<Material>(
            find
                .descendant(
                  of: find.byType(ScratchCollectibleCard),
                  matching: find.byType(Material),
                )
                .first,
          );
          expect(material.color, ScratchArt.rarityColors[tier]);
          expect(find.text('×12'), findsOneWidget);
          expect(find.text(scratchRarities[tier]), findsOneWidget);
          final card = tester.getRect(find.byType(ScratchCollectibleCard));
          final art = tester.getRect(find.byType(CollectibleArtwork));
          expect(art.width, art.height);
          expect(art.topLeft, card.topLeft);
          expect(art.width, card.width);
          await tester.tap(find.text(item.job));
          expect(tapped, isTrue);
          expect(tester.takeException(), isNull);
        }
        var lockedTapped = false;
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: SizedBox(
                width: 156,
                height: 156 / .74,
                child: ScratchCollectibleCard(
                  item: scratchCollectibles.last,
                  count: 0,
                  onTap: () => lockedTapped = true,
                ),
              ),
            ),
          ),
        );
        expect(find.byType(CollectibleArtwork), findsNothing);
        expect(find.text('传说'), findsNothing);
        expect(find.text('未获得'), findsOneWidget);
        await tester.tap(find.byType(ScratchCollectibleCard));
        await tester.pumpAndSettle();
        expect(lockedTapped, isFalse);
      },
    );
  }
}
