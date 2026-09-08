import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/features/scratch/blank_draw_card.dart';

void main() {
  test('blank style weights are 30/30/20/15/5, independent of prizes', () {
    final counts = List.filled(5, 0);
    for (var i = 0; i < 10000; i++) {
      counts[blankCardStyleForRoll(i / 10000)]++;
    }
    expect(counts, [3000, 3000, 2000, 1500, 500]);
    expect(blankCardStyleForRoll(.30), 1);
    expect(blankCardStyleForRoll(.60), 2);
    expect(blankCardStyleForRoll(.80), 3);
    expect(blankCardStyleForRoll(.95), 4);
  });
}
