import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/features/scratch/scratch_catalog.dart';
import 'package:gamebox/features/scratch/scratch_surface.dart';

void main() {
  for (final size in [
    const Size(36, 48),
    const Size(48, 36),
    const Size(96, 96),
  ]) {
    testWidgets('atlas cell stays isolated in a $size viewport', (
      tester,
    ) async {
      for (final card in scratchCollectibles) {
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: SizedBox.fromSize(
                size: size,
                child: CollectibleArtwork(cat: card),
              ),
            ),
          ),
        );
        final artwork = find.byType(CollectibleArtwork);
        final viewport = tester.getRect(artwork);
        final clips = find.descendant(
          of: artwork,
          matching: find.byType(ClipRect),
        );
        expect(clips, findsNWidgets(2));
        final cell = tester.getRect(clips.last);
        expect(cell.width, cell.height);
        expect(cell.center, viewport.center);
        expect(cell.intersect(viewport), viewport);
        final atlas = tester.getRect(
          find.descendant(of: artwork, matching: find.byType(Image)),
        );
        final row = card.artIndex ~/ 4;
        final rows = card.artRows;
        final tileHeight =
            atlas.height * (rows[row + 1] - rows[row]) / rows.last;
        expect(tileHeight, closeTo(cell.height, .0001));
        expect(atlas.width / 4, cell.width);
        expect(
          atlas.top + atlas.height * rows[row] / rows.last,
          closeTo(cell.top, .0001),
        );
        expect(tester.takeException(), isNull);
      }
    });
  }
}
