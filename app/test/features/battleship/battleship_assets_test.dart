import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'all fleet sprites decode from the app bundle with transparency',
    (tester) async {
      await tester.runAsync(() async {
        for (final name in [
          'carrier',
          'battleship',
          'cruiser',
          'submarine',
          'destroyer',
        ]) {
          final data = await rootBundle.load('assets/battleship/$name.webp');
          final codec = await ui.instantiateImageCodec(
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          );
          final image = (await codec.getNextFrame()).image;
          try {
            expect(image.width, 512, reason: name);
            expect(image.height, 512, reason: name);
            final rgba = (await image.toByteData())!;
            var transparent = false, opaque = false;
            for (var offset = 3; offset < rgba.lengthInBytes; offset += 4) {
              transparent |= rgba.getUint8(offset) == 0;
              opaque |= rgba.getUint8(offset) == 255;
            }
            expect(
              transparent && opaque,
              isTrue,
              reason: '$name silhouette alpha',
            );
          } finally {
            image.dispose();
            codec.dispose();
          }
        }
      });
    },
  );
}
