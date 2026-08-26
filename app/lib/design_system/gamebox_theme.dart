import 'package:flutter/material.dart';

import 'generated/gamebox_tokens.g.dart';

abstract final class GameboxTheme {
  static ThemeData light() => _build(GameboxTokens.lightColorScheme);

  static ThemeData dark() => _build(GameboxTokens.darkColorScheme);

  static ThemeData _build(ColorScheme scheme) {
    final textTheme = _textTheme(scheme);
    final inputRadius = BorderRadius.circular(GameboxTokens.shape.input);
    final cardShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(GameboxTokens.shape.card),
    );
    final floatingShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(GameboxTokens.shape.floating),
    );
    final dialogShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(GameboxTokens.shape.dialog),
    );
    final fullShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(GameboxTokens.shape.full),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      visualDensity: VisualDensity.standard,
      textTheme: textTheme,
      appBarTheme: const AppBarTheme(
        centerTitle: false,
        scrolledUnderElevation: 0,
      ),
      cardTheme: CardThemeData(clipBehavior: Clip.antiAlias, shape: cardShape),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        border: OutlineInputBorder(borderRadius: inputRadius),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        shape: floatingShape,
      ),
      dialogTheme: DialogThemeData(shape: dialogShape),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: Size.square(GameboxTokens.components.minimumTouchTarget),
          shape: fullShape,
          textStyle: textTheme.labelLarge,
        ),
      ),
      chipTheme: ChipThemeData(
        shape: fullShape,
        labelStyle: textTheme.labelLarge,
      ),
    );
  }

  static TextTheme _textTheme(ColorScheme scheme) {
    final base = ThemeData(useMaterial3: true, colorScheme: scheme).textTheme;
    final tokens = GameboxTokens.typography;
    return base.copyWith(
      displayLarge: _textStyle(base.displayLarge, tokens.displayLarge),
      displayMedium: _textStyle(base.displayMedium, tokens.displayMedium),
      displaySmall: _textStyle(base.displaySmall, tokens.displaySmall),
      headlineLarge: _textStyle(base.headlineLarge, tokens.headlineLarge),
      headlineMedium: _textStyle(base.headlineMedium, tokens.headlineMedium),
      headlineSmall: _textStyle(base.headlineSmall, tokens.headlineSmall),
      titleLarge: _textStyle(base.titleLarge, tokens.titleLarge),
      titleMedium: _textStyle(base.titleMedium, tokens.titleMedium),
      titleSmall: _textStyle(base.titleSmall, tokens.titleSmall),
      bodyLarge: _textStyle(base.bodyLarge, tokens.bodyLarge),
      bodyMedium: _textStyle(base.bodyMedium, tokens.bodyMedium),
      bodySmall: _textStyle(base.bodySmall, tokens.bodySmall),
      labelLarge: _textStyle(base.labelLarge, tokens.labelLarge),
      labelMedium: _textStyle(base.labelMedium, tokens.labelMedium),
      labelSmall: _textStyle(base.labelSmall, tokens.labelSmall),
    );
  }

  static TextStyle _textStyle(TextStyle? base, GameboxTypeStyle tokens) =>
      (base ?? const TextStyle()).copyWith(
        fontSize: tokens.fontSize,
        fontWeight: FontWeight.values.singleWhere(
          (weight) => weight.value == tokens.fontWeight,
        ),
        height: tokens.lineHeight / tokens.fontSize,
      );
}
