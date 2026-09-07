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
  for (final (roll, wins) in [
    (0.0, true),
    (.199999, true),
    (.2, false),
    (.999999, false),
  ]) {
    test('20 percent award boundary $roll persists outcome', () async {
      var calls = 0;
      final store = MemoryScratchStore();
      final c = ScratchController(
        store: store,
        random: () => calls++ % 3 == 0 ? roll : 0,
      );
      await c.load();
      final result = (await c.draw())!;
      expect(result.winning, wins);
      expect(result.isNew, wins);
      expect(result.count, wins ? 1 : 0);
      expect(c.total, wins ? 1 : 0);
      expect(c.firstFound.whereType<String>().length, wins ? 1 : 0);
      final restored = ScratchController(
        store: store,
        random: () => throw StateError('must not reroll'),
      );
      await restored.load();
      expect(restored.error, isNull);
      expect(restored.lastResult!.winning, wins);
      expect(restored.serial, c.serial);
      c.dispose();
      restored.dispose();
    });
  }
  for (final claimed in [false, true]) {
    test(
      'v2 migration preserves awards and restores chance for pending draw $claimed',
      () async {
        final store = MemoryScratchStore()
          ..value = jsonEncode({
            ...legacyScratchSave(claimed: claimed),
            'version': 2,
          });
        final c = ScratchController(store: store, random: () => .9);
        await c.load();
        expect(c.error, isNull);
        expect(c.total, 1);
        expect(c.winning, claimed);
        final restored = ScratchController(
          store: store,
          random: () => throw StateError('reroll'),
        );
        await restored.load();
        expect(restored.error, isNull);
        expect(restored.winning, claimed);
        if (!claimed) {
          await restored.draw();
          expect(restored.total, 1);
          expect(restored.lastResult!.winning, isFalse);
        }
        c.dispose();
        restored.dispose();
      },
    );
  }
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
    test('winning draw awards one card at rarity boundary $roll', () async {
      var calls = 0;
      final c = ScratchController(
        store: MemoryScratchStore(),
        random: () => [0.0, roll, .99][calls++ % 3],
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
    expect((jsonDecode(store.value!) as Map)['version'], 3);
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
            expect(c.claimed, claimed);
            expect(c.winning, winning);
            expect(c.cat.index, 0);
            if (!c.claimed) {
              final result = await c.draw();
              expect(result!.card.index, 0);
              expect(result.winning, winning);
              expect(c.counts[0], winning ? 2 : 1);
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
