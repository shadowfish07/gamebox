import 'dart:convert';
import 'dart:typed_data';

const _maximumJsonDepth = 32;
const _maximumContainerEntries = 4096;
const _maximumKeyCodeUnits = 64;
const _maximumStringRunes = 64 * 1024;
const _maximumSafeInteger = 9007199254740991;

/// Decodes the deliberately small JSON profile used by Gamebox.
///
/// Validation happens before [jsonDecode] so duplicate or escaped object keys
/// cannot be normalized away by the standard decoder.
Map<String, Object?> decodeStrictJsonObject(Uint8List bytes) {
  final source = utf8.decode(bytes, allowMalformed: false);
  _StrictJsonScanner(source).scanObjectDocument();
  final decoded = jsonDecode(source);
  if (decoded is! Map<String, Object?>) {
    throw const FormatException('Expected JSON object');
  }
  return Map<String, Object?>.unmodifiable(decoded);
}

bool hasExactJsonKeys(Map<String, Object?> object, Set<String> expected) {
  return object.length == expected.length &&
      object.keys.every(expected.contains);
}

final class _StrictJsonScanner {
  _StrictJsonScanner(this._source);

  final String _source;
  var _index = 0;

  void scanObjectDocument() {
    _skipWhitespace();
    if (_peek() != 0x7b) {
      throw const FormatException('Expected JSON object');
    }
    _parseValue(0);
    _skipWhitespace();
    if (_index != _source.length) {
      throw const FormatException('Trailing JSON data');
    }
  }

  void _parseValue(int depth) {
    _skipWhitespace();
    switch (_peek()) {
      case 0x7b:
        _parseObject(depth + 1);
      case 0x5b:
        _parseArray(depth + 1);
      case 0x22:
        _parseString(isKey: false);
      case 0x74:
        _consumeLiteral('true');
      case 0x66:
        _consumeLiteral('false');
      case 0x6e:
        _consumeLiteral('null');
      case 0x2d:
      case >= 0x30 && <= 0x39:
        _parseNumber();
      default:
        throw const FormatException('Invalid JSON value');
    }
  }

  void _parseObject(int depth) {
    _checkDepth(depth);
    _expect(0x7b);
    _skipWhitespace();
    if (_consumeIf(0x7d)) {
      return;
    }
    final keys = <String>{};
    var entries = 0;
    while (true) {
      entries += 1;
      if (entries > _maximumContainerEntries) {
        throw const FormatException('Too many JSON object entries');
      }
      _skipWhitespace();
      final key = _parseString(isKey: true);
      if (key.length > _maximumKeyCodeUnits ||
          !RegExp(r'^[A-Za-z][A-Za-z0-9]*$').hasMatch(key) ||
          !keys.add(key)) {
        throw const FormatException('Invalid JSON object key');
      }
      _skipWhitespace();
      _expect(0x3a);
      _parseValue(depth);
      _skipWhitespace();
      if (_consumeIf(0x7d)) {
        return;
      }
      _expect(0x2c);
    }
  }

  void _parseArray(int depth) {
    _checkDepth(depth);
    _expect(0x5b);
    _skipWhitespace();
    if (_consumeIf(0x5d)) {
      return;
    }
    var entries = 0;
    while (true) {
      entries += 1;
      if (entries > _maximumContainerEntries) {
        throw const FormatException('Too many JSON array entries');
      }
      _parseValue(depth);
      _skipWhitespace();
      if (_consumeIf(0x5d)) {
        return;
      }
      _expect(0x2c);
    }
  }

  String _parseString({required bool isKey}) {
    _expect(0x22);
    final key = isKey ? StringBuffer() : null;
    var runes = 0;
    while (_index < _source.length) {
      final unit = _source.codeUnitAt(_index++);
      if (unit == 0x22) {
        return key?.toString() ?? '';
      }
      if (unit < 0x20) {
        throw const FormatException('Control character in JSON string');
      }
      if (unit == 0x5c) {
        if (isKey) {
          throw const FormatException('Escaped JSON keys are not canonical');
        }
        _parseEscape();
        runes += 1;
      } else if (_isHighSurrogate(unit)) {
        if (_index >= _source.length ||
            !_isLowSurrogate(_source.codeUnitAt(_index))) {
          throw const FormatException('Unpaired JSON surrogate');
        }
        if (isKey) {
          key!.writeCharCode(unit);
          key.writeCharCode(_source.codeUnitAt(_index));
        }
        _index += 1;
        runes += 1;
      } else if (_isLowSurrogate(unit)) {
        throw const FormatException('Unpaired JSON surrogate');
      } else {
        key?.writeCharCode(unit);
        runes += 1;
      }
      if (runes > _maximumStringRunes) {
        throw const FormatException('JSON string too long');
      }
      if (isKey && runes > _maximumKeyCodeUnits) {
        throw const FormatException('JSON object key too long');
      }
    }
    throw const FormatException('Unterminated JSON string');
  }

  void _parseEscape() {
    if (_index >= _source.length) {
      throw const FormatException('Incomplete JSON escape');
    }
    final escaped = _source.codeUnitAt(_index++);
    if (escaped == 0x75) {
      final first = _readHexQuad();
      if (_isHighSurrogate(first)) {
        if (_index + 2 > _source.length ||
            _source.codeUnitAt(_index) != 0x5c ||
            _source.codeUnitAt(_index + 1) != 0x75) {
          throw const FormatException('Unpaired JSON surrogate escape');
        }
        _index += 2;
        final second = _readHexQuad();
        if (!_isLowSurrogate(second)) {
          throw const FormatException('Unpaired JSON surrogate escape');
        }
      } else if (_isLowSurrogate(first)) {
        throw const FormatException('Unpaired JSON surrogate escape');
      }
      return;
    }
    if (escaped != 0x22 &&
        escaped != 0x5c &&
        escaped != 0x2f &&
        escaped != 0x62 &&
        escaped != 0x66 &&
        escaped != 0x6e &&
        escaped != 0x72 &&
        escaped != 0x74) {
      throw const FormatException('Invalid JSON escape');
    }
  }

  int _readHexQuad() {
    if (_index + 4 > _source.length) {
      throw const FormatException('Incomplete Unicode escape');
    }
    var value = 0;
    for (var offset = 0; offset < 4; offset += 1) {
      final digit = _hexValue(_source.codeUnitAt(_index + offset));
      if (digit < 0) {
        throw const FormatException('Invalid Unicode escape');
      }
      value = value * 16 + digit;
    }
    _index += 4;
    return value;
  }

  void _parseNumber() {
    final start = _index;
    _consumeIf(0x2d);
    if (_consumeIf(0x30)) {
      if (_isDigit(_peek())) {
        throw const FormatException('Leading zero in JSON number');
      }
    } else {
      final first = _peek();
      if (first < 0x31 || first > 0x39) {
        throw const FormatException('Invalid JSON number');
      }
      _index += 1;
      while (_isDigit(_peek())) {
        _index += 1;
      }
    }
    var isDouble = false;
    if (_consumeIf(0x2e)) {
      isDouble = true;
      if (!_isDigit(_peek())) {
        throw const FormatException('Invalid JSON number');
      }
      while (_isDigit(_peek())) {
        _index += 1;
      }
    }
    if (_consumeIf(0x45) || _consumeIf(0x65)) {
      isDouble = true;
      if (_peek() == 0x2b || _peek() == 0x2d) {
        _index += 1;
      }
      if (!_isDigit(_peek())) {
        throw const FormatException('Invalid JSON number');
      }
      while (_isDigit(_peek())) {
        _index += 1;
      }
    }
    final number = _source.substring(start, _index);
    if (isDouble) {
      final parsed = double.tryParse(number);
      if (parsed == null || !parsed.isFinite) {
        throw const FormatException('Invalid JSON number');
      }
      return;
    }
    if (_index - start > 17) {
      throw const FormatException('Unsafe JSON integer');
    }
    final parsed = BigInt.parse(number);
    if (parsed.abs() > BigInt.from(_maximumSafeInteger)) {
      throw const FormatException('Unsafe JSON integer');
    }
  }

  void _consumeLiteral(String literal) {
    if (!_source.startsWith(literal, _index)) {
      throw const FormatException('Invalid JSON literal');
    }
    _index += literal.length;
  }

  void _checkDepth(int depth) {
    if (depth > _maximumJsonDepth) {
      throw const FormatException('JSON nesting too deep');
    }
  }

  void _skipWhitespace() {
    while (_index < _source.length) {
      final unit = _source.codeUnitAt(_index);
      if (unit != 0x20 && unit != 0x09 && unit != 0x0a && unit != 0x0d) {
        return;
      }
      _index += 1;
    }
  }

  int _peek() => _index < _source.length ? _source.codeUnitAt(_index) : -1;

  void _expect(int unit) {
    if (!_consumeIf(unit)) {
      throw const FormatException('Unexpected JSON token');
    }
  }

  bool _consumeIf(int unit) {
    if (_peek() != unit) {
      return false;
    }
    _index += 1;
    return true;
  }

  static bool _isDigit(int unit) => unit >= 0x30 && unit <= 0x39;
  static bool _isHighSurrogate(int unit) => unit >= 0xd800 && unit <= 0xdbff;
  static bool _isLowSurrogate(int unit) => unit >= 0xdc00 && unit <= 0xdfff;

  static int _hexValue(int unit) {
    if (unit >= 0x30 && unit <= 0x39) return unit - 0x30;
    if (unit >= 0x41 && unit <= 0x46) return unit - 0x41 + 10;
    if (unit >= 0x61 && unit <= 0x66) return unit - 0x61 + 10;
    return -1;
  }
}
