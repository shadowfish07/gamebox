import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/design_system/components/gamebox_async_panel.dart';
import 'package:gamebox/design_system/components/gamebox_page_body.dart';
import 'package:gamebox/design_system/components/gamebox_pending_button.dart';
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
          home: Scaffold(
            body: GameboxPageBody(
              children: [
                const Text('页面标题'),
                for (var section = 0; section < 14; section += 1)
                  Text('$longMessage 第${section + 1}段。'),
                FilledButton(onPressed: () {}, child: const Text('主要操作')),
              ],
            ),
          ),
        ),
      );

      expect(find.byType(SafeArea), findsOneWidget);
      expect(find.text('页面标题'), findsOneWidget);
      expect(tester.takeException(), isNull);

      final scrollable = find.byType(Scrollable);
      final position = tester.state<ScrollableState>(scrollable).position;
      expect(position.maxScrollExtent, greaterThan(0));
      final initialPixels = position.pixels;

      await tester.drag(find.byType(ListView), const Offset(0, -240));
      await tester.pump();
      expect(position.pixels, greaterThan(initialPixels));

      final primaryAction = find.widgetWithText(FilledButton, '主要操作');
      await tester.scrollUntilVisible(
        primaryAction,
        300,
        scrollable: scrollable,
      );
      await tester.pump();

      expect(primaryAction.hitTestable(), findsOneWidget);
      final viewport = tester.getRect(find.byType(ListView));
      final actionBounds = tester.getRect(primaryAction);
      expect(actionBounds.top, greaterThanOrEqualTo(viewport.top));
      expect(actionBounds.bottom, lessThanOrEqualTo(viewport.bottom));
      expect(tester.takeException(), isNull);
    });
  }

  for (final configuration in const [
    (
      name: 'light loading and pending at 360x800',
      size: Size(360, 800),
      brightness: Brightness.light,
      isLoading: true,
      isPending: true,
    ),
    (
      name: 'dark error and default at 412x915',
      size: Size(412, 915),
      brightness: Brightness.dark,
      isLoading: false,
      isPending: false,
    ),
  ]) {
    testWidgets('supports ${configuration.name}', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = configuration.size;
      addTearDown(tester.view.reset);

      const longMessage =
          '这是一段用于验证正常字号下长文案换行与状态排版的说明，'
          '不应遮挡加载、错误或主要操作状态。';
      await tester.pumpWidget(
        MaterialApp(
          theme: GameboxTheme.light(),
          darkTheme: GameboxTheme.dark(),
          themeMode: configuration.brightness == Brightness.dark
              ? ThemeMode.dark
              : ThemeMode.light,
          home: Scaffold(
            body: GameboxPageBody(
              children: [
                const Text('页面状态'),
                GameboxAsyncPanel(
                  icon: Icons.cloud_off_outlined,
                  title: configuration.isLoading ? '正在加载对局' : '暂时无法加载',
                  message: longMessage,
                  actionLabel: '重试',
                  isLoading: configuration.isLoading,
                  onAction: configuration.isLoading ? null : () {},
                ),
                GameboxPendingButton(
                  identifier: 'matrix-primary-action',
                  label: '开始同步',
                  pendingLabel: '正在同步',
                  isPending: configuration.isPending,
                  onPressed: () {},
                ),
                const Text(longMessage),
              ],
            ),
          ),
        ),
      );

      final pageBody = find.byType(GameboxPageBody);
      expect(pageBody, findsOneWidget);
      expect(
        Theme.of(tester.element(pageBody)).brightness,
        configuration.brightness,
      );

      final asyncPanel = find.byType(GameboxAsyncPanel);
      final asyncProgress = find.descendant(
        of: asyncPanel,
        matching: find.byType(CircularProgressIndicator),
      );
      final retryAction = find.descendant(
        of: asyncPanel,
        matching: find.widgetWithText(FilledButton, '重试'),
      );
      expect(
        asyncProgress,
        configuration.isLoading ? findsOneWidget : findsNothing,
      );
      expect(
        retryAction,
        configuration.isLoading ? findsNothing : findsOneWidget,
      );

      final pendingButton = find.byType(GameboxPendingButton);
      final pendingProgress = find.descendant(
        of: pendingButton,
        matching: find.byType(CircularProgressIndicator),
      );
      expect(
        pendingProgress,
        configuration.isPending ? findsOneWidget : findsNothing,
      );
      expect(
        find.descendant(
          of: pendingButton,
          matching: find.text(configuration.isPending ? '正在同步' : '开始同步'),
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.descendant(
                of: pendingButton,
                matching: find.byType(FilledButton),
              ),
            )
            .onPressed,
        configuration.isPending ? isNull : isNotNull,
      );
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
