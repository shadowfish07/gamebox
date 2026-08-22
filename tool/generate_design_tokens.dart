import 'dart:convert';
import 'dart:io';

import 'design_tokens.dart';

void main(List<String> arguments) {
  try {
    final options = _parseArguments(arguments);
    final inputFile = File(options['--input']!).absolute;
    final canonical = _readObject(inputFile);
    final schemaReference = canonical[r'$schema'];
    if (schemaReference is! String ||
        schemaReference.isEmpty ||
        Uri.parse(schemaReference).hasScheme) {
      throw const DesignTokenFormatException(
        r'$.$schema',
        'must be a non-empty repository-relative file reference.',
      );
    }
    final schemaFile = File.fromUri(inputFile.uri.resolve(schemaReference));
    final schema = _readObject(schemaFile);
    validateJsonSchema(schema, canonical);
    final document = DesignTokenDocument.fromJson(canonical);

    _write(File(options['--dart-output']!), renderDart(document));
    _write(File(options['--godot-output']!), renderGdscript(document));
  } on DesignTokenFormatException catch (error) {
    stderr.writeln('Design token validation failed: $error');
    exitCode = 65;
  } on FormatException catch (error) {
    stderr.writeln('Invalid JSON: $error');
    exitCode = 65;
  } on FileSystemException catch (error) {
    stderr.writeln('Design token I/O failed: $error');
    exitCode = 66;
  } on ArgumentError catch (error) {
    stderr.writeln(error.message);
    stderr.writeln(_usage);
    exitCode = 64;
  }
}

const _requiredOptions = {'--input', '--dart-output', '--godot-output'};

const _usage =
    'Usage: dart tool/generate_design_tokens.dart '
    '--input <tokens.json> --dart-output <tokens.g.dart> '
    '--godot-output <tokens.gd>';

Map<String, String> _parseArguments(List<String> arguments) {
  if (arguments.length.isOdd) {
    throw ArgumentError('Every option requires one value.');
  }
  final result = <String, String>{};
  for (var index = 0; index < arguments.length; index += 2) {
    final option = arguments[index];
    if (!_requiredOptions.contains(option)) {
      throw ArgumentError('Unsupported option: $option');
    }
    if (result.containsKey(option)) {
      throw ArgumentError('Duplicate option: $option');
    }
    final value = arguments[index + 1];
    if (value.isEmpty) {
      throw ArgumentError('Option $option requires a non-empty value.');
    }
    result[option] = value;
  }
  for (final option in _requiredOptions) {
    if (!result.containsKey(option)) {
      throw ArgumentError('Missing required option: $option');
    }
  }
  return result;
}

Map<String, Object?> _readObject(File file) {
  final decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map<String, Object?>) {
    throw DesignTokenFormatException(file.path, 'must contain a JSON object.');
  }
  return decoded;
}

void _write(File file, String contents) {
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
}
