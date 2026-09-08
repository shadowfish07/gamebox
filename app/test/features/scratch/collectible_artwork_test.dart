import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/features/scratch/scratch_catalog.dart';
import 'package:gamebox/features/scratch/scratch_surface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('published artwork cells match square source pixels', () async {
    final dimensions = <String, Size>{};
    final usedCells = <(String, int)>{};
    for (final card in scratchCollectibles) {
      final size = dimensions[card.imageAsset] ??= await () async {
        final data = await rootBundle.load(card.imageAsset);
        final codec = await ui.instantiateImageCodec(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
        try {
          final frame = await codec.getNextFrame();
          final size = Size(
            frame.image.width.toDouble(),
            frame.image.height.toDouble(),
          );
          frame.image.dispose();
          return size;
        } finally {
          codec.dispose();
        }
      }();
      final row = card.artIndex ~/ 4;
      expect(card.artRows.first, 0);
      expect(card.artRows.last, size.height);
      expect(
        card.artRows[row + 1] - card.artRows[row],
        size.width / 4,
        reason: '${card.groupId}/${card.index} must not stretch',
      );
      expect(
        usedCells.add((card.imageAsset, card.artIndex)),
        isTrue,
        reason: 'Every collectible needs its own artwork cell',
      );
    }
  });

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
