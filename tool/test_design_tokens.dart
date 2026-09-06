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
    expectEqual(tokens.version, '2.4.0');
    expectEqual(tokens.brandSeed, '#006B60');
    expectEqual(tokens.components['dialogScrimOpacity'], 0.32);
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

  test('schema validator requires an explicit dialect', () {
    final missingDialect = _copy(schema)..remove(r'$schema');
    expectThrows(
      () => validateJsonSchema(missingDialect, canonicalFixture),
      contains: r'$.$schema',
    );
  });

  test('schema validator rejects an older dialect', () {
    final wrongDialect = _copy(schema)
      ..[r'$schema'] = 'http://json-schema.org/draft-07/schema#';
    expectThrows(
      () => validateJsonSchema(wrongDialect, canonicalFixture),
      contains: r'$.$schema',
    );
  });

  test('schema validator rejects a future dialect', () {
    final futureDialect = _copy(schema)
      ..[r'$schema'] = 'https://json-schema.org/draft/next/schema';
    expectThrows(
      () => validateJsonSchema(futureDialect, canonicalFixture),
      contains: r'$.$schema',
    );
  });

  test('schema validator rejects a nested dialect declaration', () {
    final nestedDialect = _copy(schema);
    final properties = nestedDialect['properties']! as Map<String, Object?>;
    final version = properties['version']! as Map<String, Object?>;
    version[r'$schema'] = 'https://json-schema.org/draft/2020-12/schema';
    expectThrows(
      () => validateJsonSchema(nestedDialect, canonicalFixture),
      contains: r'$.properties.version.$schema',
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
    expectContains(dartA, "static const version = '2.4.0';");
    expectContains(gdscriptA, 'const VERSION := "2.4.0"');
    expectContains(dartA, '0xFF006B60');
    expectContains(gdscriptA, '"#006B60"');
    expectContains(dartA, 'flightBoardPaper: Color(0xFFFFF9E9)');
    expectContains(gdscriptA, '"flight_board_paper": Color("#FFF9E9")');
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

  test('production verifier rejects Flutter style literals', () {
    final fixtureRoot = Directory.systemTemp.createTempSync(
      'gamebox-flutter-hardcodes-',
    );
    try {
      _writeFixture(fixtureRoot, 'app/lib/hardcodes.dart', '''
const colorHex = Color ( 0xFF123456 );
final materialColor = Colors.red;
final argbColor = Color.fromARGB(255, 18, 52, 86);
final rgboColor = Color.fromRGBO(18, 52, 86, 0.5);
const text = TextStyle(fontSize: 13.5);
final mixedText = TextStyle(
  fontSize: GameboxTokens.typography.bodyLarge.fontSize + 1,
);
final radius = BorderRadius.circular(13.5);
const delay = Duration ( milliseconds : 175 );
final mixedDelay = Duration(
  milliseconds: GameboxTokens.motion.standard.inMilliseconds + 1,
);
const all = EdgeInsets.all(7);
const symmetric = EdgeInsets.symmetric(horizontal: 7);
const only = EdgeInsets.only(top: 7);
const sides = EdgeInsets.fromLTRB(1, 2, 3, 4);
const directionalOnly = EdgeInsetsDirectional.only(start: 7);
const directionalSides = EdgeInsetsDirectional.fromSTEB(1, 2, 3, 4);
const box = SizedBox(width: 17.5);
const squareBox = SizedBox.square(dimension: 19);
final wrap = Wrap(spacing: 7);
final mixedWrap = Wrap(spacing: GameboxTokens.spacing.layout + 1);
final wrapped = Wrap(runSpacing: 9);
final grid = GridView.count(mainAxisSpacing: 11);
final gridWide = GridView.count(crossAxisSpacing: 13);
''');
      expectThrowsAll(
        () => verifyProductionDesignHardcodes(fixtureRoot),
        contains: const [
          'Color ( 0xFF123456',
          'Colors.red',
          'Color.fromARGB(255',
          'Color.fromRGBO(18',
          'fontSize: 13.5',
          'fontSize: GameboxTokens.typography.bodyLarge.fontSize + 1',
          'BorderRadius.circular(13.5',
          'Duration ( milliseconds : 175',
          'milliseconds: GameboxTokens.motion.standard.inMilliseconds + 1',
          'EdgeInsets.all(7',
          'EdgeInsets.symmetric(horizontal: 7',
          'EdgeInsets.only(top: 7',
          'EdgeInsets.fromLTRB(1',
          'EdgeInsetsDirectional.only(start: 7',
          'EdgeInsetsDirectional.fromSTEB(1',
          'SizedBox(width: 17.5',
          'SizedBox.square(dimension: 19',
          'spacing: 7',
          'spacing: GameboxTokens.spacing.layout + 1',
          'runSpacing: 9',
          'mainAxisSpacing: 11',
          'crossAxisSpacing: 13',
        ],
      );
    } finally {
      fixtureRoot.deleteSync(recursive: true);
    }
  });

  test('production verifier rejects complete Flutter numeric literals', () {
    final fixtureRoot = Directory.systemTemp.createTempSync(
      'gamebox-flutter-numeric-',
    );
    try {
      _writeFixture(fixtureRoot, 'app/lib/numeric_literals.dart', '''
final exponentSize = TextStyle(fontSize: 1e2);
final exponentInset = EdgeInsets.all(1e2);
final underscoredDuration = Duration(milliseconds: 1_00);
final underscoredSize = TextStyle(fontSize: 1_00.0);
final positiveExponent = TextStyle(fontSize: 1E+2);
final negativeExponent = TextStyle(fontSize: 1e-2);
final leadingDot = TextStyle(fontSize: .5);
final leadingDotExponent = TextStyle(fontSize: .5E+2);
final separatedExponent = TextStyle(fontSize: 1_2.3_4e-5_6);
final separatedHex = Color(0xFF_12_34_56);
''');
      expectThrowsAll(
        () => verifyProductionDesignHardcodes(fixtureRoot),
        contains: const [
          'fontSize: 1e2',
          'EdgeInsets.all(1e2',
          'milliseconds: 1_00',
          'fontSize: 1_00.0',
          'fontSize: 1E+2',
          'fontSize: 1e-2',
          'fontSize: .5',
          'fontSize: .5E+2',
          'fontSize: 1_2.3_4e-5_6',
          'Color(0xFF_12_34_56',
        ],
      );
    } finally {
      fixtureRoot.deleteSync(recursive: true);
    }
  });

  test('production verifier accepts token-backed Flutter styles', () {
    final fixtureRoot = Directory.systemTemp.createTempSync(
      'gamebox-flutter-tokens-',
    );
    try {
      _writeFixture(fixtureRoot, 'app/lib/token_styles.dart', '''
final color = GameboxTokens.lightColorScheme.primary;
final text = TextStyle(fontSize: GameboxTokens.typography.bodyLarge.fontSize);
final radius = BorderRadius.circular(GameboxTokens.shape.card);
final delay = GameboxTokens.motion.standard;
final all = EdgeInsets.all(GameboxTokens.spacing.layout);
final symmetric = EdgeInsets.symmetric(horizontal: GameboxTokens.spacing.page);
final only = EdgeInsets.only(top: GameboxTokens.spacing.section);
final sides = EdgeInsets.fromLTRB(
  GameboxTokens.spacing.base,
  GameboxTokens.spacing.layout,
  GameboxTokens.spacing.compact,
  GameboxTokens.spacing.page,
);
final directionalOnly = EdgeInsetsDirectional.only(
  start: GameboxTokens.spacing.layout,
);
final directionalSides = EdgeInsetsDirectional.fromSTEB(
  GameboxTokens.spacing.base,
  GameboxTokens.spacing.layout,
  GameboxTokens.spacing.compact,
  GameboxTokens.spacing.page,
);
final box = SizedBox(width: GameboxTokens.components.pageMaxWidth);
final squareBox = SizedBox.square(
  dimension: GameboxTokens.components.smallProgressSize,
);
final wrap = Wrap(spacing: GameboxTokens.spacing.layout);
final wrapped = Wrap(runSpacing: GameboxTokens.spacing.compact);
final grid = GridView.count(mainAxisSpacing: GameboxTokens.spacing.section);
final gridWide = GridView.count(crossAxisSpacing: GameboxTokens.spacing.page);
''');
      verifyProductionDesignHardcodes(fixtureRoot);
    } finally {
      fixtureRoot.deleteSync(recursive: true);
    }
  });

  test('production verifier ignores Dart comments and unrelated strings', () {
    final fixtureRoot = Directory.systemTemp.createTempSync(
      'gamebox-flutter-non-code-',
    );
    try {
      _writeFixture(fixtureRoot, 'app/lib/non_code.dart', r'''
// EdgeInsetsDirectional.only(start: 7)
/* Colors.red and fontSize: 13.5 */
final single = 'Colors.red';
final double = "fontSize: 13.5";
final escaped = "quoted \"Colors.red\" value";
final raw = r'EdgeInsetsDirectional.only(start: 7)';
final multiline = """
Colors.red
fontSize: 13.5
""";
final rawMultiline = r"""
EdgeInsetsDirectional.only(start: 7)
""";
''');
      verifyProductionDesignHardcodes(fixtureRoot);
    } finally {
      fixtureRoot.deleteSync(recursive: true);
    }
  });

  test('production verifier masks complete Dart interpolated strings', () {
    final fixtureRoot = Directory.systemTemp.createTempSync(
      'gamebox-flutter-interpolation-',
    );
    try {
      const dollar = r'$';
      final source = <String>[
        "final exact = '$dollar{format('Colors.red')}';",
        'final otherQuote = "$dollar{format(\'Colors.red\')}";',
        "final differentQuote = '$dollar{format(\"Colors.red\")}';",
        "final nestedBraces = '$dollar{format({'style': {'value': 'Colors.red'}})}';",
        'final escaped = "' +
            dollar +
            r'''{format('escaped \' Colors.red')}";''',
        'final triple = """$dollar{format(\'Colors.red\')}""";',
        'final rawOuter = r"$dollar{format(\'Colors.red\')}";',
        "final nestedRaw = '$dollar{format(r\"Colors.red\")}';",
        "final nestedTriple = '" + dollar + r'''{format("""Colors.red""")}';''',
      ].join('\n');
      final fixture = _writeFixture(
        fixtureRoot,
        'app/lib/interpolated_strings.dart',
        '$source\n',
      );
      verifyProductionDesignHardcodes(fixtureRoot);

      fixture.writeAsStringSync('''
final color = Colors.red;
final style = TextStyle(fontSize: 13.5);
''');
      expectThrowsAll(
        () => verifyProductionDesignHardcodes(fixtureRoot),
        contains: const ['Colors.red', 'fontSize: 13.5'],
      );
    } finally {
      fixtureRoot.deleteSync(recursive: true);
    }
  });

  test('production verifier rejects Godot color literals', () {
    final fixtureRoot = Directory.systemTemp.createTempSync(
      'gamebox-godot-hardcodes-',
    );
    try {
      _writeFixture(fixtureRoot, 'game_runtime/hardcodes.gd', '''
const HEX_SIX := Color("123456")
const HEX_EIGHT := Color("#12345678")
const NAMED_STRING := Color("red")
const NUMERIC := Color(0.1, 0.2, 0.3, 1.0)
const NUMERIC_SPACED := Color ( 0.1 , 0.2 , 0.3 , 1.0 )
var derived := Color(existing_color, 0.56)
const NAMED_CONSTANT := Color.RED
var first := 1; var AFTER_SEMICOLON := Color.BLUE
theme_override_font_sizes/font_size = 28
''');
      expectThrowsAll(
        () => verifyProductionDesignHardcodes(fixtureRoot),
        contains: const [
          'Color("123456")',
          'Color("#12345678")',
          'Color("red")',
          'Color(0.1,',
          'Color ( 0.1 ,',
          'Color(existing_color, 0.56',
          'Color.RED',
          'Color.BLUE',
          'theme_override_font_sizes/font_size = 28',
        ],
      );
    } finally {
      fixtureRoot.deleteSync(recursive: true);
    }
  });

  test(
    'production verifier rejects complete Godot numeric and hex literals',
    () {
      final fixtureRoot = Directory.systemTemp.createTempSync(
        'gamebox-godot-numeric-',
      );
      try {
        _writeFixture(fixtureRoot, 'game_runtime/numeric_literals.gd', '''
const HEX_THREE := Color("#abc")
const HEX_FOUR := Color("#abcd")
const POSITIVE_EXPONENT := Color(1e+2, 0.0, 0.0, 1.0)
const NEGATIVE_EXPONENT := Color(1e-2, 0.0, 0.0, 1.0)
const UNDERSCORED := Color(1_00.0, 0.0, 0.0, 1.0)
const SEPARATED_EXPONENT := Color(1_2.3_4e-5_6, 0.0, 0.0, 1.0)
''');
        expectThrowsAll(
          () => verifyProductionDesignHardcodes(fixtureRoot),
          contains: const [
            'Color("#abc")',
            'Color("#abcd")',
            'Color(1e+2,',
            'Color(1e-2,',
            'Color(1_00.0,',
            'Color(1_2.3_4e-5_6,',
          ],
        );
      } finally {
        fixtureRoot.deleteSync(recursive: true);
      }
    },
  );

  test(
    'production verifier ignores GDScript comments and unrelated strings',
    () {
      final fixtureRoot = Directory.systemTemp.createTempSync(
        'gamebox-godot-non-code-',
      );
      try {
        final fixture = _writeFixture(
          fixtureRoot,
          'game_runtime/non_code.gd',
          r'''
# Color("red") and Color.RED
var single := 'Color("red")'
var double := "Colors.red and fontSize: 13.5"
var escaped := "quoted \"Color(0.1, 0.2, 0.3, 1.0)\" value"
var raw := r"Color.RED"
var multiline := """
Color("red")
Color(0.1, 0.2, 0.3, 1.0)
"""
''',
        );
        verifyProductionDesignHardcodes(fixtureRoot);
        fixture.writeAsStringSync('var real := Color("red")\n');
        expectThrows(
          () => verifyProductionDesignHardcodes(fixtureRoot),
          contains: 'Color("red")',
        );
      } finally {
        fixtureRoot.deleteSync(recursive: true);
      }
    },
  );

  test(
    'production verifier accepts token-backed Godot styles and coordinates',
    () {
      final fixtureRoot = Directory.systemTemp.createTempSync(
        'gamebox-godot-tokens-',
      );
      try {
        _writeFixture(fixtureRoot, 'game_runtime/token_styles.gd', '''
var board := Color(GameboxTokens.GAME["board"])
var derived := Color(existing_color, GameboxTokens.GAME["pending_overlay_alpha"])
theme_override_font_sizes/font_size = GameboxTokens.TYPOGRAPHY["body_large"]["font_size"]
var coordinate := Vector2(60, 360)
''');
        verifyProductionDesignHardcodes(fixtureRoot);
      } finally {
        fixtureRoot.deleteSync(recursive: true);
      }
    },
  );

  test(
    'production verifier allows legacy reduction but rejects a duplicate',
    () {
      final fixtureRoot = Directory.systemTemp.createTempSync(
        'gamebox-hardcode-baseline-',
      );
      try {
        final fixture = _writeFixture(
          fixtureRoot,
          'app/lib/app.dart',
          'final color = Colors.deepPurple;\n',
        );
        verifyProductionDesignHardcodes(fixtureRoot);
        fixture.writeAsStringSync(
          'final first = Colors.deepPurple;\n'
          'final second = Colors.deepPurple;\n',
        );
        expectThrows(
          () => verifyProductionDesignHardcodes(fixtureRoot),
          contains: 'app/lib/app.dart:Colors.deepPurple',
        );
      } finally {
        fixtureRoot.deleteSync(recursive: true);
      }
    },
  );

  test('production hard-code baseline has no additions', () {
    verifyProductionDesignHardcodes(repositoryRoot);
  });

  test('production verifier scans lookalike generated directories', () {
    final fixtureRoot = Directory.systemTemp.createTempSync(
      'gamebox-generated-lookalike-',
    );
    try {
      _writeFixture(
        fixtureRoot,
        'app/lib/foo/design_system/generated/hardcodes.dart',
        'final color = Colors.red;\n',
      );
      _writeFixture(
        fixtureRoot,
        'game_runtime/games/design_system/generated/hardcodes.gd',
        'const COLOR := Color.RED\n',
      );
      expectThrowsAll(
        () => verifyProductionDesignHardcodes(fixtureRoot),
        contains: const ['Colors.red', 'Color.RED'],
      );
    } finally {
      fixtureRoot.deleteSync(recursive: true);
    }
  });

  test(
    'production verifier exempts only the drift-checked generated files',
    () {
      final fixtureRoot = Directory.systemTemp.createTempSync(
        'gamebox-exact-generated-',
      );
      try {
        _writeFixture(
          fixtureRoot,
          'app/lib/design_system/generated/gamebox_tokens.g.dart',
          'final color = Colors.red;\n',
        );
        _writeFixture(
          fixtureRoot,
          'game_runtime/design_system/generated/gamebox_tokens.gd',
          'const COLOR := Color.RED\n',
        );
        verifyProductionDesignHardcodes(fixtureRoot);
      } finally {
        fixtureRoot.deleteSync(recursive: true);
      }
    },
  );

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
      const markerPrefix = 'gamebox-numeric-';
      const unit = 'dp';
      final readme = File('${fixtureRoot.path}/design_system/README.md');
      readme.writeAsStringSync(
        '${readme.readAsStringSync()}\n'
        '<!-- ${markerPrefix}claim '
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

  test('reconciliation does not treat marker text as a scan exemption', () {
    final fixtureRoot = _copyReconciliationFixture(repositoryRoot);
    try {
      const markerPrefix = 'gamebox-numeric-';
      const value = 99;
      const unit = 'dp';
      final standard = File(
        '${fixtureRoot.path}/.agents/skills/gamebox-material-3-ux/references/ux-standard.md',
      );
      standard.writeAsStringSync(
        '${standard.readAsStringSync()}\n'
        'Unregistered bypass ${markerPrefix}claim text: $value$unit.\n',
      );
      expectThrows(
        () => verifyNormativeClaims(canonicalFixture, fixtureRoot),
        contains: 'marker is only allowed',
      );
    } finally {
      fixtureRoot.deleteSync(recursive: true);
    }
  });

  test('reconciliation rejects marker text outside the registry', () {
    final fixtureRoot = _copyReconciliationFixture(repositoryRoot);
    try {
      const markerPrefix = 'gamebox-numeric-';
      final standard = File(
        '${fixtureRoot.path}/.agents/skills/gamebox-material-3-ux/references/ux-standard.md',
      );
      standard.writeAsStringSync(
        '${standard.readAsStringSync()}\n'
        'Stray ${markerPrefix}exception marker text.\n',
      );
      expectThrows(
        () => verifyNormativeClaims(canonicalFixture, fixtureRoot),
        contains: 'marker is only allowed',
      );
    } finally {
      fixtureRoot.deleteSync(recursive: true);
    }
  });

  test('reconciliation rejects malformed registry markers', () {
    final fixtureRoot = _copyReconciliationFixture(repositoryRoot);
    try {
      const markerPrefix = 'gamebox-numeric-';
      final readme = File('${fixtureRoot.path}/design_system/README.md');
      readme.writeAsStringSync(
        '${readme.readAsStringSync()}\n'
        '<!-- ${markerPrefix}claim {"id":"malformed" -->\n',
      );
      expectThrows(
        () => verifyNormativeClaims(canonicalFixture, fixtureRoot),
        contains: 'malformed numeric claim marker',
      );
    } finally {
      fixtureRoot.deleteSync(recursive: true);
    }
  });

  test('numeric exception reason must not be empty', () {
    _verifyNumericExceptionReason(
      repositoryRoot,
      canonicalFixture,
      id: 'round4-empty-reason',
      reason: '',
      expectedError: 'round4-empty-reason.reason',
    );
  });

  test('numeric exception reason must be a string', () {
    _verifyNumericExceptionReason(
      repositoryRoot,
      canonicalFixture,
      id: 'round4-numeric-reason',
      reason: 7,
      expectedError: 'round4-numeric-reason.reason',
    );
  });

  test('numeric exception reason must be a stable identifier', () {
    _verifyNumericExceptionReason(
      repositoryRoot,
      canonicalFixture,
      id: 'round4-invalid-reason',
      reason: 'Temporary_reason',
      expectedError: 'round4-invalid-reason.reason',
    );
  });

  test('numeric exception accepts a stable reason identifier', () {
    _verifyNumericExceptionReason(
      repositoryRoot,
      canonicalFixture,
      id: 'round4-valid-reason',
      reason: 'legacy-layout-constraint',
    );
  });

  test('reconciliation rejects unsafe registered paths before reading', () {
    final sandboxRoot = Directory.systemTemp.createTempSync(
      'gamebox-normative-paths-',
    );
    final temporaryFixture = _copyReconciliationFixture(repositoryRoot);
    final fixtureRoot = temporaryFixture.renameSync(
      '${sandboxRoot.path}/repository',
    );
    try {
      const value = 4;
      const unit = 'dp';
      File(
        '${sandboxRoot.path}/outside.md',
      ).writeAsStringSync('a $value$unit base grid\n');
      final standard = File(
        '${fixtureRoot.path}/.agents/skills/gamebox-material-3-ux/references/ux-standard.md',
      );
      standard.writeAsStringSync(
        standard.readAsStringSync().replaceFirst(
          'a $value$unit base grid',
          'a four-$unit base grid',
        ),
      );
      final readme = File('${fixtureRoot.path}/design_system/README.md');
      final canonicalReadme = readme.readAsStringSync();
      for (final unsafePath in [
        '../outside.md',
        '${sandboxRoot.path}/outside.md',
        '.agents/./skills/gamebox-material-3-ux/references/ux-standard.md',
        r'..\outside.md',
      ]) {
        readme.writeAsStringSync(
          _replaceRegisteredPath(
            canonicalReadme,
            id: 'ux-spacing-base',
            path: unsafePath,
          ),
        );
        expectThrows(
          () => verifyNormativeClaims(canonicalFixture, fixtureRoot),
          contains: 'must be a normalized repository-relative path',
        );
      }
    } finally {
      sandboxRoot.deleteSync(recursive: true);
    }
  });

  test('reconciliation rejects registered symlink escapes', () {
    final fixtureRoot = _copyReconciliationFixture(repositoryRoot);
    final outsideRoot = Directory.systemTemp.createTempSync(
      'gamebox-normative-symlink-',
    );
    try {
      const value = 4;
      const unit = 'dp';
      final outside = File('${outsideRoot.path}/outside.md')
        ..writeAsStringSync('a $value$unit base grid\n');
      Link('${fixtureRoot.path}/escape.md').createSync(outside.path);
      final standard = File(
        '${fixtureRoot.path}/.agents/skills/gamebox-material-3-ux/references/ux-standard.md',
      );
      standard.writeAsStringSync(
        standard.readAsStringSync().replaceFirst(
          'a $value$unit base grid',
          'a four-$unit base grid',
        ),
      );
      final readme = File('${fixtureRoot.path}/design_system/README.md');
      readme.writeAsStringSync(
        _replaceRegisteredPath(
          readme.readAsStringSync(),
          id: 'ux-spacing-base',
          path: 'escape.md',
        ),
      );
      expectThrows(
        () => verifyNormativeClaims(canonicalFixture, fixtureRoot),
        contains: 'must resolve inside the repository',
      );
    } finally {
      fixtureRoot.deleteSync(recursive: true);
      outsideRoot.deleteSync(recursive: true);
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

void expectThrowsAll(void Function() body, {required List<String> contains}) {
  try {
    body();
  } catch (error) {
    final message = error.toString();
    for (final expected in contains) {
      if (!message.contains(expected)) {
        throw StateError(
          'Expected error containing <$expected>, got <$error>.',
        );
      }
    }
    return;
  }
  throw StateError('Expected an exception containing all of <$contains>.');
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

File _writeFixture(Directory root, String relativePath, String contents) {
  final file = File('${root.path}/$relativePath');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
  return file;
}

String _replaceRegisteredPath(
  String readme, {
  required String id,
  required String path,
}) {
  final markerStart = '"id":"$id","path":';
  final start = readme.indexOf(markerStart);
  if (start < 0) {
    throw StateError('Missing numeric claim marker <$id>.');
  }
  final valueStart = start + markerStart.length;
  final valueEnd = readme.indexOf(',"token":', valueStart);
  if (valueEnd < 0) {
    throw StateError('Missing path terminator for numeric claim marker <$id>.');
  }
  return readme.replaceRange(valueStart, valueEnd, jsonEncode(path));
}

void _verifyNumericExceptionReason(
  Directory repositoryRoot,
  Map<String, Object?> canonical, {
  required String id,
  required Object reason,
  String? expectedError,
}) {
  final fixtureRoot = _copyReconciliationFixture(repositoryRoot);
  try {
    const value = 99;
    const unit = 'dp';
    const markerPrefix = 'gamebox-numeric-';
    const relativePath =
        '.agents/skills/gamebox-material-3-ux/references/ux-standard.md';
    final standard = File('${fixtureRoot.path}/$relativePath');
    standard.writeAsStringSync(
      '${standard.readAsStringSync()}\nRound four exception $value$unit.\n',
    );
    final marker = <String, Object>{
      'id': id,
      'path': relativePath,
      'value': value,
      'unit': unit,
      'context': 'Round four exception {value}$unit.',
      'reason': reason,
    };
    final readme = File('${fixtureRoot.path}/design_system/README.md');
    readme.writeAsStringSync(
      '${readme.readAsStringSync()}\n'
      '<!-- ${markerPrefix}exception ${jsonEncode(marker)} -->\n',
    );
    if (expectedError == null) {
      verifyNormativeClaims(canonical, fixtureRoot);
    } else {
      expectThrows(
        () => verifyNormativeClaims(canonical, fixtureRoot),
        contains: expectedError,
      );
    }
  } finally {
    fixtureRoot.deleteSync(recursive: true);
  }
}
