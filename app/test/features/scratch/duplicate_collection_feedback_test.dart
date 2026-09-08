import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/design_system/gamebox_theme.dart';
import 'package:gamebox/design_system/generated/gamebox_tokens.g.dart';
import 'package:gamebox/features/scratch/card_draw_play.dart';
import 'package:gamebox/features/scratch/scratch_controller.dart';

void main() {
  Widget stage({required bool playing, int count = 3}) => MaterialApp(
    theme: GameboxTheme.dark(),
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 220,
          child: CardDrawStage(
            result: CardDrawResult(
              card: scratchCollectibles.first,
              serial: 3,
              isNew: false,
              count: count,
            ),
            playing: playing,
            collecting: false,
            waiting: false,
            onRevealed: () {},
            onStory: () {},
          ),
        ),
      ),
    ),
  );

  testWidgets('duplicate count changes only after the incoming card lands', (
    tester,
  ) async {
    await tester.pumpWidget(stage(playing: true));
    await tester.pump(cardRevealDuration(0) * .65);
    expect(find.text('共 2 张'), findsOneWidget);
    expect(find.text('共 3 张'), findsNothing);
    await tester.pump(GameboxTokens.motion.slow);
    expect(find.text('共 2 张'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('共 3 张'), findsOneWidget);
    expect(find.text('已收进收藏'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('skipping the reveal immediately settles the saved count', (
    tester,
  ) async {
    await tester.pumpWidget(stage(playing: true));
    await tester.pump(cardRevealDuration(0) * .45);
    expect(find.text('共 2 张'), findsOneWidget);
    await tester.pumpWidget(stage(playing: false));
    expect(find.text('共 3 张'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('共 2 张'), findsNothing);
  });

  testWidgets('restored result shows its final large count without replay', (
    tester,
  ) async {
    await tester.pumpWidget(stage(playing: false, count: 1000000));
    expect(find.text('共 1000000 张'), findsOneWidget);
    expect(find.text('共 999999 张'), findsNothing);
    expect(find.text('已收进收藏'), findsOneWidget);
    expect(find.byKey(const Key('draw-view-story')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
