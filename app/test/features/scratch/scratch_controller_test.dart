import 'dart:async';

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
  test('all rarity boundaries and 24 members are reachable', () {
    expect(scratchCats.length, 24);
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
        drawScratchCat(() {
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

  test('changing mode keeps reward; career requires clue and paws require all regions', () async {
    final controller = ScratchController(
      store: MemoryScratchStore(),
      random: () => 0,
    );
    await controller.load();
    final cat = controller.cat;
    await controller.changeMode(ScratchMode.career);
    expect(controller.cat, cat);
    await controller.open(1);
    expect(controller.opened, isEmpty);
    await controller.open(0);
    expect(controller.claimed, isFalse);
    await controller.open(1);
    expect(controller.total, 1);
    await controller.next();
    await controller.changeMode(ScratchMode.paws);
    for (var i = 0; i < 3; i++) {
      await controller.open(i);
    }
    expect(controller.claimed, isFalse);
    await controller.open(3);
    expect(controller.total, 2);
    controller.dispose();
  });

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

  test(
    'corrupt saves are preserved; unowned cats cannot enter showcase',
    () async {
      final store = MemoryScratchStore()..value = '{bad';
      final controller = ScratchController(store: store);
      await controller.load();
      expect(controller.error, isNotNull);
      expect(store.value, '{bad');
      expect(await controller.favorite(0), '先通过刮奖获得这只猫猫');
      controller.dispose();
    },
  );

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
