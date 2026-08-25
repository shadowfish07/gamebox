import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/design_system/gamebox_theme.dart';
import 'package:gamebox/design_system/generated/gamebox_tokens.g.dart';

void main() {
  test('uses the generated light and dark Material 3 schemes', () {
    expect(GameboxTheme.light().colorScheme, GameboxTokens.lightColorScheme);
    expect(GameboxTheme.dark().colorScheme, GameboxTokens.darkColorScheme);
    expect(GameboxTheme.light().useMaterial3, isTrue);
    expect(GameboxTheme.dark().useMaterial3, isTrue);
  });

  test('maps generated typography and component sizing', () {
    final theme = GameboxTheme.light();

    expect(
      theme.textTheme.titleLarge?.fontSize,
      GameboxTokens.typography.titleLarge.fontSize,
    );
    expect(
      theme.textTheme.titleLarge?.fontWeight?.value,
      GameboxTokens.typography.titleLarge.fontWeight,
    );
    expect(
      theme.textTheme.titleLarge?.height,
      GameboxTokens.typography.titleLarge.lineHeight /
          GameboxTokens.typography.titleLarge.fontSize,
    );
    expect(
      theme.filledButtonTheme.style?.minimumSize?.resolve(<WidgetState>{}),
      Size.square(GameboxTokens.components.minimumTouchTarget),
    );
  });

  test('maps every shared component shape from generated tokens', () {
    final theme = GameboxTheme.light();
    final inputBorder = theme.inputDecorationTheme.border;

    expect(inputBorder, isA<OutlineInputBorder>());
    expect(
      (inputBorder! as OutlineInputBorder).borderRadius.topLeft.x,
      GameboxTokens.shape.input,
    );
    expect(_cornerRadius(theme.cardTheme.shape), GameboxTokens.shape.card);
    expect(
      _cornerRadius(theme.floatingActionButtonTheme.shape),
      GameboxTokens.shape.floating,
    );
    expect(_cornerRadius(theme.dialogTheme.shape), GameboxTokens.shape.dialog);
    expect(
      _cornerRadius(
        theme.filledButtonTheme.style?.shape?.resolve(<WidgetState>{}),
      ),
      GameboxTokens.shape.full,
    );
    expect(_cornerRadius(theme.chipTheme.shape), GameboxTokens.shape.full);
  });
}

double _cornerRadius(ShapeBorder? shape) {
  expect(shape, isA<RoundedRectangleBorder>());
  final borderRadius = (shape! as RoundedRectangleBorder).borderRadius.resolve(
    TextDirection.ltr,
  );
  return borderRadius.topLeft.x;
}
