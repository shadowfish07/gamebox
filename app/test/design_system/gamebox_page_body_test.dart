import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/design_system/components/gamebox_page_body.dart';
import 'package:gamebox/design_system/gamebox_theme.dart';
import 'package:gamebox/design_system/generated/gamebox_tokens.g.dart';

void main() {
  for (final size in const [Size(360, 800), Size(412, 915)]) {
    testWidgets('lays out and scrolls long phone content at $size', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);

      const longMessage =
          '这是一段用于验证手机页面换行和滚动的较长文案，'
          '内容到达边界时应该自然换行，而不是遮挡主要操作。';
      await tester.pumpWidget(
        MaterialApp(
          theme: GameboxTheme.light(),
          home: const Scaffold(
            body: GameboxPageBody(
              children: [
                Text('页面标题'),
                Text(longMessage),
                Text(longMessage),
                Text(longMessage),
                Text(longMessage),
                Text('主要操作'),
              ],
            ),
          ),
        ),
      );

      expect(find.byType(SafeArea), findsOneWidget);
      expect(find.text('页面标题'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.drag(find.byType(ListView), const Offset(0, -500));
      await tester.pump();

      expect(find.text('主要操作'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('uses token page padding, section spacing, and max width', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(700, 915);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: GameboxTheme.light(),
        home: const Scaffold(
          body: GameboxPageBody(children: [Text('第一组'), Text('第二组')]),
        ),
      ),
    );

    final listView = tester.widget<ListView>(find.byType(ListView));
    expect(
      listView.padding,
      EdgeInsets.all(GameboxTokens.components.pagePadding),
    );
    expect(tester.getSize(find.byType(ListView)).width, 560);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SizedBox &&
            widget.height == GameboxTokens.components.sectionSpacing,
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
