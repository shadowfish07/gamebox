import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/features/scratch/blank_draw_card.dart';

void main() {
  test('offline catalog contains exactly 2000 sourced unique couplets', () {
    final catalog = jsonDecode(
      File('../docs/design/cat-scratch/poetry-library.json').readAsStringSync(),
    ) as Map;
    final entries = (catalog['entries'] as List).cast<Map>();
    expect(blankCardPoems, entries.map((e) => e['text']).toList());
    expect(blankCardPoems.length, 2000);
    final keys = blankCardPoems
        .map((p) => p.replaceAll(RegExp(r'[^\u4e00-\u9fff]'), ''))
        .toSet();
    expect(keys.length, 2000);
    for (final poem in blankCardPoems) {
      final lines = poem.split('\n');
      expect(lines.length, 2);
      expect([6, 8], contains(lines.first.length));
      expect(lines.last.length, lines.first.length);
      expect(entries[blankCardPoems.indexOf(poem)]['source'], isNotEmpty);
    }
    final reachable = {
      for (var serial = 1; serial <= 50000; serial++) blankCardPoem(serial),
    };
    expect(reachable.length, 2000);
  });
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
