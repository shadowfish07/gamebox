import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/design_system/gamebox_theme.dart';
import 'package:gamebox/features/scratch/scratch_controller.dart';
import 'package:gamebox/features/scratch/scratch_page.dart';
import 'package:gamebox/features/scratch/scratch_social_api.dart';
import 'package:gamebox/features/scratch/scratch_surface.dart';

import 'scratch_controller_test.dart'
    show MemoryScratchStore, legacyScratchSave;
import 'scratch_social_test.dart' show FakeSocial;

void main() {
  test(
    'both series have stable indices, tier counts, and reachable prizes',
    () {
      final reached = <int>{};
      for (final group in scratchGroups) {
        expect(
          [
            for (var tier = 0; tier < 4; tier++)
              scratchCollectibles
                  .where((c) => c.groupId == group.id && c.rarity == tier)
                  .length,
          ],
          [12, 7, 4, 1],
        );
      }
      for (final (tier, roll) in [(0, 0.0), (1, .7), (2, .94), (3, .995)]) {
        final pool = scratchCollectibles
            .where((c) => c.rarity == tier)
            .toList();
        for (var i = 0; i < pool.length; i++) {
          final values = [roll, (i + .5) / pool.length].iterator;
          final prize = drawScratchCollectible(() {
            values.moveNext();
            return values.current;
          });
          expect(prize.index, pool[i].index);
          expect(scratchCollectibles[prize.index], same(prize));
          reached.add(prize.index);
        }
      }
      expect(reached.length, 48);
      expect(
        scratchCollectibles.take(24).every((c) => c.groupId == 'cats'),
        isTrue,
      );
      expect(
        scratchCollectibles.skip(24).every((c) => c.groupId == 'dogs'),
        isTrue,
      );
    },
  );

  test(
    '24-entry save retains cats, current ticket, dates, and adds empty dogs',
    () async {
      final store = MemoryScratchStore();
      final legacy = legacyScratchSave(size: 24);
      store.value = jsonEncode(legacy);
      final restored = ScratchController(store: store);
      await restored.load();
      expect(restored.error, isNull);
      expect(restored.counts.take(24), [1, ...List.filled(23, 0)]);
      expect(restored.counts.skip(24), everyElement(0));
      expect(restored.firstFound[0], DateTime(2026).toIso8601String());
      expect(restored.favorites, [0]);
      expect(restored.cat.index, 0);
      expect(restored.claimed, isFalse);
      expect(restored.serial, 7);
      await restored.draw();
      expect(restored.counts[0], 2);
      final reloaded = ScratchController(store: store);
      await reloaded.load();
      expect(reloaded.error, isNull);
      expect(reloaded.counts, restored.counts);
      for (final c in [restored, reloaded]) {
        c.dispose();
      }
    },
  );

  test(
    'dog prize persists, restores and repeated claims award only once',
    () async {
      final values = [0.0, .995, .75].iterator;
      final store = MemoryScratchStore();
      final c = ScratchController(
        store: store,
        random: () {
          values.moveNext();
          return values.current;
        },
      );
      await c.load();
      expect(c.cat.index, 47);
      await c.draw();
      final restored = ScratchController(store: store);
      await restored.load();
      expect(restored.error, isNull);
      expect(restored.cat.index, 47);
      expect(restored.counts[47], 1);
      expect(restored.firstFound[47], c.firstFound[47]);
      expect(restored.total, 1);
      c.dispose();
      restored.dispose();
    },
  );

  test(
    'legacy player snapshots pad dogs while malformed lengths are rejected',
    () {
      final json = <String, Object?>{
        'userId': '11111111-1111-4111-8111-111111111111',
        'nickname': '玩家',
        'counts': List.filled(24, 1),
        'updatedAt': 0,
      };
      final player = ScratchPlayer.fromJson(json);
      expect(player.counts.length, 48);
      expect(player.counts.skip(24), everyElement(0));
      for (final length in [0, 23, 25, 47, 49]) {
        json['counts'] = List.filled(length, 0);
        expect(() => ScratchPlayer.fromJson(json), throwsFormatException);
      }
    },
  );

  for (final dark in [false, true]) {
    testWidgets(
      'dog group combines rarity and owned filters, opens matching art dark=$dark',
      (tester) async {
        tester.view.physicalSize = const Size(360, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final c = ScratchController(
          store: MemoryScratchStore(),
          random: () => 0,
        );
        await c.load();
        c.counts[24] = 2;
        c.firstFound[24] = DateTime(2026).toIso8601String();
        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? GameboxTheme.dark() : GameboxTheme.light(),
            home: ScratchPage(
              controller: c,
              socialApi: FakeSocial()..canSync = false,
            ),
          ),
        );
        await tester.tap(find.byKey(const Key('scratch-tab-album')));
        await tester.pumpAndSettle();
        final dogGroup = find.text('狗狗百业 1/24');
        await tester.ensureVisible(dogGroup);
        await tester.pumpAndSettle();
        await tester.tap(dogGroup);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('scratch-cat-24')), findsOneWidget);
        expect(find.byKey(const ValueKey('scratch-cat-0')), findsNothing);
        await tester.tap(find.text('已拥有'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('scratch-cat-25')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('scratch-cat-24')));
        await tester.pumpAndSettle();
        expect(find.text('狗狗百业'), findsOneWidget);
        expect(
          find
              .byType(CollectibleArtwork)
              .evaluate()
              .map((e) => (e.widget as CollectibleArtwork).cat.imageAsset),
          everyElement('assets/scratch/dog-atlas-v2.webp'),
        );
        await tester.tap(find.byTooltip('关闭详情'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('史诗'));
        await tester.pumpAndSettle();
        expect(find.text('还没有藏品，去抽一张吧'), findsOneWidget);
        await tester.tap(find.text('已拥有'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('scratch-cat-43')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        c.dispose();
      },
    );
  }
}
