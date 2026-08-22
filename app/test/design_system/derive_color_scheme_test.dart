import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _outputPath = String.fromEnvironment('GAMEBOX_SCHEME_OUTPUT');

void main() {
  test('exports and locks the Flutter 3.35.1 tonal spot color schemes', () {
    final derived = <String, Object?>{
      'light': _scheme(Brightness.light),
      'dark': _scheme(Brightness.dark),
    };

    expect(derived['light'], isA<Map<String, String>>());
    expect(derived['dark'], isA<Map<String, String>>());
    expect((derived['light']! as Map<String, String>).length, 46);
    expect((derived['dark']! as Map<String, String>).length, 46);

    if (_outputPath.isNotEmpty) {
      File(_outputPath).writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(derived)}\n',
      );
    }

    final canonicalFile = File('../design_system/tokens/gamebox.tokens.json');
    if (canonicalFile.existsSync()) {
      final canonical =
          jsonDecode(canonicalFile.readAsStringSync()) as Map<String, Object?>;
      expect(canonical['colorSchemes'], derived);
    }
  });
}

Map<String, String> _scheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF006B60),
    brightness: brightness,
    dynamicSchemeVariant: DynamicSchemeVariant.tonalSpot,
    contrastLevel: 0.0,
  );
  return <String, String>{
    'primary': _hex(scheme.primary),
    'onPrimary': _hex(scheme.onPrimary),
    'primaryContainer': _hex(scheme.primaryContainer),
    'onPrimaryContainer': _hex(scheme.onPrimaryContainer),
    'primaryFixed': _hex(scheme.primaryFixed),
    'primaryFixedDim': _hex(scheme.primaryFixedDim),
    'onPrimaryFixed': _hex(scheme.onPrimaryFixed),
    'onPrimaryFixedVariant': _hex(scheme.onPrimaryFixedVariant),
    'secondary': _hex(scheme.secondary),
    'onSecondary': _hex(scheme.onSecondary),
    'secondaryContainer': _hex(scheme.secondaryContainer),
    'onSecondaryContainer': _hex(scheme.onSecondaryContainer),
    'secondaryFixed': _hex(scheme.secondaryFixed),
    'secondaryFixedDim': _hex(scheme.secondaryFixedDim),
    'onSecondaryFixed': _hex(scheme.onSecondaryFixed),
    'onSecondaryFixedVariant': _hex(scheme.onSecondaryFixedVariant),
    'tertiary': _hex(scheme.tertiary),
    'onTertiary': _hex(scheme.onTertiary),
    'tertiaryContainer': _hex(scheme.tertiaryContainer),
    'onTertiaryContainer': _hex(scheme.onTertiaryContainer),
    'tertiaryFixed': _hex(scheme.tertiaryFixed),
    'tertiaryFixedDim': _hex(scheme.tertiaryFixedDim),
    'onTertiaryFixed': _hex(scheme.onTertiaryFixed),
    'onTertiaryFixedVariant': _hex(scheme.onTertiaryFixedVariant),
    'error': _hex(scheme.error),
    'onError': _hex(scheme.onError),
    'errorContainer': _hex(scheme.errorContainer),
    'onErrorContainer': _hex(scheme.onErrorContainer),
    'surface': _hex(scheme.surface),
    'onSurface': _hex(scheme.onSurface),
    'surfaceDim': _hex(scheme.surfaceDim),
    'surfaceBright': _hex(scheme.surfaceBright),
    'surfaceContainerLowest': _hex(scheme.surfaceContainerLowest),
    'surfaceContainerLow': _hex(scheme.surfaceContainerLow),
    'surfaceContainer': _hex(scheme.surfaceContainer),
    'surfaceContainerHigh': _hex(scheme.surfaceContainerHigh),
    'surfaceContainerHighest': _hex(scheme.surfaceContainerHighest),
    'onSurfaceVariant': _hex(scheme.onSurfaceVariant),
    'outline': _hex(scheme.outline),
    'outlineVariant': _hex(scheme.outlineVariant),
    'inverseSurface': _hex(scheme.inverseSurface),
    'onInverseSurface': _hex(scheme.onInverseSurface),
    'inversePrimary': _hex(scheme.inversePrimary),
    'surfaceTint': _hex(scheme.surfaceTint),
    'shadow': _hex(scheme.shadow),
    'scrim': _hex(scheme.scrim),
  };
}

String _hex(Color color) {
  return '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
}
