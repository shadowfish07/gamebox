// ignore_for_file: prefer_initializing_formals

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../api/strict_json.dart';
import 'lan_models.dart';

abstract interface class LanKeyValueStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

final class FlutterLanKeyValueStorage implements LanKeyValueStorage {
  FlutterLanKeyValueStorage({
    FlutterSecureStorage storage = const FlutterSecureStorage(
      aOptions: AndroidOptions(resetOnError: false),
    ),
  }) : _storage = storage;

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

final class LanCredentialStore {
  LanCredentialStore({LanKeyValueStorage? storage, Random? random})
    : _storage = storage ?? FlutterLanKeyValueStorage(),
      _random = random ?? Random.secure();

  static const keyPrefix = 'gamebox_lan_room_v1_';
  final LanKeyValueStorage _storage;
  final Random _random;

  Future<LanJoinCandidate> createCandidate(
    String roomId,
    LanEndpoint endpoint,
  ) async {
    if (!isCanonicalLanUuid(roomId)) throw ArgumentError('Invalid room ID');
    final candidate = LanJoinCandidate(
      roomId: roomId,
      joinAttemptId: _uuid(),
      candidateResumeToken: _credential(),
      endpoint: endpoint,
    );
    await _writeCandidate(candidate);
    return candidate;
  }

  Future<LanJoinCandidate?> readCandidate(String roomId) async {
    final value = await _read(roomId);
    if (value == null || value['kind'] != 'candidate') return null;
    return LanJoinCandidate(
      roomId: _uuidField(value, 'roomId'),
      joinAttemptId: _uuidField(value, 'joinAttemptId'),
      candidateResumeToken: _credentialField(value, 'token'),
      endpoint: LanEndpoint.parse(_stringField(value, 'endpoint')),
    );
  }

  Future<LanCredential?> readCredential(String roomId) async {
    final value = await _read(roomId);
    if (value == null || value['kind'] != 'credential') return null;
    return LanCredential(
      roomId: _uuidField(value, 'roomId'),
      playerId: _uuidField(value, 'playerId'),
      joinAttemptId: _uuidField(value, 'joinAttemptId'),
      resumeToken: _credentialField(value, 'token'),
      endpoint: LanEndpoint.parse(_stringField(value, 'endpoint')),
    );
  }

  Future<void> commit(LanJoinCandidate candidate, String playerId) async {
    if (!isCanonicalLanUuid(playerId)) throw ArgumentError('Invalid player ID');
    await _storage.write(
      _key(candidate.roomId),
      jsonEncode({
        'schemaVersion': 1,
        'kind': 'credential',
        'roomId': candidate.roomId,
        'playerId': playerId,
        'joinAttemptId': candidate.joinAttemptId,
        'token': candidate.candidateResumeToken,
        'endpoint': candidate.endpoint.encoded,
      }),
    );
  }

  Future<void> updateEndpoint(LanCredential credential, LanEndpoint endpoint) {
    return _storage.write(
      _key(credential.roomId),
      jsonEncode({
        'schemaVersion': 1,
        'kind': 'credential',
        'roomId': credential.roomId,
        'playerId': credential.playerId,
        'joinAttemptId': credential.joinAttemptId,
        'token': credential.resumeToken,
        'endpoint': endpoint.encoded,
      }),
    );
  }

  Future<void> delete(String roomId) => _storage.delete(_key(roomId));

  Future<void> _writeCandidate(LanJoinCandidate candidate) {
    return _storage.write(
      _key(candidate.roomId),
      jsonEncode({
        'schemaVersion': 1,
        'kind': 'candidate',
        'roomId': candidate.roomId,
        'joinAttemptId': candidate.joinAttemptId,
        'token': candidate.candidateResumeToken,
        'endpoint': candidate.endpoint.encoded,
      }),
    );
  }

  Future<Map<String, Object?>?> _read(String roomId) async {
    if (!isCanonicalLanUuid(roomId)) throw ArgumentError('Invalid room ID');
    final encoded = await _storage.read(_key(roomId));
    if (encoded == null) return null;
    try {
      final bytes = utf8.encode(encoded);
      if (bytes.isEmpty || bytes.length > 64 * 1024) {
        throw const FormatException();
      }
      final object = decodeStrictJsonObject(Uint8List.fromList(bytes));
      final kind = object['kind'];
      final expected = kind == 'credential'
          ? const {
              'schemaVersion',
              'kind',
              'roomId',
              'playerId',
              'joinAttemptId',
              'token',
              'endpoint',
            }
          : const {
              'schemaVersion',
              'kind',
              'roomId',
              'joinAttemptId',
              'token',
              'endpoint',
            };
      if (object['schemaVersion'] != 1 ||
          !hasExactJsonKeys(object, expected) ||
          object['roomId'] != roomId) {
        throw const FormatException();
      }
      return object;
    } on Object {
      throw const LanException('credential_corrupt');
    }
  }

  String _credential() => base64Url
      .encode(List<int>.generate(32, (_) => _random.nextInt(256)))
      .replaceAll('=', '');

  String _uuid() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  static String _key(String roomId) => '$keyPrefix$roomId';
  static String _stringField(Map<String, Object?> value, String key) {
    final field = value[key];
    if (field is! String || field.isEmpty) {
      throw const LanException('credential_corrupt');
    }
    return field;
  }

  static String _uuidField(Map<String, Object?> value, String key) {
    final field = _stringField(value, key);
    if (!isCanonicalLanUuid(field)) {
      throw const LanException('credential_corrupt');
    }
    return field;
  }

  static String _credentialField(Map<String, Object?> value, String key) {
    final field = _stringField(value, key);
    if (!isCanonicalLanCredential(field)) {
      throw const LanException('credential_corrupt');
    }
    return field;
  }
}
