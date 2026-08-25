import 'dart:convert';

import 'package:flutter/services.dart';

import '../lan/lan_models.dart';
import 'game_results_platform.dart';

final class MethodChannelGameResultsPlatform implements GameResultsPlatform {
  MethodChannelGameResultsPlatform({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = 'me.zqydev.gamebox/game_results';
  final MethodChannel _channel;

  @override
  Future<List<CommittedGameResult>> listCommitted() async {
    final values = await _channel.invokeListMethod<Object?>('listCommitted');
    return (values ?? const <Object?>[])
        .map((raw) {
          if (raw is! Map<Object?, Object?> || raw.length != 2) {
            throw const FormatException('invalid_committed_result');
          }
          final value = raw['result'];
          final sha256 = raw['sha256'];
          if (value is! String ||
              sha256 is! String ||
              !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) {
            throw const FormatException('invalid_committed_result');
          }
          return CommittedGameResult(
            result: AuthoritativeGameResult.fromJsonBytes(utf8.encode(value)),
            sha256: sha256,
          );
        })
        .toList(growable: false);
  }

  @override
  Future<List<PendingGameResultRecord>> listPending() async {
    final values = await _channel.invokeListMethod<Object?>('listPending');
    return (values ?? const <Object?>[])
        .map((raw) {
          if (raw is! Map<Object?, Object?> || raw.length != 5) {
            throw const FormatException('invalid_pending_result');
          }
          final matchId = raw['matchId'];
          final gameId = raw['gameId'];
          final source = raw['source'];
          final endpointKind = raw['endpointKind'];
          final localUserId = raw['localUserId'];
          if (matchId is! String ||
              gameId is! String ||
              source is! String ||
              endpointKind is! String ||
              localUserId is! String?) {
            throw const FormatException('invalid_pending_result');
          }
          return PendingGameResultRecord(
            matchId: matchId,
            gameId: gameId,
            source: source,
            endpointKind: endpointKind,
            localUserId: localUserId,
          );
        })
        .toList(growable: false);
  }

  @override
  Future<String> persistRecovered(AuthoritativeGameResult result) async {
    final value = await _channel.invokeMethod<String>('persistRecovered', {
      'result': result.encode(),
    });
    if (value == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
      throw const FormatException('invalid_result_hash');
    }
    return value;
  }

  @override
  Future<void> completePending(String matchId, String expectedSha256) =>
      _channel.invokeMethod<void>('completePending', {
        'matchId': matchId,
        'expectedSha256': expectedSha256,
      });

  @override
  Future<bool> quarantine(String matchId) async =>
      await _channel.invokeMethod<bool>('quarantine', {'matchId': matchId}) ??
      false;
}
