import 'package:flutter/services.dart';

import '../lan/lan_models.dart';
import 'lan_host_platform.dart';

final class MethodChannelLanHostPlatform implements LanHostPlatform {
  MethodChannelLanHostPlatform({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('me.zqydev.gamebox/lan_host');

  final MethodChannel _channel;

  @override
  Future<LanHostStatus> getStatus() => _status('getStatus');

  @override
  Future<LanHostStatus> refreshEndpoint() => _status('refreshEndpoint');

  @override
  Future<LanHostStatus> closeRoom(String mode) {
    if (!const {'cancel', 'resign', 'discard_corrupt'}.contains(mode)) {
      throw ArgumentError.value(mode, 'mode');
    }
    return _status('closeRoom', {'mode': mode});
  }

  @override
  Future<LanHostStatus> stopCompletedRoom({
    required bool allowMissingGuestAck,
  }) => _status('stopCompletedRoom', {
    'allowMissingGuestAck': allowMissingGuestAck,
  });

  @override
  Future<LanHostCreation> createRoom(String nickname) async {
    if (nickname.trim().isEmpty) {
      throw ArgumentError.value(nickname, 'nickname');
    }
    final value = await _invoke('createRoom', {'nickname': nickname});
    if (!_exact(value, _statusFields.union({'roomKey', 'joinExpiresAt'})) ||
        value['roomKey'] is! String ||
        value['joinExpiresAt'] is! int ||
        !isCanonicalLanCredential(value['roomKey']! as String)) {
      throw const LanHostException('invalid_response');
    }
    final status = _decodeStatus(
      value,
      allowExtra: const {'roomKey', 'joinExpiresAt'},
    );
    final expires = value['joinExpiresAt']! as int;
    if (status.state != LanNativeState.waiting || expires <= 0) {
      throw const LanHostException('invalid_response');
    }
    return LanHostCreation(
      status: status,
      roomKey: value['roomKey']! as String,
      joinExpiresAt: DateTime.fromMillisecondsSinceEpoch(expires, isUtc: true),
    );
  }

  @override
  Future<LanHostLaunch> issueHostLaunch() async {
    final value = await _invoke('issueHostLaunch', null);
    const fields = {
      'schemaVersion',
      'matchId',
      'gameId',
      'playerId',
      'launchTicket',
      'resumeToken',
      'wsUrl',
      'expiresAt',
    };
    if (!_exact(value, fields) ||
        value['schemaVersion'] != 1 ||
        value['matchId'] is! String ||
        value['gameId'] != 'gomoku' ||
        value['playerId'] is! String ||
        value['launchTicket'] is! String ||
        value['resumeToken'] is! String ||
        value['wsUrl'] is! String ||
        value['expiresAt'] is! int ||
        !isCanonicalLanUuid(value['matchId']! as String) ||
        !isCanonicalLanUuid(value['playerId']! as String) ||
        !isCanonicalLanCredential(value['launchTicket']! as String) ||
        !isCanonicalLanCredential(value['resumeToken']! as String)) {
      throw const LanHostException('invalid_response');
    }
    final ws = Uri.tryParse(value['wsUrl']! as String);
    if (ws == null ||
        ws.scheme != 'ws' ||
        ws.host != '127.0.0.1' ||
        ws.port < 1 ||
        ws.port > 65535 ||
        ws.path != '/lan/v1/ws' ||
        ws.userInfo.isNotEmpty ||
        ws.hasQuery ||
        ws.hasFragment) {
      throw const LanHostException('invalid_response');
    }
    return LanHostLaunch(
      matchId: value['matchId']! as String,
      gameId: 'gomoku',
      playerId: value['playerId']! as String,
      launchTicket: value['launchTicket']! as String,
      resumeToken: value['resumeToken']! as String,
      wsUrl: ws.toString(),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        value['expiresAt']! as int,
        isUtc: true,
      ),
    );
  }

  Future<LanHostStatus> _status(String method, [Object? arguments]) async =>
      _decodeStatus(await _invoke(method, arguments));

  Future<Map<String, Object?>> _invoke(String method, Object? arguments) async {
    try {
      final raw = await _channel.invokeMethod<Object?>(method, arguments);
      if (raw is! Map<Object?, Object?> ||
          raw.keys.any((key) => key is! String)) {
        throw const LanHostException('invalid_response');
      }
      return Map<String, Object?>.unmodifiable(raw.cast<String, Object?>());
    } on LanHostException {
      rethrow;
    } on PlatformException catch (error) {
      throw LanHostException(error.code);
    } on MissingPluginException {
      throw const LanHostException('missing_plugin');
    } on Object {
      throw const LanHostException('invalid_response');
    }
  }

  static LanHostStatus _decodeStatus(
    Map<String, Object?> value, {
    Set<String> allowExtra = const {},
  }) {
    if (!_exact(value, _statusFields.union(allowExtra)) ||
        value['schemaVersion'] != 1 ||
        value['state'] is! String ||
        value['port'] is! int ||
        value['gameRevision'] is! int ||
        value['endpointChanged'] is! bool ||
        value['roomId'] is! String? ||
        value['endpoint'] is! String?) {
      throw const LanHostException('invalid_response');
    }
    final state = LanNativeState.values
        .where((item) => item.name == value['state'])
        .firstOrNull;
    final roomId = value['roomId'] as String?;
    final port = value['port']! as int;
    final revision = value['gameRevision']! as int;
    final endpointRaw = value['endpoint'] as String?;
    if (state == null ||
        revision < 0 ||
        revision > 9007199254740991 ||
        roomId != null && !isCanonicalLanUuid(roomId)) {
      throw const LanHostException('invalid_response');
    }
    LanEndpoint? endpoint;
    try {
      endpoint = endpointRaw == null ? null : LanEndpoint.parse(endpointRaw);
    } on FormatException {
      throw const LanHostException('invalid_response');
    }
    if (state == LanNativeState.empty &&
            (roomId != null ||
                port != 0 ||
                revision != 0 ||
                endpoint != null) ||
        state == LanNativeState.corrupt &&
            (roomId == null ||
                port != 0 ||
                revision != 0 ||
                endpoint != null) ||
        state != LanNativeState.empty &&
            state != LanNativeState.corrupt &&
            (roomId == null || port < 49152 || endpoint?.port != port)) {
      throw const LanHostException('invalid_response');
    }
    return LanHostStatus(
      state: state,
      roomId: roomId,
      port: port,
      gameRevision: revision,
      endpointChanged: value['endpointChanged']! as bool,
      endpoint: endpoint,
    );
  }

  static bool _exact(Map<String, Object?> value, Set<String> keys) =>
      value.length == keys.length && value.keys.every(keys.contains);

  static const _statusFields = {
    'schemaVersion',
    'state',
    'roomId',
    'port',
    'gameRevision',
    'endpointChanged',
    'endpoint',
  };
}
