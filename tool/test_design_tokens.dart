import 'dart:convert';
import 'dart:io';

import 'design_tokens.dart';

typedef TestBody = void Function();

var _passed = 0;
var _failed = 0;

void main() {
  final repositoryRoot = Directory.current;
  final canonicalFixture = _readObject(
    File('design_system/tokens/gamebox.tokens.json'),
  );
  final schema = _readObject(File('design_system/schema/tokens.schema.json'));

  test('accepts the canonical version and seed', () {
    final tokens = DesignTokenDocument.fromJson(canonicalFixture);
    expectEqual(tokens.version, '1.0.0');
    expectEqual(tokens.brandSeed, '#006B60');
  });

  test('rejects a missing on-color role', () {
    expectThrows(
      () => DesignTokenDocument.fromJson(
        _withoutPath(canonicalFixture, 'colorSchemes.light.onPrimary'),
      ),
      contains: 'colorSchemes.light.onPrimary',
    );
  });

  test('rejects unknown top-level keys', () {
    final fixture = _copy(canonicalFixture)..['surprise'] = true;
    expectThrows(
      () => DesignTokenDocument.fromJson(fixture),
      contains: r'$.surprise',
    );
  });

  test('rejects illegal colors and non-positive dimensions', () {
    expectThrows(
      () => DesignTokenDocument.fromJson(
        _withPath(canonicalFixture, 'game.board', '#abc'),
      ),
      contains: 'game.board',
    );
    expectThrows(
      () => DesignTokenDocument.fromJson(
        _withPath(canonicalFixture, 'spacing.base', 0),
      ),
      contains: 'spacing.base',
    );
  });

  test('executes the JSON schema against the canonical document', () {
    validateJsonSchema(schema, canonicalFixture);
    expectThrows(
      () => validateJsonSchema(
        schema,
        _withPath(canonicalFixture, 'brand.seed', '006B60'),
      ),
      contains: 'brand.seed',
    );
  });

  test('schema enforces required and additionalProperties', () {
    expectThrows(
      () => validateJsonSchema(
        schema,
        _withoutPath(canonicalFixture, 'brand.seed'),
      ),
      contains: 'brand.seed',
    );
    expectThrows(
      () => validateJsonSchema(
        schema,
        _withPath(canonicalFixture, 'brand.extra', true),
      ),
      contains: 'brand.extra',
    );
  });

  test('schema enforces number types and boundaries', () {
    expectThrows(
      () => validateJsonSchema(
        schema,
        _withPath(canonicalFixture, 'spacing.base', '4'),
      ),
      contains: 'spacing.base',
    );
    expectThrows(
      () => validateJsonSchema(
        schema,
        _withPath(canonicalFixture, 'game.pendingOverlayAlpha', 2),
      ),
      contains: 'game.pendingOverlayAlpha',
    );
  });

  test('schema validator fails closed on unsupported keywords', () {
    final unsupportedSchema = _copy(schema);
    final properties = unsupportedSchema['properties']! as Map<String, Object?>;
    final version = properties['version']! as Map<String, Object?>;
    version['minLength'] = 1;
    expectThrows(
      () => validateJsonSchema(unsupportedSchema, canonicalFixture),
      contains: r'$.properties.version.minLength',
    );
  });

  test('renders deterministic platform constants', () {
    final tokens = DesignTokenDocument.fromJson(canonicalFixture);
    final dartA = renderDart(tokens);
    final gdscriptA = renderGdscript(tokens);
    expectEqual(dartA, renderDart(tokens));
    expectEqual(gdscriptA, renderGdscript(tokens));
    expectTrue(dartA.endsWith('\n') && !dartA.endsWith('\n\n'));
    expectTrue(gdscriptA.endsWith('\n') && !gdscriptA.endsWith('\n\n'));
    expectContains(dartA, "static const version = '1.0.0';");
    expectContains(gdscriptA, 'const VERSION := "1.0.0"');
    expectContains(dartA, '0xFF006B60');
    expectContains(gdscriptA, '"#006B60"');
  });

  test('keeps semantic foreground and container roles distinct', () {
    final tokens = DesignTokenDocument.fromJson(canonicalFixture);
    expectNotEqual(
      tokens.lightColors['primary'],
      tokens.lightColors['onPrimary'],
    );
    expectNotEqual(
      tokens.darkColors['surface'],
      tokens.darkColors['onSurface'],
    );
  });

  test('reconciles every registered normative numeric claim', () {
    verifyNormativeClaims(canonicalFixture, repositoryRoot);
  });

  if (_failed != 0) {
    stderr.writeln('FAILED: $_failed test(s), PASSED: $_passed');
    exitCode = 1;
    return;
  }
  stdout.writeln('PASS: $_passed design token tests');
}

void test(String name, TestBody body) {
  try {
    body();
    _passed += 1;
    stdout.writeln('PASS: $name');
  } catch (error, stackTrace) {
    _failed += 1;
    stderr.writeln('FAIL: $name\n$error\n$stackTrace');
  }
}

void expectEqual(Object? actual, Object? expected) {
  if (actual != expected) {
    throw StateError('Expected <$expected>, got <$actual>.');
  }
}

void expectNotEqual(Object? actual, Object? unexpected) {
  if (actual == unexpected) {
    throw StateError('Did not expect <$unexpected>.');
  }
}

void expectTrue(bool value) {
  if (!value) {
    throw StateError('Expected true, got false.');
  }
}

void expectContains(String actual, String expectedSubstring) {
  if (!actual.contains(expectedSubstring)) {
    throw StateError('Expected output to contain <$expectedSubstring>.');
  }
}

void expectThrows(void Function() body, {required String contains}) {
  try {
    body();
  } catch (error) {
    if (!error.toString().contains(contains)) {
      throw StateError('Expected error containing <$contains>, got <$error>.');
    }
    return;
  }
  throw StateError('Expected an exception containing <$contains>.');
}

Map<String, Object?> _readObject(File file) {
  final decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map<String, Object?>) {
    throw StateError('${file.path} must contain a JSON object.');
  }
  return decoded;
}

Map<String, Object?> _copy(Map<String, Object?> source) {
  return jsonDecode(jsonEncode(source)) as Map<String, Object?>;
}

Map<String, Object?> _withoutPath(Map<String, Object?> source, String path) {
  final copy = _copy(source);
  final segments = path.split('.');
  var current = copy;
  for (final segment in segments.take(segments.length - 1)) {
    current = current[segment]! as Map<String, Object?>;
  }
  current.remove(segments.last);
  return copy;
}

Map<String, Object?> _withPath(
  Map<String, Object?> source,
  String path,
  Object? value,
) {
  final copy = _copy(source);
  final segments = path.split('.');
  var current = copy;
  for (final segment in segments.take(segments.length - 1)) {
    current = current[segment]! as Map<String, Object?>;
  }
  current[segments.last] = value;
  return copy;
}
