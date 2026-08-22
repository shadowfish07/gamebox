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

  test('parser rejects fractional font weights and motion durations', () {
    expectThrows(
      () => DesignTokenDocument.fromJson(
        _withPath(canonicalFixture, 'typography.bodyLarge.fontWeight', 400.5),
      ),
      contains: 'typography.bodyLarge.fontWeight',
    );
    expectThrows(
      () => DesignTokenDocument.fromJson(
        _withPath(canonicalFixture, 'motion.standard', 100.5),
      ),
      contains: 'motion.standard',
    );
    for (final invalidWeight in [150, 1000]) {
      expectThrows(
        () => DesignTokenDocument.fromJson(
          _withPath(
            canonicalFixture,
            'typography.bodyLarge.fontWeight',
            invalidWeight,
          ),
        ),
        contains: 'typography.bodyLarge.fontWeight',
      );
    }
  });

  test('schema rejects fractional font weights and motion durations', () {
    expectThrows(
      () => validateJsonSchema(
        schema,
        _withPath(canonicalFixture, 'typography.bodyLarge.fontWeight', 400.5),
      ),
      contains: 'typography.bodyLarge.fontWeight',
    );
    expectThrows(
      () => validateJsonSchema(
        schema,
        _withPath(canonicalFixture, 'motion.standard', 100.5),
      ),
      contains: 'motion.standard',
    );
    for (final invalidWeight in [150, 1000]) {
      expectThrows(
        () => validateJsonSchema(
          schema,
          _withPath(
            canonicalFixture,
            'typography.bodyLarge.fontWeight',
            invalidWeight,
          ),
        ),
        contains: 'typography.bodyLarge.fontWeight',
      );
    }
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

  test('canonical loader rejects wrong absolute and traversal schema refs', () {
    final fixtureRoot = Directory.systemTemp.createTempSync(
      'gamebox-schema-ref-',
    );
    try {
      final inputFile = File('${fixtureRoot.path}/tokens/tokens.json');
      inputFile.parent.createSync(recursive: true);
      for (final reference in [
        'tokens.schema.json',
        '/tmp/tokens.schema.json',
        '../../schema/tokens.schema.json',
      ]) {
        inputFile.writeAsStringSync(
          jsonEncode(_withPath(canonicalFixture, r'$schema', reference)),
        );
        expectThrows(
          () => loadCanonicalDesignTokenDocument(
            inputFile: inputFile,
            committedSchemaFile: File(
              'design_system/schema/tokens.schema.json',
            ),
          ),
          contains: r'$.$schema',
        );
      }
    } finally {
      fixtureRoot.deleteSync(recursive: true);
    }
  });

  test('canonical loader always reads the committed schema', () {
    final fixtureRoot = Directory.systemTemp.createTempSync(
      'gamebox-committed-schema-',
    );
    try {
      final inputFile = File('${fixtureRoot.path}/tokens/tokens.json');
      inputFile.parent.createSync(recursive: true);
      inputFile.writeAsStringSync(
        jsonEncode(
          _withPath(
            canonicalFixture,
            'brand.schemeSource',
            'unlocked-local-source',
          ),
        ),
      );
      final localSchema = File('${fixtureRoot.path}/schema/tokens.schema.json');
      localSchema.parent.createSync(recursive: true);
      localSchema.writeAsStringSync('{}');

      expectThrows(
        () => loadCanonicalDesignTokenDocument(
          inputFile: inputFile,
          committedSchemaFile: File('design_system/schema/tokens.schema.json'),
        ),
        contains: 'brand.schemeSource',
      );
    } finally {
      fixtureRoot.deleteSync(recursive: true);
    }
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

  test('reconciliation binds token meanings to stable contexts', () {
    final fixtureRoot = _copyReconciliationFixture(repositoryRoot);
    try {
      final spacing = canonicalFixture['spacing']! as Map<String, Object?>;
      final base = spacing['base'];
      final layout = spacing['layout'];
      const unit = 'dp';
      final standard = File(
        '${fixtureRoot.path}/.agents/skills/gamebox-material-3-ux/references/ux-standard.md',
      );
      standard.writeAsStringSync(
        standard.readAsStringSync().replaceFirst(
          'a $base$unit base grid with an $layout$unit layout rhythm',
          'an $layout$unit base grid with a $base$unit layout rhythm',
        ),
      );
      expectThrows(
        () => verifyNormativeClaims(canonicalFixture, fixtureRoot),
        contains: 'ux-spacing-base',
      );
    } finally {
      fixtureRoot.deleteSync(recursive: true);
    }
  });

  test('reconciliation rejects stale registered contexts', () {
    final fixtureRoot = _copyReconciliationFixture(repositoryRoot);
    try {
      const unit = 'dp';
      final readme = File('${fixtureRoot.path}/design_system/README.md');
      readme.writeAsStringSync(
        '${readme.readAsStringSync()}\n'
        '<!-- gamebox-numeric-claim '
        '{"id":"stale-test","path":".agents/skills/gamebox-material-3-ux/references/ux-standard.md",'
        '"token":"spacing.base","unit":"$unit","context":"missing {value}$unit context"} -->\n',
      );
      expectThrows(
        () => verifyNormativeClaims(canonicalFixture, fixtureRoot),
        contains: 'stale-test',
      );
    } finally {
      fixtureRoot.deleteSync(recursive: true);
    }
  });

  test('reconciliation rejects unregistered numeric occurrences', () {
    final fixtureRoot = _copyReconciliationFixture(repositoryRoot);
    try {
      const unit = 'dp';
      final standard = File(
        '${fixtureRoot.path}/.agents/skills/gamebox-material-3-ux/references/ux-standard.md',
      );
      standard.writeAsStringSync(
        '${standard.readAsStringSync()}\nUnregistered test target: ${49}$unit.\n',
      );
      expectThrows(
        () => verifyNormativeClaims(canonicalFixture, fixtureRoot),
        contains: 'unregistered numeric claim',
      );
    } finally {
      fixtureRoot.deleteSync(recursive: true);
    }
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

Directory _copyReconciliationFixture(Directory sourceRoot) {
  final fixtureRoot = Directory.systemTemp.createTempSync(
    'gamebox-normative-claims-',
  );
  final relativePaths = <String>[
    ...Directory(
          '${sourceRoot.path}/.agents/skills/gamebox-material-3-ux/references',
        )
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.md'))
        .map(
          (file) =>
              '.agents/skills/gamebox-material-3-ux/references/${file.uri.pathSegments.last}',
        ),
    'docs/superpowers/plans/2026-08-22-gamebox-material-3-ux-retrofit.md',
    'design_system/README.md',
    'app/test/design_system/derive_color_scheme_test.dart',
    'tool/test_design_tokens.dart',
  ];
  for (final relativePath in relativePaths) {
    final target = File('${fixtureRoot.path}/$relativePath');
    target.parent.createSync(recursive: true);
    File('${sourceRoot.path}/$relativePath').copySync(target.path);
  }
  return fixtureRoot;
}
