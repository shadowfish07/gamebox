import 'dart:convert';
import 'dart:io';

final class DesignTokenFormatException implements Exception {
  const DesignTokenFormatException(this.path, this.message);

  final String path;
  final String message;

  @override
  String toString() => '$path: $message';
}

final class DesignTokenDocument {
  const DesignTokenDocument({
    required this.version,
    required this.brandSeed,
    required this.schemeSource,
    required this.lightColors,
    required this.darkColors,
    required this.gameColors,
    required this.typography,
    required this.spacing,
    required this.shape,
    required this.motion,
    required this.components,
  });

  factory DesignTokenDocument.fromJson(Map<String, Object?> json) {
    _expectKeys('', json, _topLevelKeys);
    final brand = _object(json['brand'], 'brand');
    _expectKeys('brand', brand, const {'seed', 'schemeSource'});
    final colorSchemes = _object(json['colorSchemes'], 'colorSchemes');
    _expectKeys('colorSchemes', colorSchemes, const {'light', 'dark'});

    final version = _string(json['version'], 'version');
    if (!RegExp(r'^[0-9]+\.[0-9]+\.[0-9]+$').hasMatch(version)) {
      throw const DesignTokenFormatException(
        'version',
        'must be a semantic version.',
      );
    }
    final brandSeed = _color(brand['seed'], 'brand.seed');
    final schemeSource = _string(brand['schemeSource'], 'brand.schemeSource');
    if (schemeSource.isEmpty) {
      throw const DesignTokenFormatException(
        'brand.schemeSource',
        'must not be empty.',
      );
    }

    return DesignTokenDocument(
      version: version,
      brandSeed: brandSeed,
      schemeSource: schemeSource,
      lightColors: _colorMap(
        colorSchemes['light'],
        'colorSchemes.light',
        _colorSchemeRoles,
      ),
      darkColors: _colorMap(
        colorSchemes['dark'],
        'colorSchemes.dark',
        _colorSchemeRoles,
      ),
      gameColors: _gameMap(json['game']),
      typography: _typographyMap(json['typography']),
      spacing: _positiveMap(json['spacing'], 'spacing', _spacingRoles),
      shape: _positiveMap(json['shape'], 'shape', _shapeRoles),
      motion: _positiveIntegerMap(json['motion'], 'motion', _motionRoles),
      components: _positiveMap(json['component'], 'component', _componentRoles),
    );
  }

  final String version;
  final String brandSeed;
  final String schemeSource;
  final Map<String, String> lightColors;
  final Map<String, String> darkColors;
  final Map<String, Object> gameColors;
  final Map<String, Map<String, num>> typography;
  final Map<String, num> spacing;
  final Map<String, num> shape;
  final Map<String, num> motion;
  final Map<String, num> components;
}

const canonicalDesignTokenSchemaReference = '../schema/tokens.schema.json';

DesignTokenDocument loadCanonicalDesignTokenDocument({
  required File inputFile,
  required File committedSchemaFile,
}) {
  final canonical = _readJsonObject(inputFile);
  final schemaReference = canonical[r'$schema'];
  if (schemaReference != canonicalDesignTokenSchemaReference) {
    throw const DesignTokenFormatException(
      r'$.$schema',
      'must equal ../schema/tokens.schema.json.',
    );
  }
  final schema = _readJsonObject(committedSchemaFile);
  validateJsonSchema(schema, canonical);
  return DesignTokenDocument.fromJson(canonical);
}

Map<String, Object?> _readJsonObject(File file) {
  final decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map<String, Object?>) {
    throw DesignTokenFormatException(file.path, 'must contain a JSON object.');
  }
  return decoded;
}

const _topLevelKeys = {
  r'$schema',
  'version',
  'brand',
  'colorSchemes',
  'game',
  'typography',
  'spacing',
  'shape',
  'motion',
  'component',
};

const _colorSchemeRoles = {
  'primary',
  'onPrimary',
  'primaryContainer',
  'onPrimaryContainer',
  'primaryFixed',
  'primaryFixedDim',
  'onPrimaryFixed',
  'onPrimaryFixedVariant',
  'secondary',
  'onSecondary',
  'secondaryContainer',
  'onSecondaryContainer',
  'secondaryFixed',
  'secondaryFixedDim',
  'onSecondaryFixed',
  'onSecondaryFixedVariant',
  'tertiary',
  'onTertiary',
  'tertiaryContainer',
  'onTertiaryContainer',
  'tertiaryFixed',
  'tertiaryFixedDim',
  'onTertiaryFixed',
  'onTertiaryFixedVariant',
  'error',
  'onError',
  'errorContainer',
  'onErrorContainer',
  'surface',
  'onSurface',
  'surfaceDim',
  'surfaceBright',
  'surfaceContainerLowest',
  'surfaceContainerLow',
  'surfaceContainer',
  'surfaceContainerHigh',
  'surfaceContainerHighest',
  'onSurfaceVariant',
  'outline',
  'outlineVariant',
  'inverseSurface',
  'onInverseSurface',
  'inversePrimary',
  'surfaceTint',
  'shadow',
  'scrim',
};

const _gameColorRoles = {
  'board',
  'grid',
  'blackPiece',
  'whitePiece',
  'whitePieceOutline',
  'lastMove',
  'pressedMove',
  'pendingMove',
};
const _gameRoles = {..._gameColorRoles, 'pendingOverlayAlpha'};
const _typeRoles = {
  'displayLarge',
  'displayMedium',
  'displaySmall',
  'headlineLarge',
  'headlineMedium',
  'headlineSmall',
  'titleLarge',
  'titleMedium',
  'titleSmall',
  'bodyLarge',
  'bodyMedium',
  'bodySmall',
  'labelLarge',
  'labelMedium',
  'labelSmall',
};
const _typeStyleRoles = {'fontSize', 'fontWeight', 'lineHeight'};
const _spacingRoles = {
  'base',
  'layout',
  'compact',
  'page',
  'section',
  'large',
  'xlarge',
  'xxlarge',
};
const _shapeRoles = {'input', 'card', 'floating', 'dialog', 'full'};
const _motionRoles = {'fast', 'standard', 'slow', 'pageEnter'};
const _componentRoles = {
  'minimumTouchTarget',
  'pageMaxWidth',
  'pagePadding',
  'sectionSpacing',
  'smallProgressSize',
};

Map<String, Object?> _object(Object? value, String path) {
  if (value is! Map) {
    throw DesignTokenFormatException(path, 'must be an object.');
  }
  if (value.keys.any((key) => key is! String)) {
    throw DesignTokenFormatException(path, 'must use string keys.');
  }
  return value.cast<String, Object?>();
}

String _string(Object? value, String path) {
  if (value is! String) {
    throw DesignTokenFormatException(path, 'must be a string.');
  }
  return value;
}

String _color(Object? value, String path) {
  final color = _string(value, path);
  if (!RegExp(r'^#[0-9A-F]{6}$').hasMatch(color)) {
    throw DesignTokenFormatException(path, 'must match uppercase #RRGGBB.');
  }
  return color;
}

num _positiveNumber(Object? value, String path) {
  if (value is! num || !value.isFinite || value <= 0) {
    throw DesignTokenFormatException(path, 'must be a finite positive number.');
  }
  return value;
}

int _positiveInteger(Object? value, String path) {
  if (value is! num ||
      !value.isFinite ||
      value <= 0 ||
      value != value.roundToDouble()) {
    throw DesignTokenFormatException(
      path,
      'must be a finite positive integer.',
    );
  }
  return value.toInt();
}

int _fontWeight(Object? value, String path) {
  final weight = _positiveInteger(value, path);
  if (weight < 100 || weight > 900 || weight % 100 != 0) {
    throw DesignTokenFormatException(
      path,
      'must be a shared font weight from 100 through 900 in steps of 100.',
    );
  }
  return weight;
}

void _expectKeys(
  String path,
  Map<String, Object?> object,
  Set<String> expected,
) {
  for (final key in expected) {
    if (!object.containsKey(key)) {
      throw DesignTokenFormatException(_join(path, key), 'is required.');
    }
  }
  for (final key in object.keys) {
    if (!expected.contains(key)) {
      throw DesignTokenFormatException(_join(path, key), 'is not supported.');
    }
  }
}

Map<String, String> _colorMap(Object? value, String path, Set<String> roles) {
  final object = _object(value, path);
  _expectKeys(path, object, roles);
  return {
    for (final role in roles) role: _color(object[role], _join(path, role)),
  };
}

Map<String, Object> _gameMap(Object? value) {
  const path = 'game';
  final object = _object(value, path);
  _expectKeys(path, object, _gameRoles);
  final alpha = _positiveNumber(
    object['pendingOverlayAlpha'],
    'game.pendingOverlayAlpha',
  );
  if (alpha > 1) {
    throw const DesignTokenFormatException(
      'game.pendingOverlayAlpha',
      'must not exceed 1.',
    );
  }
  return {
    for (final role in _gameColorRoles)
      role: _color(object[role], 'game.$role'),
    'pendingOverlayAlpha': alpha,
  };
}

Map<String, Map<String, num>> _typographyMap(Object? value) {
  const path = 'typography';
  final object = _object(value, path);
  _expectKeys(path, object, _typeRoles);
  return {
    for (final role in _typeRoles)
      role: _typeStyle(object[role], 'typography.$role'),
  };
}

Map<String, num> _typeStyle(Object? value, String path) {
  final object = _object(value, path);
  _expectKeys(path, object, _typeStyleRoles);
  return {
    'fontSize': _positiveNumber(object['fontSize'], '$path.fontSize'),
    'fontWeight': _fontWeight(object['fontWeight'], '$path.fontWeight'),
    'lineHeight': _positiveNumber(object['lineHeight'], '$path.lineHeight'),
  };
}

Map<String, num> _positiveMap(Object? value, String path, Set<String> roles) {
  final object = _object(value, path);
  _expectKeys(path, object, roles);
  return {
    for (final role in roles)
      role: _positiveNumber(object[role], '$path.$role'),
  };
}

Map<String, num> _positiveIntegerMap(
  Object? value,
  String path,
  Set<String> roles,
) {
  final object = _object(value, path);
  _expectKeys(path, object, roles);
  return {
    for (final role in roles)
      role: _positiveInteger(object[role], '$path.$role'),
  };
}

String _join(String path, String key) =>
    path.isEmpty ? r'$.' + key : '$path.$key';

void validateJsonSchema(Map<String, Object?> schema, Object? instance) {
  _assertSupportedSchema(schema, r'$');
  _validateSchemaNode(schema, instance, r'$', schema, r'$');
}

const _supportedSchemaKeywords = {
  r'$schema',
  r'$id',
  r'$defs',
  r'$ref',
  'title',
  'type',
  'const',
  'pattern',
  'exclusiveMinimum',
  'minimum',
  'maximum',
  'multipleOf',
  'additionalProperties',
  'required',
  'properties',
};

void _assertSupportedSchema(Map<String, Object?> schema, String schemaPath) {
  for (final entry in schema.entries) {
    if (!_supportedSchemaKeywords.contains(entry.key)) {
      throw DesignTokenFormatException(
        '$schemaPath.${entry.key}',
        'unsupported JSON Schema keyword.',
      );
    }
  }
  for (final containerKey in const [r'$defs', 'properties']) {
    final container = schema[containerKey];
    if (container == null) {
      continue;
    }
    final definitions = _schemaObject(container, '$schemaPath.$containerKey');
    for (final entry in definitions.entries) {
      final child = _schemaObject(
        entry.value,
        '$schemaPath.$containerKey.${entry.key}',
      );
      _assertSupportedSchema(child, '$schemaPath.$containerKey.${entry.key}');
    }
  }
}

Map<String, Object?> _schemaObject(Object? value, String schemaPath) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw DesignTokenFormatException(schemaPath, 'schema must be an object.');
  }
  return value.cast<String, Object?>();
}

void _validateSchemaNode(
  Map<String, Object?> schema,
  Object? instance,
  String instancePath,
  Map<String, Object?> rootSchema,
  String schemaPath,
) {
  final reference = schema[r'$ref'];
  if (reference != null) {
    if (reference is! String || !reference.startsWith(r'#/$defs/')) {
      throw DesignTokenFormatException(
        '$schemaPath.\$ref',
        'only local #/\$defs references are supported.',
      );
    }
    final name = reference.substring(r'#/$defs/'.length);
    final definitions = _schemaObject(rootSchema[r'$defs'], r'$.$defs');
    final target = _schemaObject(definitions[name], r'$.$defs.' + name);
    _validateSchemaNode(
      target,
      instance,
      instancePath,
      rootSchema,
      r'$.$defs.' + name,
    );
  }

  final type = schema['type'];
  if (type != null) {
    if (type is! String ||
        !const {'object', 'string', 'number', 'integer'}.contains(type)) {
      throw DesignTokenFormatException(
        '$schemaPath.type',
        'unsupported schema type.',
      );
    }
    final valid = switch (type) {
      'object' => instance is Map,
      'string' => instance is String,
      'number' => instance is num && instance.isFinite,
      'integer' =>
        instance is num &&
            instance.isFinite &&
            instance == instance.roundToDouble(),
      _ => false,
    };
    if (!valid) {
      throw DesignTokenFormatException(instancePath, 'must be a $type.');
    }
  }

  if (schema.containsKey('const') && instance != schema['const']) {
    throw DesignTokenFormatException(
      instancePath,
      'must equal ${jsonEncode(schema['const'])}.',
    );
  }

  final pattern = schema['pattern'];
  if (pattern != null) {
    if (pattern is! String) {
      throw DesignTokenFormatException(
        '$schemaPath.pattern',
        'must be a string.',
      );
    }
    if (instance is String && !RegExp(pattern).hasMatch(instance)) {
      throw DesignTokenFormatException(
        instancePath,
        'does not match $pattern.',
      );
    }
  }

  _validateNumberBoundary(
    schema,
    instance,
    instancePath,
    schemaPath,
    'exclusiveMinimum',
    (value, boundary) => value > boundary,
  );
  _validateNumberBoundary(
    schema,
    instance,
    instancePath,
    schemaPath,
    'minimum',
    (value, boundary) => value >= boundary,
  );
  _validateNumberBoundary(
    schema,
    instance,
    instancePath,
    schemaPath,
    'maximum',
    (value, boundary) => value <= boundary,
  );
  final multipleOf = schema['multipleOf'];
  if (multipleOf != null) {
    if (multipleOf is! num || !multipleOf.isFinite || multipleOf <= 0) {
      throw DesignTokenFormatException(
        '$schemaPath.multipleOf',
        'must be a finite positive number.',
      );
    }
    if (instance is num && instance % multipleOf != 0) {
      throw DesignTokenFormatException(
        instancePath,
        'must be a multiple of $multipleOf.',
      );
    }
  }

  if (instance is Map) {
    if (instance.keys.any((key) => key is! String)) {
      throw DesignTokenFormatException(instancePath, 'must use string keys.');
    }
    final object = instance.cast<String, Object?>();
    final required = schema['required'];
    if (required != null) {
      if (required is! List || required.any((key) => key is! String)) {
        throw DesignTokenFormatException(
          '$schemaPath.required',
          'must be a string array.',
        );
      }
      for (final key in required.cast<String>()) {
        if (!object.containsKey(key)) {
          throw DesignTokenFormatException(
            _instanceJoin(instancePath, key),
            'is required by schema.',
          );
        }
      }
    }
    final propertiesValue = schema['properties'];
    final properties = propertiesValue == null
        ? const <String, Object?>{}
        : _schemaObject(propertiesValue, '$schemaPath.properties');
    if (schema['additionalProperties'] == false) {
      for (final key in object.keys) {
        if (!properties.containsKey(key)) {
          throw DesignTokenFormatException(
            _instanceJoin(instancePath, key),
            'additional property is not allowed by schema.',
          );
        }
      }
    } else if (schema.containsKey('additionalProperties') &&
        schema['additionalProperties'] != true) {
      throw DesignTokenFormatException(
        '$schemaPath.additionalProperties',
        'only boolean additionalProperties is supported.',
      );
    }
    for (final entry in properties.entries) {
      if (!object.containsKey(entry.key)) {
        continue;
      }
      _validateSchemaNode(
        _schemaObject(entry.value, '$schemaPath.properties.${entry.key}'),
        object[entry.key],
        _instanceJoin(instancePath, entry.key),
        rootSchema,
        '$schemaPath.properties.${entry.key}',
      );
    }
  }
}

void _validateNumberBoundary(
  Map<String, Object?> schema,
  Object? instance,
  String instancePath,
  String schemaPath,
  String keyword,
  bool Function(num value, num boundary) accepts,
) {
  final boundary = schema[keyword];
  if (boundary == null) {
    return;
  }
  if (boundary is! num || !boundary.isFinite) {
    throw DesignTokenFormatException(
      '$schemaPath.$keyword',
      'must be a finite number.',
    );
  }
  if (instance is num && !accepts(instance, boundary)) {
    throw DesignTokenFormatException(
      instancePath,
      'violates schema $keyword $boundary.',
    );
  }
}

String _instanceJoin(String path, String key) =>
    path == r'$' ? r'$.' + key : '$path.$key';

String renderDart(DesignTokenDocument document) {
  final output = StringBuffer()
    ..writeln('// GENERATED CODE - DO NOT MODIFY BY HAND.')
    ..writeln('// Source: design_system/tokens/gamebox.tokens.json')
    ..writeln()
    ..writeln("import 'package:flutter/material.dart';")
    ..writeln()
    ..writeln('abstract final class GameboxTokens {')
    ..writeln("  static const version = '${document.version}';")
    ..writeln(
      "  static const brandSeed = Color(${_dartColor(document.brandSeed)});",
    )
    ..writeln()
    ..write(
      _renderDartScheme('lightColorScheme', 'light', document.lightColors),
    )
    ..writeln()
    ..write(_renderDartScheme('darkColorScheme', 'dark', document.darkColors))
    ..writeln()
    ..write(
      _renderDartTokenValue('spacing', 'GameboxSpacing', document.spacing),
    )
    ..write(_renderDartTypographyValue(document.typography))
    ..write(_renderDartTokenValue('shape', 'GameboxShape', document.shape))
    ..write(_renderDartMotionValue(document.motion))
    ..write(
      _renderDartTokenValue(
        'components',
        'GameboxComponentTokens',
        document.components,
      ),
    )
    ..write(_renderDartGameValue(document.gameColors))
    ..writeln('}')
    ..writeln();

  _writeDartNumberClass(output, 'GameboxSpacing', document.spacing);
  _writeDartTypographyClasses(output, document.typography);
  _writeDartNumberClass(output, 'GameboxShape', document.shape);
  _writeDartMotionClass(output, document.motion);
  _writeDartNumberClass(output, 'GameboxComponentTokens', document.components);
  _writeDartGameClass(output, document.gameColors);
  return _singleTrailingNewline(output.toString());
}

String _renderDartScheme(
  String fieldName,
  String brightness,
  Map<String, String> colors,
) {
  final output = StringBuffer()
    ..writeln('  static const $fieldName = ColorScheme(')
    ..writeln('    brightness: Brightness.$brightness,');
  for (final key in _sortedKeys(colors)) {
    output.writeln('    $key: Color(${_dartColor(colors[key]!)}),');
  }
  output.writeln('  );');
  return output.toString();
}

String _renderDartTokenValue(
  String fieldName,
  String className,
  Map<String, num> values,
) {
  final output = StringBuffer()
    ..writeln('  static const $fieldName = $className(');
  for (final key in _sortedKeys(values)) {
    output.writeln('    $key: ${_dartDouble(values[key]!)},');
  }
  output.writeln('  );');
  return output.toString();
}

String _renderDartTypographyValue(Map<String, Map<String, num>> typography) {
  final output = StringBuffer()
    ..writeln('  static const typography = GameboxTypography(');
  for (final role in _sortedKeys(typography)) {
    final style = typography[role]!;
    output
      ..writeln('    $role: GameboxTypeStyle(')
      ..writeln('      fontSize: ${_dartDouble(style['fontSize']!)},')
      ..writeln('      fontWeight: ${style['fontWeight']!.toInt()},')
      ..writeln('      lineHeight: ${_dartDouble(style['lineHeight']!)},')
      ..writeln('    ),');
  }
  output.writeln('  );');
  return output.toString();
}

String _renderDartMotionValue(Map<String, num> values) {
  final output = StringBuffer()
    ..writeln('  static const motion = GameboxMotion(');
  for (final key in _sortedKeys(values)) {
    output.writeln(
      '    $key: Duration(milliseconds: ${values[key]!.toInt()}),',
    );
  }
  output.writeln('  );');
  return output.toString();
}

String _renderDartGameValue(Map<String, Object> values) {
  final output = StringBuffer()
    ..writeln('  static const gameColors = GameboxGameColors(');
  for (final key in _sortedKeys(values)) {
    final value = values[key]!;
    if (value is String) {
      output.writeln('    $key: Color(${_dartColor(value)}),');
    } else {
      output.writeln('    $key: ${_dartDouble(value as num)},');
    }
  }
  output.writeln('  );');
  return output.toString();
}

void _writeDartNumberClass(
  StringBuffer output,
  String className,
  Map<String, num> values,
) {
  final keys = _sortedKeys(values);
  output
    ..writeln('final class $className {')
    ..writeln('  const $className({');
  for (final key in keys) {
    output.writeln('    required this.$key,');
  }
  output
    ..writeln('  });')
    ..writeln();
  for (final key in keys) {
    output.writeln('  final double $key;');
  }
  output
    ..writeln('}')
    ..writeln();
}

void _writeDartTypographyClasses(
  StringBuffer output,
  Map<String, Map<String, num>> typography,
) {
  final roles = _sortedKeys(typography);
  output
    ..writeln('final class GameboxTypography {')
    ..writeln('  const GameboxTypography({');
  for (final role in roles) {
    output.writeln('    required this.$role,');
  }
  output
    ..writeln('  });')
    ..writeln();
  for (final role in roles) {
    output.writeln('  final GameboxTypeStyle $role;');
  }
  output
    ..writeln('}')
    ..writeln()
    ..writeln('final class GameboxTypeStyle {')
    ..writeln('  const GameboxTypeStyle({')
    ..writeln('    required this.fontSize,')
    ..writeln('    required this.fontWeight,')
    ..writeln('    required this.lineHeight,')
    ..writeln('  });')
    ..writeln()
    ..writeln('  final double fontSize;')
    ..writeln('  final int fontWeight;')
    ..writeln('  final double lineHeight;')
    ..writeln('}')
    ..writeln();
}

void _writeDartMotionClass(StringBuffer output, Map<String, num> values) {
  final keys = _sortedKeys(values);
  output
    ..writeln('final class GameboxMotion {')
    ..writeln('  const GameboxMotion({');
  for (final key in keys) {
    output.writeln('    required this.$key,');
  }
  output
    ..writeln('  });')
    ..writeln();
  for (final key in keys) {
    output.writeln('  final Duration $key;');
  }
  output
    ..writeln('}')
    ..writeln();
}

void _writeDartGameClass(StringBuffer output, Map<String, Object> values) {
  final keys = _sortedKeys(values);
  output
    ..writeln('final class GameboxGameColors {')
    ..writeln('  const GameboxGameColors({');
  for (final key in keys) {
    output.writeln('    required this.$key,');
  }
  output
    ..writeln('  });')
    ..writeln();
  for (final key in keys) {
    output.writeln(
      '  final ${values[key] is String ? 'Color' : 'double'} $key;',
    );
  }
  output
    ..writeln('}')
    ..writeln();
}

String _dartColor(String color) => '0xFF${color.substring(1)}';

String _dartDouble(num value) {
  if (value is int || value == value.roundToDouble()) {
    return '${value.toInt()}.0';
  }
  return value.toString();
}

String renderGdscript(DesignTokenDocument document) {
  final output = StringBuffer()
    ..writeln('# GENERATED CODE - DO NOT MODIFY BY HAND.')
    ..writeln('# Source: design_system/tokens/gamebox.tokens.json')
    ..writeln()
    ..writeln('class_name GameboxTokens')
    ..writeln('extends RefCounted')
    ..writeln()
    ..writeln('const VERSION := "${document.version}"')
    ..writeln('const BRAND_SEED := "${document.brandSeed}"')
    ..writeln()
    ..write(_renderGdscriptMap('LIGHT', document.lightColors))
    ..writeln()
    ..write(_renderGdscriptMap('DARK', document.darkColors))
    ..writeln()
    ..write(_renderGdscriptMap('GAME', document.gameColors))
    ..writeln()
    ..write(_renderGdscriptTypography(document.typography))
    ..writeln()
    ..write(_renderGdscriptMap('SPACING', document.spacing))
    ..writeln()
    ..write(_renderGdscriptMap('SHAPE', document.shape))
    ..writeln()
    ..write(_renderGdscriptMap('MOTION', document.motion))
    ..writeln()
    ..write(_renderGdscriptMap('COMPONENT', document.components));
  return _singleTrailingNewline(output.toString());
}

String _renderGdscriptMap(String name, Map<String, Object> values) {
  final output = StringBuffer()..writeln('const $name := {');
  for (final key in _sortedKeys(values)) {
    output.writeln(
      '    "${_snakeCase(key)}": ${_gdscriptValue(values[key]!)},',
    );
  }
  output.writeln('}');
  return output.toString();
}

String _renderGdscriptTypography(Map<String, Map<String, num>> typography) {
  final output = StringBuffer()..writeln('const TYPOGRAPHY := {');
  for (final role in _sortedKeys(typography)) {
    output.writeln('    "${_snakeCase(role)}": {');
    final style = typography[role]!;
    for (final key in _sortedKeys(style)) {
      output.writeln(
        '        "${_snakeCase(key)}": ${_gdscriptValue(style[key]!)},',
      );
    }
    output.writeln('    },');
  }
  output.writeln('}');
  return output.toString();
}

String _gdscriptValue(Object value) {
  if (value is String) {
    return 'Color("$value")';
  }
  return value.toString();
}

String _snakeCase(String value) {
  return value.replaceAllMapped(
    RegExp(r'([a-z0-9])([A-Z])'),
    (match) => '${match.group(1)}_${match.group(2)!.toLowerCase()}',
  );
}

List<String> _sortedKeys(Map<String, Object?> values) {
  return values.keys.toList()..sort();
}

String _singleTrailingNewline(String value) => '${value.trimRight()}\n';

void verifyProductionDesignHardcodes(Directory repositoryRoot) {
  final flutterMatches = _collectStyleLiterals(
    repositoryRoot,
    relativeRoot: 'app/lib',
    extensions: const {'.dart'},
    pattern: _flutterStyleLiteralPattern(),
  );
  final godotMatches = _collectStyleLiterals(
    repositoryRoot,
    relativeRoot: 'game_runtime',
    extensions: const {'.gd', '.tscn'},
    pattern: _godotStyleLiteralPattern(),
  );
  final newFlutter = _subtractExactMultiset(
    flutterMatches,
    _flutterStyleLiteralBaseline,
  );
  final newGodot = _subtractExactMultiset(
    godotMatches,
    _godotStyleLiteralBaseline,
  );
  if (newFlutter.isEmpty && newGodot.isEmpty) {
    return;
  }
  final message = StringBuffer();
  if (newFlutter.isNotEmpty) {
    message.writeln('New Flutter production style literals are forbidden:');
    for (final match in newFlutter) {
      message.writeln('  $match');
    }
  }
  if (newGodot.isNotEmpty) {
    message.writeln('New Godot production style literals are forbidden:');
    for (final match in newGodot) {
      message.writeln('  $match');
    }
  }
  throw DesignTokenFormatException(
    'productionStyleLiterals',
    message.toString().trimRight(),
  );
}

RegExp _flutterStyleLiteralPattern() {
  const number =
      r'(?<![A-Za-z0-9_.])(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)(?![A-Za-z0-9_.])';
  return RegExp(
    '\\bColors\\s*\\.\\s*[A-Za-z_][A-Za-z0-9_]*'
    '|\\bColor\\s*\\(\\s*(?:0x[0-9A-Fa-f]+|$number)'
    '|\\bColor\\s*\\.\\s*(?:fromARGB|fromRGBO)\\s*\\([^)]*?$number'
    '|\\bfontSize\\s*:\\s*[^,\\n})]*?$number'
    '|\\bBorderRadius\\s*\\.\\s*[A-Za-z_][A-Za-z0-9_]*\\s*\\([^)]*?$number'
    '|\\bDuration\\s*\\(\\s*milliseconds\\s*:\\s*[^,)\\n]*?$number'
    '|\\bEdgeInsets(?:Directional)?\\s*\\.\\s*'
    '(?:all|symmetric|only|fromLTRB|fromSTEB)\\s*\\([^)]*?$number'
    '|\\bSizedBox(?:\\s*\\.\\s*square)?\\s*\\([^)]*?'
    '(?:width|height|dimension)\\s*:\\s*$number'
    '|\\b(?:spacing|runSpacing|mainAxisSpacing|crossAxisSpacing)'
    '\\s*:\\s*[^,\\n})]*?$number',
    multiLine: true,
    dotAll: true,
  );
}

RegExp _godotStyleLiteralPattern() {
  const number =
      r'(?<![A-Za-z0-9_.])(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)(?![A-Za-z0-9_.])';
  return RegExp(
    '\\bColor\\s*\\(\\s*[\"\\\']'
    '(?:#?[0-9A-Fa-f]{6}(?:[0-9A-Fa-f]{2})?|[A-Za-z][A-Za-z0-9_]*)'
    '[\"\\\']\\s*\\)'
    '|\\bColor\\s*\\.\\s*[A-Z][A-Z0-9_]*'
    '|\\bColor\\s*\\(\\s*$number\\s*,'
    '|\\bColor\\s*\\(\\s*[^,\\n]+,\\s*[^)]*?$number'
    '|\\btheme_override_[A-Za-z0-9_/]+\\s*=\\s*$number',
    multiLine: true,
    dotAll: true,
  );
}

List<String> _collectStyleLiterals(
  Directory repositoryRoot, {
  required String relativeRoot,
  required Set<String> extensions,
  required RegExp pattern,
}) {
  final sourceRoot = Directory('${repositoryRoot.path}/$relativeRoot');
  if (!sourceRoot.existsSync()) {
    return const [];
  }
  final files =
      sourceRoot
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where((file) {
            final relativePath = _relativePath(repositoryRoot, file);
            if (relativePath.contains('/design_system/generated/')) {
              return false;
            }
            return extensions.any(file.path.endsWith);
          })
          .toList()
        ..sort((left, right) => left.path.compareTo(right.path));
  final matches = <String>[];
  for (final file in files) {
    final relativePath = _relativePath(repositoryRoot, file);
    for (final match in pattern.allMatches(file.readAsStringSync())) {
      matches.add('$relativePath:${_normalizeStyleLiteral(match.group(0)!)}');
    }
  }
  matches.sort();
  return matches;
}

String _normalizeStyleLiteral(String literal) =>
    literal.replaceAll(RegExp(r'\s+'), ' ');

List<String> _subtractExactMultiset(
  List<String> actual,
  List<String> baseline,
) {
  final available = <String, int>{};
  for (final match in baseline) {
    available.update(match, (count) => count + 1, ifAbsent: () => 1);
  }
  final additions = <String>[];
  for (final match in actual) {
    final count = available[match] ?? 0;
    if (count == 0) {
      additions.add(match);
    } else {
      available[match] = count - 1;
    }
  }
  return additions;
}

const _flutterStyleLiteralBaseline = <String>[
  'app/lib/app.dart:Colors.deepPurple',
  'app/lib/app.dart:SizedBox(height: 12',
  'app/lib/app.dart:SizedBox(height: 12',
  'app/lib/app.dart:SizedBox(height: 16',
  'app/lib/features/auth/registration_page.dart:EdgeInsets.all(24',
  'app/lib/features/auth/registration_page.dart:EdgeInsets.all(24',
  'app/lib/features/auth/registration_page.dart:EdgeInsets.all(24',
  'app/lib/features/auth/registration_page.dart:SizedBox(height: 16',
  'app/lib/features/auth/registration_page.dart:SizedBox(height: 16',
  'app/lib/features/auth/registration_page.dart:SizedBox(height: 24',
  'app/lib/features/auth/registration_page.dart:SizedBox(height: 24',
  'app/lib/features/auth/registration_page.dart:SizedBox(height: 24',
  'app/lib/features/auth/registration_page.dart:SizedBox(height: 24',
  'app/lib/features/auth/registration_page.dart:SizedBox(height: 8',
  'app/lib/features/auth/registration_page.dart:SizedBox(height: 8',
  'app/lib/features/auth/registration_page.dart:SizedBox.square( dimension: 20',
  'app/lib/features/home/home_page.dart:EdgeInsets.all(20',
  'app/lib/features/home/home_page.dart:EdgeInsets.all(24',
  'app/lib/features/home/home_page.dart:SizedBox(height: 16',
  'app/lib/features/home/home_page.dart:SizedBox(height: 16',
  'app/lib/features/home/home_page.dart:SizedBox(height: 16',
  'app/lib/features/home/home_page.dart:SizedBox(height: 20',
  'app/lib/features/home/home_page.dart:SizedBox(height: 8',
  'app/lib/features/home/home_page.dart:SizedBox(height: 8',
  'app/lib/features/home/home_page.dart:SizedBox.square( dimension: 20',
  'app/lib/features/home/opponent_page.dart:EdgeInsets.all(24',
  'app/lib/features/home/opponent_page.dart:EdgeInsets.all(24',
  'app/lib/features/home/opponent_page.dart:EdgeInsets.fromLTRB(20',
  'app/lib/features/home/opponent_page.dart:EdgeInsets.symmetric(vertical: 12',
  'app/lib/features/home/opponent_page.dart:SizedBox(height: 16',
  'app/lib/features/home/opponent_page.dart:SizedBox.square( dimension: 20',
  'app/lib/features/update/update_action.dart:SizedBox(height: 12',
  'app/lib/features/update/update_action.dart:SizedBox(height: 16',
  'app/lib/features/update/update_action.dart:SizedBox(height: 16',
  'app/lib/features/update/update_action.dart:SizedBox(height: 6',
  'app/lib/features/update/update_action.dart:SizedBox(height: 8',
  'app/lib/features/update/update_action.dart:SizedBox(width: 10',
  'app/lib/features/update/update_action.dart:SizedBox( width: 420',
  'app/lib/features/update/update_action.dart:SizedBox.square( dimension: 18',
  'app/lib/features/update/update_action.dart:SizedBox.square( dimension: 20',
];

const _godotStyleLiteralBaseline = <String>[
  'game_runtime/games/gomoku/gomoku_board.gd:Color("0072b2")',
  'game_runtime/games/gomoku/gomoku_board.gd:Color("151a24")',
  'game_runtime/games/gomoku/gomoku_board.gd:Color("493217")',
  'game_runtime/games/gomoku/gomoku_board.gd:Color("667085")',
  'game_runtime/games/gomoku/gomoku_board.gd:Color("d8a85f")',
  'game_runtime/games/gomoku/gomoku_board.gd:Color("f04438")',
  'game_runtime/games/gomoku/gomoku_board.gd:Color("f8fafc")',
  'game_runtime/games/gomoku/gomoku_board.gd:Color(PENDING_COLOR, 0.24',
  'game_runtime/games/gomoku/gomoku_scene.tscn:Color(0.105882,',
  'game_runtime/games/gomoku/gomoku_scene.tscn:Color(0.105882,',
  'game_runtime/games/gomoku/gomoku_scene.tscn:Color(0.105882,',
  'game_runtime/games/gomoku/gomoku_scene.tscn:Color(0.290196,',
  'game_runtime/games/gomoku/gomoku_scene.tscn:Color(0.705882,',
  'game_runtime/games/gomoku/gomoku_scene.tscn:Color(0.956863,',
  'game_runtime/games/gomoku/gomoku_scene.tscn:'
      'theme_override_font_sizes/font_size = 24',
  'game_runtime/games/gomoku/gomoku_scene.tscn:'
      'theme_override_font_sizes/font_size = 28',
  'game_runtime/games/gomoku/gomoku_scene.tscn:'
      'theme_override_font_sizes/font_size = 30',
  'game_runtime/games/gomoku/gomoku_scene.tscn:'
      'theme_override_font_sizes/font_size = 32',
  'game_runtime/games/gomoku/gomoku_scene.tscn:'
      'theme_override_font_sizes/font_size = 32',
  'game_runtime/games/gomoku/gomoku_scene.tscn:'
      'theme_override_font_sizes/font_size = 40',
  'game_runtime/games/gomoku/gomoku_scene.tscn:'
      'theme_override_font_sizes/font_size = 42',
];

void verifyNormativeClaims(
  Map<String, Object?> canonical,
  Directory repositoryRoot,
) {
  final registryFile = File('${repositoryRoot.path}/design_system/README.md');
  if (!registryFile.existsSync()) {
    throw const DesignTokenFormatException(
      'design_system/README.md',
      'numeric claim registry is missing.',
    );
  }
  final registry = _parseNumericClaimRegistry(registryFile.readAsLinesSync());
  final scanPaths = <String>{
    ...Directory(
          '${repositoryRoot.path}/.agents/skills/gamebox-material-3-ux/references',
        )
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.md'))
        .map((file) => _relativePath(repositoryRoot, file)),
    'docs/superpowers/plans/2026-08-22-gamebox-material-3-ux-retrofit.md',
    'design_system/README.md',
    'app/test/design_system/derive_color_scheme_test.dart',
    'tool/test_design_tokens.dart',
    ...registry.map((entry) => entry.relativePath),
  };
  final numericPattern = RegExp(
    r'(?<![A-Za-z0-9_.])(\d+(?:\.\d+)?)\s*(dp|sp|ms)\b',
  );

  final registeredOccurrences = <String, String>{};
  for (final registration in registry) {
    final file = File('${repositoryRoot.path}/${registration.relativePath}');
    if (!file.existsSync()) {
      throw DesignTokenFormatException(
        registration.id,
        'registered normative claim file is missing: '
        '${registration.relativePath}.',
      );
    }
    final value = registration.tokenPath == null
        ? registration.fixedValue
        : _jsonPath(canonical, registration.tokenPath!);
    if (value is! num) {
      throw DesignTokenFormatException(
        registration.id,
        'registered value must resolve to a number.',
      );
    }
    final plainValue = _plainNumber(value);
    final expectedContext = registration.context.replaceAll(
      '{value}',
      plainValue,
    );
    final expectedLiteral = '$plainValue${registration.unit}';
    final literalOffset = expectedContext.indexOf(expectedLiteral);
    if (literalOffset < 0 ||
        expectedContext.indexOf(expectedLiteral, literalOffset + 1) >= 0) {
      throw DesignTokenFormatException(
        registration.id,
        'context must identify exactly one $expectedLiteral occurrence.',
      );
    }
    final contextMatches = <(int, int)>[];
    final lines = file.readAsLinesSync();
    for (var lineIndex = 0; lineIndex < lines.length; lineIndex += 1) {
      var start = 0;
      while (true) {
        final offset = lines[lineIndex].indexOf(expectedContext, start);
        if (offset < 0) {
          break;
        }
        contextMatches.add((lineIndex, offset));
        start = offset + expectedContext.length;
      }
    }
    if (contextMatches.length != 1) {
      throw DesignTokenFormatException(
        registration.id,
        contextMatches.isEmpty
            ? 'registered context is stale or missing.'
            : 'registered context is ambiguous.',
      );
    }
    final contextMatch = contextMatches.single;
    final occurrenceKey =
        '${registration.relativePath}|${contextMatch.$1}|'
        '${contextMatch.$2 + literalOffset}';
    final previous = registeredOccurrences[occurrenceKey];
    if (previous != null) {
      throw DesignTokenFormatException(
        registration.id,
        'numeric occurrence is already owned by $previous.',
      );
    }
    registeredOccurrences[occurrenceKey] = registration.id;
  }

  final seenOccurrences = <String>{};
  for (final relativePath in scanPaths.toList()..sort()) {
    final file = File('${repositoryRoot.path}/$relativePath');
    if (!file.existsSync()) {
      continue;
    }
    final lines = file.readAsLinesSync();
    for (var index = 0; index < lines.length; index += 1) {
      final line = lines[index];
      if (relativePath != 'design_system/README.md' &&
          _containsNumericMarkerText(line)) {
        throw DesignTokenFormatException(
          '$relativePath:${index + 1}',
          'numeric claim marker is only allowed in design_system/README.md.',
        );
      }
      for (final match in numericPattern.allMatches(line)) {
        final occurrenceKey = '$relativePath|$index|${match.start}';
        final registrationId = registeredOccurrences[occurrenceKey];
        if (registrationId == null) {
          throw DesignTokenFormatException(
            '$relativePath:${index + 1}',
            'unregistered numeric claim ${match.group(0)}.',
          );
        }
        seenOccurrences.add(occurrenceKey);
      }
    }
  }

  for (final entry in registeredOccurrences.entries) {
    if (!seenOccurrences.contains(entry.key)) {
      throw DesignTokenFormatException(
        entry.value,
        'registered numeric occurrence is not scan-visible.',
      );
    }
  }
}

List<_NumericClaim> _parseNumericClaimRegistry(List<String> lines) {
  final result = <_NumericClaim>[];
  final ids = <String>{};
  final pattern = RegExp(
    r'^\s*<!--\s+gamebox-numeric-(claim|exception)\s+(\{.*\})\s+-->\s*$',
  );
  for (final line in lines) {
    final match = pattern.firstMatch(line);
    if (match == null) {
      if (_containsNumericMarkerSyntax(line)) {
        throw const DesignTokenFormatException(
          'design_system/README.md',
          'malformed numeric claim marker.',
        );
      }
      continue;
    }
    final kind = match.group(1)!;
    final Object? decoded;
    try {
      decoded = jsonDecode(match.group(2)!);
    } on FormatException {
      throw const DesignTokenFormatException(
        'design_system/README.md',
        'malformed numeric claim marker JSON.',
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw const DesignTokenFormatException(
        'design_system/README.md',
        'numeric claim marker must contain a JSON object.',
      );
    }
    final id = _string(decoded['id'], 'numericClaim.id');
    final expectedKeys = kind == 'claim'
        ? const {'id', 'path', 'token', 'unit', 'context'}
        : const {'id', 'path', 'value', 'unit', 'context', 'reason'};
    _expectKeys('numericClaim.$id', decoded, expectedKeys);
    if (!ids.add(id)) {
      throw DesignTokenFormatException(id, 'numeric claim id is duplicated.');
    }
    final unit = _string(decoded['unit'], '$id.unit');
    if (!const {'dp', 'sp', 'ms'}.contains(unit)) {
      throw DesignTokenFormatException(id, 'unsupported numeric claim unit.');
    }
    final context = _string(decoded['context'], '$id.context');
    if (!context.contains('{value}')) {
      throw DesignTokenFormatException(
        id,
        'context must contain a {value} placeholder.',
      );
    }
    final fixedValue = decoded['value'];
    if (kind == 'exception' && fixedValue is! num) {
      throw DesignTokenFormatException(
        id,
        'numeric exception value must be a number.',
      );
    }
    final claim = _NumericClaim(
      id: id,
      relativePath: _string(decoded['path'], '$id.path'),
      unit: unit,
      context: context,
      tokenPath: kind == 'claim'
          ? _string(decoded['token'], '$id.token')
          : null,
      fixedValue: kind == 'exception' ? fixedValue! as num : null,
    );
    result.add(claim);
  }
  if (result.isEmpty) {
    throw const DesignTokenFormatException(
      'design_system/README.md',
      'numeric claim registry is empty.',
    );
  }
  return result;
}

bool _containsNumericMarkerText(String line) =>
    line.contains('gamebox-numeric-claim') ||
    line.contains('gamebox-numeric-exception');

bool _containsNumericMarkerSyntax(String line) =>
    RegExp(r'<!--\s*gamebox-numeric-(?:claim|exception)\b').hasMatch(line);

Object? _jsonPath(Map<String, Object?> root, String path) {
  Object? current = root;
  for (final segment in path.split('.')) {
    if (current is! Map || !current.containsKey(segment)) {
      throw DesignTokenFormatException(path, 'canonical JSON path is missing.');
    }
    current = current[segment];
  }
  return current;
}

String _relativePath(Directory root, File file) {
  final prefix = '${root.absolute.path}/';
  final absolute = file.absolute.path;
  if (!absolute.startsWith(prefix)) {
    throw DesignTokenFormatException(file.path, 'is outside the repository.');
  }
  return absolute.substring(prefix.length);
}

String _plainNumber(num value) {
  return value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toString();
}

final class _NumericClaim {
  const _NumericClaim({
    required this.id,
    required this.relativePath,
    required this.unit,
    required this.context,
    required this.tokenPath,
    required this.fixedValue,
  });

  final String id;
  final String relativePath;
  final String unit;
  final String context;
  final String? tokenPath;
  final num? fixedValue;
}
