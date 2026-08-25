import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/design_system/components/gamebox_pending_button.dart';
import 'package:gamebox/design_system/gamebox_theme.dart';
import 'package:gamebox/design_system/generated/gamebox_tokens.g.dart';

void main() {
  testWidgets('shows its default verb and handles a pressed action', (
    tester,
  ) async {
    var pressCount = 0;
    await tester.pumpWidget(
      _app(
        GameboxPendingButton(
          identifier: 'register',
          label: '注册',
          pendingLabel: '正在注册',
          onPressed: () => pressCount += 1,
        ),
      ),
    );

    expect(find.bySemanticsIdentifier('register'), findsOneWidget);
    expect(find.text('注册'), findsOneWidget);
    expect(
      tester.getSize(find.byType(FilledButton)).height,
      greaterThanOrEqualTo(48),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(FilledButton)),
    );
    await tester.pump();
    expect(pressCount, 0);
    await gesture.up();
    await tester.pump();

    expect(pressCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stays disabled when no action is available', (tester) async {
    await tester.pumpWidget(
      _app(
        const GameboxPendingButton(
          identifier: 'register',
          label: '注册',
          pendingLabel: '正在注册',
        ),
      ),
    );

    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps a visible verb and blocks duplicate pending presses', (
    tester,
  ) async {
    var pressCount = 0;
    await tester.pumpWidget(
      _app(
        GameboxPendingButton(
          identifier: 'register',
          label: '注册',
          pendingLabel: '正在注册',
          isPending: true,
          onPressed: () => pressCount += 1,
        ),
      ),
    );

    expect(find.text('正在注册'), findsOneWidget);
    expect(find.text('注册'), findsNothing);
    expect(
      tester.getSize(find.byType(CircularProgressIndicator)),
      Size.square(GameboxTokens.components.smallProgressSize),
    );
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );

    await tester.tap(find.byType(FilledButton), warnIfMissed: false);
    await tester.tap(find.byType(FilledButton), warnIfMissed: false);
    await tester.pump();

    expect(pressCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('returns to enabled after its parent reports failure', (
    tester,
  ) async {
    var pressCount = 0;
    Widget button(bool pending) => GameboxPendingButton(
      identifier: 'register',
      label: '重试注册',
      pendingLabel: '正在注册',
      isPending: pending,
      onPressed: () => pressCount += 1,
    );

    await tester.pumpWidget(_app(button(true)));
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );

    await tester.pumpWidget(_app(button(false)));
    await tester.tap(find.byType(FilledButton));
    await tester.pump();

    expect(find.text('重试注册'), findsOneWidget);
    expect(pressCount, 1);
    expect(tester.takeException(), isNull);
  });
}

Widget _app(Widget child) => MaterialApp(
  theme: GameboxTheme.light(),
  home: Scaffold(body: Center(child: child)),
);
