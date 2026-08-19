import '../api/strict_json.dart';

/// A public, non-secret user identity carried by an authenticated session.
final class SessionUser {
  const SessionUser({required this.id, required this.nickname});

  final String id;
  final String nickname;

  @override
  String toString() => 'SessionUser(id: $id, nickname: $nickname)';
}

/// One server-issued, rotating authentication session.
final class Session {
  Session({
    required this.user,
    required this.accessToken,
    required this.accessExpiresAt,
    required this.refreshToken,
    required this.refreshExpiresAt,
  }) {
    if (!_isCanonicalUuid(user.id) ||
        !_isValidNickname(user.nickname) ||
        !_isCredential(accessToken) ||
        !_isCredential(refreshToken) ||
        !accessExpiresAt.isBefore(refreshExpiresAt)) {
      throw ArgumentError('Invalid session');
    }
  }

  factory Session.fromEnvelope(Map<String, Object?> envelope) {
    if (!hasExactJsonKeys(envelope, const {'session'})) {
      throw const FormatException('Invalid session response');
    }
    final session = _object(envelope['session']);
    if (!hasExactJsonKeys(session, const {
      'user',
      'accessToken',
      'accessExpiresAt',
      'refreshToken',
      'refreshExpiresAt',
    })) {
      throw const FormatException('Invalid session response');
    }
    final user = _object(session['user']);
    if (!hasExactJsonKeys(user, const {'id', 'nickname'})) {
      throw const FormatException('Invalid session response');
    }
    final userId = _string(user['id']);
    final nickname = _string(user['nickname']);
    final accessToken = _string(session['accessToken']);
    final refreshToken = _string(session['refreshToken']);
    final accessExpiresAt = _timestamp(session['accessExpiresAt']);
    final refreshExpiresAt = _timestamp(session['refreshExpiresAt']);
    try {
      return Session(
        user: SessionUser(id: userId, nickname: nickname),
        accessToken: accessToken,
        accessExpiresAt: accessExpiresAt,
        refreshToken: refreshToken,
        refreshExpiresAt: refreshExpiresAt,
      );
    } on ArgumentError {
      throw const FormatException('Invalid session response');
    }
  }

  final SessionUser user;
  final String accessToken;
  final DateTime accessExpiresAt;
  final String refreshToken;
  final DateTime refreshExpiresAt;

  @override
  String toString() {
    return 'Session(user: $user, credentials: <redacted>, '
        'accessExpiresAt: $accessExpiresAt, '
        'refreshExpiresAt: $refreshExpiresAt)';
  }

  static final RegExp _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );

  static bool _isCanonicalUuid(String value) {
    return value != '00000000-0000-0000-0000-000000000000' &&
        _uuid.hasMatch(value);
  }

  static bool _isValidNickname(String value) {
    final runeCount = value.runes.length;
    return value == value.trim() &&
        runeCount >= 2 &&
        runeCount <= 16 &&
        !value.runes.any((rune) => rune < 0x20 || rune == 0x7f);
  }

  static bool _isCredential(String value) {
    return value.isNotEmpty &&
        value.length <= 4096 &&
        value.codeUnits.every((unit) => unit >= 0x21 && unit <= 0x7e);
  }

  static Map<String, Object?> _object(Object? value) {
    if (value is! Map<String, Object?>) {
      throw const FormatException('Invalid session response');
    }
    return value;
  }

  static String _string(Object? value) {
    if (value is! String) {
      throw const FormatException('Invalid session response');
    }
    return value;
  }

  static DateTime _timestamp(Object? value) {
    if (value is! int || value <= 0) {
      throw const FormatException('Invalid session response');
    }
    try {
      return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
    } on RangeError {
      throw const FormatException('Invalid session response');
    }
  }
}
