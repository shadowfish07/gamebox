import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/features/scratch/card_draw_preview.dart';

void main() {
  test(
    'preview repeats blank, rare, epic, legendary without saving misses',
    () async {
      final controller = createCardDrawPreviewController();
      addTearDown(controller.dispose);
      await controller.load();
      for (var cycle = 0; cycle < 2; cycle++) {
        for (var tier = 0; tier < 4; tier++) {
          final result = (await controller.draw())!;
          expect(result.winning, tier != 0);
          if (tier != 0) {
            expect(result.card.rarity, tier);
            expect(result.count, cycle + 1);
            expect(result.isNew, cycle == 0);
          } else {
            expect(result.count, 0);
          }
        }
      }
      expect(controller.total, 6);
      final reopened = createCardDrawPreviewController();
      addTearDown(reopened.dispose);
      await reopened.load();
      expect(reopened.total, 0);
      expect((await reopened.draw())!.winning, isFalse);
    },
  );

  test('preview has no remote collection', () async {
    const social = CardDrawPreviewSocialApi();
    expect(social.canSync, isFalse);
    expect((await social.list()).players, isEmpty);
  });
}
