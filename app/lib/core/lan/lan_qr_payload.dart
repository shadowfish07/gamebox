import 'lan_models.dart';
import 'private_ipv4.dart';

sealed class LanQrPayload {
  const LanQrPayload(this.roomId, this.endpoint);

  final String roomId;
  final LanEndpoint endpoint;

  String encode();

  static LanQrPayload parse(String raw, DateTime now) {
    if (raw.length > 2048 ||
        raw.codeUnits.any((unit) => unit <= 0x20 || unit == 0x7f)) {
      throw const LanException('invalid_qr');
    }
    final Uri uri;
    try {
      uri = Uri.parse(raw);
    } on FormatException {
      throw const LanException('invalid_qr');
    }
    if (uri.scheme != 'gamebox-lan' ||
        uri.userInfo.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        uri.path.isNotEmpty ||
        uri.port != 0) {
      throw const LanException('invalid_qr');
    }
    final pairs = <MapEntry<String, String>>[];
    for (final pair in uri.query.split('&')) {
      if (pair.isEmpty || !pair.contains('=')) {
        throw const LanException('invalid_qr');
      }
      final index = pair.indexOf('=');
      final key = Uri.decodeQueryComponent(pair.substring(0, index));
      final value = Uri.decodeQueryComponent(pair.substring(index + 1));
      if (pairs.any((item) => item.key == key)) {
        throw const LanException('invalid_qr');
      }
      pairs.add(MapEntry(key, value));
    }
    final query = Map<String, String>.fromEntries(pairs);
    if (uri.host == 'join') return LanJoinQr._parse(query, now);
    if (uri.host == 'resume') return LanResumeQr._parse(query);
    throw const LanException('invalid_qr');
  }
}

final class LanJoinQr extends LanQrPayload {
  const LanJoinQr._({
    required String roomId,
    required LanEndpoint endpoint,
    required this.roomKey,
    required this.expiresAt,
  }) : super(roomId, endpoint);

  factory LanJoinQr({
    required String roomId,
    required LanEndpoint endpoint,
    required String roomKey,
    required DateTime expiresAt,
  }) {
    if (!isCanonicalLanUuid(roomId) ||
        !isCanonicalLanCredential(roomKey) ||
        expiresAt.toUtc().millisecondsSinceEpoch <= 0) {
      throw ArgumentError('Invalid join QR');
    }
    return LanJoinQr._(
      roomId: roomId,
      endpoint: endpoint,
      roomKey: roomKey,
      expiresAt: expiresAt.toUtc(),
    );
  }

  final String roomKey;
  final DateTime expiresAt;

  static LanJoinQr _parse(Map<String, String> query, DateTime now) {
    if (!_sameKeys(query, const {'v', 'room', 'host', 'port', 'key', 'exp'}) ||
        query['v'] != '1' ||
        !isCanonicalLanUuid(query['room'] ?? '') ||
        !isCanonicalLanCredential(query['key'] ?? '') ||
        !_canonicalInt(query['port'] ?? '', min: 1, max: 65535) ||
        !_canonicalInt(query['exp'] ?? '', min: 1, max: 9007199254740991)) {
      throw const LanException('invalid_qr');
    }
    try {
      final expiresAt = DateTime.fromMillisecondsSinceEpoch(
        int.parse(query['exp']!),
        isUtc: true,
      );
      if (!expiresAt.isAfter(now.toUtc())) {
        throw const LanException('join_expired');
      }
      return LanJoinQr._(
        roomId: query['room']!,
        endpoint: LanEndpoint(
          host: PrivateIpv4.parse(query['host']!),
          port: int.parse(query['port']!),
        ),
        roomKey: query['key']!,
        expiresAt: expiresAt,
      );
    } on LanException {
      rethrow;
    } on Object {
      throw const LanException('invalid_qr');
    }
  }

  @override
  String encode() => Uri(
    scheme: 'gamebox-lan',
    host: 'join',
    queryParameters: <String, String>{
      'v': '1',
      'room': roomId,
      'host': endpoint.host.address,
      'port': '${endpoint.port}',
      'key': roomKey,
      'exp': '${expiresAt.millisecondsSinceEpoch}',
    },
  ).toString();

  @override
  String toString() => 'LanJoinQr(roomId: $roomId, key: <redacted>)';
}

final class LanResumeQr extends LanQrPayload {
  const LanResumeQr._({required String roomId, required LanEndpoint endpoint})
    : super(roomId, endpoint);

  factory LanResumeQr({required String roomId, required LanEndpoint endpoint}) {
    if (!isCanonicalLanUuid(roomId)) throw ArgumentError('Invalid recovery QR');
    return LanResumeQr._(roomId: roomId, endpoint: endpoint);
  }

  static LanResumeQr _parse(Map<String, String> query) {
    if (!_sameKeys(query, const {'v', 'room', 'host', 'port'}) ||
        query['v'] != '1' ||
        !isCanonicalLanUuid(query['room'] ?? '') ||
        !_canonicalInt(query['port'] ?? '', min: 1, max: 65535)) {
      throw const LanException('invalid_qr');
    }
    try {
      return LanResumeQr._(
        roomId: query['room']!,
        endpoint: LanEndpoint(
          host: PrivateIpv4.parse(query['host']!),
          port: int.parse(query['port']!),
        ),
      );
    } on Object {
      throw const LanException('invalid_qr');
    }
  }

  @override
  String encode() => Uri(
    scheme: 'gamebox-lan',
    host: 'resume',
    queryParameters: <String, String>{
      'v': '1',
      'room': roomId,
      'host': endpoint.host.address,
      'port': '${endpoint.port}',
    },
  ).toString();
}

bool _sameKeys(Map<String, String> value, Set<String> expected) =>
    value.length == expected.length && value.keys.every(expected.contains);

bool _canonicalInt(String value, {required int min, required int max}) {
  if (!RegExp(r'^[1-9][0-9]*$').hasMatch(value)) return false;
  final parsed = int.tryParse(value);
  return parsed != null && parsed >= min && parsed <= max;
}
