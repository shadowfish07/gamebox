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

void main() {
  for (final roll in [0.19999, 0.2, 0.999]) {
    test(
      'winning boundary $roll persists miss and never adds a collectible',
      () async {
        final store = MemoryScratchStore();
        final controller = ScratchController(store: store, random: () => roll);
        await controller.load();
        expect(controller.winning, roll < .2);
        final restored = ScratchController(store: store, random: () => 0);
        await restored.load();
        expect(restored.winning, controller.winning);
        await restored.revealAll();
        await restored.revealAll();
        expect(restored.total, roll < .2 ? 1 : 0);
        final result = ScratchController(store: store);
        await result.load();
        expect(result.claimed, isTrue);
        expect(result.winning, roll < .2);
        expect(result.total, restored.total);
        controller.dispose();
        restored.dispose();
        result.dispose();
      },
    );
  }
  test(
    'finishing a stroke while a prior save is pending still claims once',
    () async {
      final store = MemoryScratchStore();
      final controller = ScratchController(store: store, random: () => 0);
      await controller.load();
      store.pending = Completer<void>();
      final partialSave = controller.persist();
      final completion = controller.open(0);
      expect(controller.claimed, isTrue);
      expect(controller.total, 1);
      store.pending!.complete();
      await partialSave;
      await completion;
      final restored = ScratchController(store: store);
      await restored.load();
      expect(restored.total, 1);
      expect(restored.claimed, isTrue);
      controller.dispose();
      restored.dispose();
    },
  );
  test('all rarity boundaries and 48 members are reachable', () {
    expect(scratchCollectibles.length, 48);
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
      final values = [roll, .99].iterator;
      expect(
        drawScratchCollectible(() {
          values.moveNext();
          return values.current;
        }).rarity,
        tier,
      );
    }
  });

  test('scratch completes once; duplicates increase count only; restore retains result', () async {
    final store = MemoryScratchStore();
    final controller = ScratchController(store: store, random: () => 0);
    await controller.load();
    await controller.revealAll();
    await controller.revealAll();
    expect(controller.total, 1);
    expect(controller.collected, 1);
    await controller.next();
    await controller.revealAll();
    expect(controller.total, 2);
    expect(controller.collected, 1);
    final restored = ScratchController(store: store);
    await restored.load();
    expect(restored.claimed, isTrue);
    await restored.revealAll();
    expect(restored.total, 2);
    controller.dispose();
    restored.dispose();
  });

  for (final legacyMode in [0, 1, 2]) {
    for (final claimed in [false, true]) {
      test(
        'legacy mode $legacyMode claimed=$claimed preserves collection and prize',
        () async {
          final store = MemoryScratchStore();
          final original = ScratchController(store: store, random: () => 0);
          await original.load();
          await original.revealAll();
          original.favorites.add(0);
          await original.persist();
          if (!claimed) await original.next();
          final data = jsonDecode(store.value!) as Map<String, dynamic>;
          data.remove('winning');
          data['mode'] = legacyMode;
          data['opened'] = claimed
              ? List.generate([1, 4, 2][legacyMode], (i) => i)
              : legacyMode == 0
              ? []
              : [0];
          data['strokes'] = List.generate(
            4,
            (_) => [
              [.1, .1, .8, .1, .085],
            ],
          );
          store.value = jsonEncode(data);
          final restored = ScratchController(store: store, random: () => .999);
          await restored.load();
          expect(restored.error, isNull);
          expect(restored.cat.index, 0);
          expect(restored.total, 1);
          expect(restored.favorites, [0]);
          expect(restored.firstFound, original.firstFound);
          expect(restored.serial, original.serial);
          expect(restored.claimed, claimed);
          expect(
            restored.masks[0].coverage,
            legacyMode == 0 ? greaterThan(0) : 0,
          );
          await restored.revealAll();
          expect(restored.total, claimed ? 1 : 2);
          final reloaded = ScratchController(store: store);
          await reloaded.load();
          expect(reloaded.error, isNull);
          expect(reloaded.total, restored.total);
          original.dispose();
          restored.dispose();
          reloaded.dispose();
        },
      );
    }
  }

  test(
    'failed write keeps one award pending and retry never awards again',
    () async {
      final store = MemoryScratchStore();
      final controller = ScratchController(store: store, random: () => 0);
      await controller.load();
      store.fail = true;
      await controller.revealAll();
      expect(controller.error, isNotNull);
      expect(controller.unsaved, isTrue);
      await controller.next();
      expect(controller.total, 1);
      store.fail = false;
      await controller.retry();
      expect(controller.unsaved, isFalse);
      final restored = ScratchController(store: store);
      await restored.load();
      expect(restored.total, 1);
      controller.dispose();
      restored.dispose();
    },
  );

  test('corrupt saves are preserved', () async {
    final store = MemoryScratchStore()..value = '{bad';
    final controller = ScratchController(store: store);
    await controller.load();
    expect(controller.error, isNotNull);
    expect(store.value, '{bad');
    controller.dispose();
  });

  test('coverage counts unique erased area, and normal strokes can finish', () {
    final mask = ScratchMask();
    for (var i = 0; i < 100; i++) {
      mask.erase(.1, .1, .9, .1);
    }
    expect(mask.coverage, lessThan(.2));
    for (var y = .05; y < 1; y += .1) {
      mask.erase(.05, y, .95, y);
    }
    expect(mask.coverage, greaterThan(.65));
    expect(mask.strokes.length, lessThan(20));
    mask.dispose();
  });
}
