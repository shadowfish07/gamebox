import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/features/scratch/card_draw_flow.dart';
import 'package:gamebox/design_system/generated/gamebox_tokens.g.dart';
import 'package:gamebox/features/scratch/scratch_controller.dart';

import 'scratch_controller_test.dart' show MemoryScratchStore;

void main() {
  testWidgets('restored receipt stays out of current session history', (
    tester,
  ) async {
    final c = ScratchController(store: MemoryScratchStore(), random: () => 0);
    await c.load();
    await c.draw();
    final restoredSerial = c.serial;
    final f = CardDrawFlow(c);
    f.primary();
    await tester.pump(GameboxTokens.motion.standard);
    await tester.pump();
    expect(f.recent, isEmpty);
    expect(f.current!.serial, restoredSerial + 1);
    f.finishReveal();
    await tester.pump(CardDrawFlow.celebrationDuration);
    await tester.pump(GameboxTokens.motion.standard);
    f.primary();
    await tester.pump(GameboxTokens.motion.standard);
    await tester.pump();
    expect(f.recent.single.serial, restoredSerial + 1);
    f.dispose();
    c.dispose();
  });

  testWidgets('miss retry does not reroll and next win alone enters recent', (
    tester,
  ) async {
    var roll = .9;
    final store = MemoryScratchStore();
    final c = ScratchController(store: store, random: () => roll);
    await c.load();
    final f = CardDrawFlow(c);
    store.fail = true;
    f.primary();
    await tester.pump();
    expect(f.phase, CardDrawPhase.failed);
    expect(c.total, 0);
    roll = 0;
    store.fail = false;
    await f.retry();
    expect(f.current!.winning, isFalse);
    f.finishReveal();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(GameboxTokens.motion.standard);
    f.primary();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(f.current!.winning, isTrue);
    expect(f.recent, isEmpty);
    expect(c.total, 1);
    f.finishReveal();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(GameboxTokens.motion.standard);
    f.primary();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(f.recent.length, 1);
    expect(f.recent.single.winning, isTrue);
    f.dispose();
    c.dispose();
  });
  testWidgets(
    'rapid taps are ignored throughout saving, reveal, celebration and return',
    (tester) async {
      final store = MemoryScratchStore();
      final c = ScratchController(store: store, random: () => 0);
      await c.load();
      final f = CardDrawFlow(c);
      store.pending = Completer<void>();
      f.primary();
      for (var i = 0; i < 30; i++) {
        f.primary();
      }
      expect(c.total, 1);
      expect(f.phase, CardDrawPhase.saving);
      store.pending!.complete();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(c.total, 1);
      for (var i = 0; i < 30; i++) {
        f.primary();
      }
      expect(f.phase, CardDrawPhase.revealing);
      f.finishReveal();
      expect(f.phase, CardDrawPhase.celebrating);
      f.primary();
      await tester.pump(CardDrawFlow.celebrationDuration);
      expect(f.phase, CardDrawPhase.returning);
      f.primary();
      expect(c.total, 1);
      await tester.pump(GameboxTokens.motion.standard);
      expect(f.canDraw, isTrue);
      await tester.pump(const Duration(seconds: 10));
      expect(c.total, 1);
      f.primary();
      f.primary();
      await tester.pump(const Duration(seconds: 1));
      expect(c.total, 2);
      f.dispose();
      c.dispose();
    },
  );
  testWidgets(
    'no unattended draws; recent receipts are immutable and bounded',
    (tester) async {
      final c = ScratchController(store: MemoryScratchStore(), random: () => 0);
      await c.load();
      final f = CardDrawFlow(c);
      for (var i = 0; i < 9; i++) {
        f.primary();
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        f.finishReveal();
        await tester.pump(const Duration(seconds: 10));
        await tester.pump(GameboxTokens.motion.standard);
        expect(c.total, i + 1);
      }
      expect(f.recent.length, 6);
      expect(f.recent.first.count, 8);
      expect(f.recent.last.count, 3);
      f.dispose();
      c.dispose();
    },
  );
  testWidgets('background prevents continuation but preserves current award', (
    tester,
  ) async {
    final store = MemoryScratchStore();
    final c = ScratchController(store: store, random: () => 0);
    await c.load();
    final f = CardDrawFlow(c);
    store.pending = Completer<void>();
    f.primary();
    f.primary();
    f.suspend();
    store.pending!.complete();
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(c.total, 1);
    expect(f.canDraw, isFalse);
    f.resume();
    await tester.pump(const Duration(seconds: 10));
    expect(c.total, 1);
    f.dispose();
    c.dispose();
  });
  testWidgets(
    'save failure ignores repeated taps; retry reveals the same award',
    (tester) async {
      final store = MemoryScratchStore();
      final c = ScratchController(store: store, random: () => 0);
      await c.load();
      final f = CardDrawFlow(c);
      store.fail = true;
      f.primary();
      f.primary();
      await tester.pump();
      expect(f.phase, CardDrawPhase.failed);
      expect(c.total, 1);
      f.primary();
      await tester.pump(const Duration(seconds: 5));
      expect(c.total, 1);
      store.fail = false;
      await f.retry();
      expect(f.phase, CardDrawPhase.revealing);
      f.finishReveal();
      await tester.pump(const Duration(seconds: 5));
      expect(c.total, 1);
      f.dispose();
      c.dispose();
    },
  );
}
