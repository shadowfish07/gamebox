import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/features/scratch/scratch_controller.dart';

class MemoryScratchStore implements ScratchStore {
  String? value;
  bool fail = false;
  Completer<void>? pending;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String value) async {
    await pending?.future;
    if (fail) throw StateError('storage unavailable');
    this.value = value;
  }
}

Map<String, Object?> legacyScratchSave({
  int mode = 0,
  bool claimed = false,
  bool winning = true,
  int size = 48,
}) => {
  'version': 1,
  'counts': [1, ...List.filled(size - 1, 0)],
  'firstFound': [
    DateTime(2026).toIso8601String(),
    ...List<String?>.filled(size - 1, null),
  ],
  'favorites': [0],
  'cat': 0,
  'mode': mode,
  'winning': winning,
  'claimed': claimed,
  'isNew': claimed && winning,
  'serial': 7,
  'opened': claimed ? List.generate([1, 4, 2][mode], (i) => i) : <int>[],
  'strokes': List.generate(
    4,
    (_) => [
      [.1, .1, .8, .1, .085],
    ],
  ),
};

void main() {
  for (final (roll, tier) in [
    (0.0, 0),
    (.69999, 0),
    (.7, 1),
    (.93999, 1),
    (.94, 2),
    (.99499, 2),
    (.995, 3),
    (.99999, 3),
  ]) {
    test('every draw awards one card at rarity boundary $roll', () async {
      var calls = 0;
      final c = ScratchController(
        store: MemoryScratchStore(),
        random: () => calls++ % 2 == 0 ? roll : .99,
      );
      await c.load();
      final result = await c.draw();
      expect(result!.card.rarity, tier);
      expect(c.total, 1);
      expect(result.isNew, isTrue);
      c.dispose();
    });
  }
  test('one durable write per draw; duplicate increases quantity only; reload never reclaims', () async {
    final store = MemoryScratchStore();
    final c = ScratchController(store: store, random: () => 0);
    await c.load();
    final first = await c.draw();
    final second = await c.draw();
    expect(first!.isNew, isTrue);
    expect(second!.isNew, isFalse);
    expect(second.count, 2);
    expect(c.total, 2);
    expect(c.collected, 1);
    final restored = ScratchController(store: store);
    await restored.load();
    expect(restored.total, 2);
    expect(restored.lastResult!.serial, second.serial);
    expect(restored.lastResult!.isNew, isFalse);
    expect((jsonDecode(store.value!) as Map)['version'], 2);
    c.dispose();
    restored.dispose();
  });
  test(
    'concurrent draw during save cannot award or reroll another card',
    () async {
      final store = MemoryScratchStore();
      final c = ScratchController(store: store, random: () => 0);
      await c.load();
      store.pending = Completer<void>();
      final first = c.draw();
      expect(await c.draw(), isNull);
      expect(c.total, 1);
      store.pending!.complete();
      await first;
      expect(c.total, 1);
      c.dispose();
    },
  );
  for (final mode in [0, 1, 2]) {
    for (final claimed in [false, true]) {
      for (final winning in [false, true]) {
        test(
          'legacy mode $mode claimed=$claimed winning=$winning migrates without lost or extra awards',
          () async {
            final store = MemoryScratchStore()
              ..value = jsonEncode(
                legacyScratchSave(
                  mode: mode,
                  claimed: claimed,
                  winning: winning,
                ),
              );
            final c = ScratchController(store: store, random: () => .999);
            await c.load();
            expect(c.error, isNull);
            expect(c.total, 1);
            expect(c.favorites, [0]);
            expect(c.firstFound[0], DateTime(2026).toIso8601String());
            expect(c.claimed, claimed && winning);
            expect(c.cat.index, 0);
            if (!c.claimed) {
              final result = await c.draw();
              expect(result!.card.index, 0);
              expect(c.counts[0], 2);
            }
            final restored = ScratchController(store: store);
            await restored.load();
            expect(restored.total, c.total);
            c.dispose();
            restored.dispose();
          },
        );
      }
    }
  }
  test(
    'failed save blocks new draws; retry preserves exact pending result',
    () async {
      final store = MemoryScratchStore();
      final c = ScratchController(store: store, random: () => 0);
      await c.load();
      store.fail = true;
      final result = await c.draw();
      expect(c.unsaved, isTrue);
      expect(await c.draw(), isNull);
      expect(c.total, 1);
      store.fail = false;
      await c.retry();
      expect(c.lastResult!.serial, result!.serial);
      expect(c.total, 1);
      expect(c.unsaved, isFalse);
      c.dispose();
    },
  );
  for (final value in [
    '{bad',
    jsonEncode({
      ...legacyScratchSave(),
      'strokes': [
        [
          [double.maxFinite],
        ],
        [],
        [],
        [],
      ],
    }),
  ]) {
    test('corrupt save is preserved ${value.length}', () async {
      final store = MemoryScratchStore()..value = value;
      final c = ScratchController(store: store);
      await c.load();
      expect(c.error, isNotNull);
      expect(store.value, value);
      expect(c.total, 0);
      c.dispose();
    });
  }
}
