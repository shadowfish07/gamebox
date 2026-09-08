import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/features/scratch/blank_draw_card.dart';

void main() {
  testWidgets('poem fits compact card without attribution and remains stable', (
    tester,
  ) async {
    for (var serial = 1; serial <= 20; serial++) {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 110,
              height: 150,
              child: BlankDrawCard(serial: serial),
            ),
          ),
        ),
      );
      expect(find.text(blankCardPoem(serial)), findsOneWidget);
      expect(find.text('偶得一句'), findsOneWidget);
      expect(find.text('空白卡'), findsNothing);
      expect(find.textContaining('王维'), findsNothing);
      expect(tester.takeException(), isNull);
      final poem = tester.widget<Text>(
        find.byKey(const Key('blank-card-poem')),
      );
      expect(poem.style!.fontFamily, 'LXGWWenKai');
      expect(
        poem.style!.fontSize,
        Theme.of(tester.element(find.byKey(const Key('blank-card-poem'))))
            .textTheme
            .bodyLarge!
            .fontSize,
      );
    }
  });
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
