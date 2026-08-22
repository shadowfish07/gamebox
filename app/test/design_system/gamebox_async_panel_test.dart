import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/design_system/components/gamebox_async_panel.dart';
import 'package:gamebox/design_system/gamebox_theme.dart';
import 'package:gamebox/design_system/generated/gamebox_tokens.g.dart';

void main() {
  testWidgets('shows an explicit loading state in a stable panel', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const GameboxAsyncPanel(
          icon: Icons.cloud_off_outlined,
          title: '正在加载对局',
          message: '请稍候，正在获取最新状态。',
          actionLabel: '重试',
          isLoading: true,
        ),
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('正在加载对局'), findsOneWidget);
    expect(find.text('请稍候，正在获取最新状态。'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
    expect(
      tester.getSize(find.byType(CircularProgressIndicator)),
      Size.square(GameboxTokens.components.smallProgressSize),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows an error and invokes its retry action once', (
    tester,
  ) async {
    var retryCount = 0;
    await tester.pumpWidget(
      _app(
        GameboxAsyncPanel(
          icon: Icons.cloud_off_outlined,
          title: '暂时无法加载',
          message: '检查网络后再试一次。',
          actionLabel: '重试',
          onAction: () => retryCount += 1,
        ),
      ),
    );

    expect(find.byIcon(Icons.cloud_off_outlined), findsOneWidget);
    expect(find.text('暂时无法加载'), findsOneWidget);
    expect(find.text('检查网络后再试一次。'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(
      tester.getSize(find.widgetWithText(FilledButton, '重试')).height,
      greaterThanOrEqualTo(GameboxTokens.components.minimumTouchTarget),
    );

    await tester.tap(find.text('重试'));
    await tester.pump();

    expect(retryCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reserves the action and status regions across states', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const GameboxAsyncPanel(
          icon: Icons.info_outline,
          title: '状态标题',
          message: '稳定的状态说明',
          actionLabel: '重试',
          isLoading: true,
        ),
      ),
    );
    final loadingHeight = tester.getSize(find.byType(GameboxAsyncPanel)).height;

    await tester.pumpWidget(
      _app(
        const GameboxAsyncPanel(
          icon: Icons.info_outline,
          title: '状态标题',
          message: '稳定的状态说明',
          actionLabel: '重试',
        ),
      ),
    );
    final messageHeight = tester.getSize(find.byType(GameboxAsyncPanel)).height;

    expect(messageHeight, loadingHeight);
    expect(tester.takeException(), isNull);
  });
}

Widget _app(Widget child) => MaterialApp(
  theme: GameboxTheme.light(),
  home: Scaffold(body: Center(child: child)),
);
