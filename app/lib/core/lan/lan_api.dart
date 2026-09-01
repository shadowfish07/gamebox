import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../api/network_failure.dart';
import '../api/strict_json.dart';
import 'lan_models.dart';
import 'lan_qr_payload.dart';

final class LanApi {
  LanApi({http.Client? client, this.timeout = const Duration(seconds: 8)})
    : _client = client ?? http.Client() {
    if (timeout <= Duration.zero) throw ArgumentError.value(timeout, 'timeout');
  }

  static const _maximumResponseBytes = 512 * 1024;
  final http.Client _client;
  final Duration timeout;

  Future<LanJoinReceipt> join(
    LanJoinQr qr,
    LanJoinCandidate candidate,
    String nickname,
  ) async {
    if (candidate.roomId != qr.roomId ||
        candidate.endpoint != qr.endpoint ||
        nickname.trim().isEmpty) {
      throw const LanException('invalid_request');
    }
    final object = await _request(
      qr.endpoint.resolve('/lan/v1/rooms/${qr.roomId}/join'),
      'POST',
      {
        'roomId': qr.roomId,
        'nickname': nickname,
        'joinAttemptId': candidate.joinAttemptId,
        'candidateResumeToken': candidate.candidateResumeToken,
        'roomKey': qr.roomKey,
      },
    );
    return _launchReceipt(
      object,
      qr.roomId,
      resumeToken: candidate.candidateResumeToken,
    );
  }

  Future<LanLaunchReceipt> resumeTicket(
    LanResumeQr qr,
    LanCredential credential,
  ) async {
    if (credential.roomId != qr.roomId) {
      throw const LanException('credential_mismatch');
    }
    final object = await _request(
      qr.endpoint.resolve('/lan/v1/rooms/${qr.roomId}/resume-ticket'),
      'POST',
      {
        'roomId': qr.roomId,
        'playerId': credential.playerId,
        'resumeToken': credential.resumeToken,
      },
    );
    return _launchReceipt(
      object,
      qr.roomId,
      resumeToken: credential.resumeToken,
    );
  }

  Future<({String resultHash, AuthoritativeGameResult result})> fetchResult(
    LanEndpoint endpoint,
    LanCredential credential,
  ) async {
    final object = await _request(
      endpoint.resolve('/lan/v1/rooms/${credential.roomId}/result'),
      'GET',
      {'resumeToken': credential.resumeToken},
    );
    if (!hasExactJsonKeys(object, const {
          'schemaVersion',
          'resultHash',
          'result',
        }) ||
        object['schemaVersion'] != 1 ||
        object['resultHash'] is! String ||
        object['result'] is! Map<String, Object?>) {
      throw const LanException('invalid_response');
    }
    final hash = object['resultHash']! as String;
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
      throw const LanException('invalid_response');
    }
    try {
      final result = AuthoritativeGameResult.fromObject(
        object['result']! as Map<String, Object?>,
      );
      if (result.matchId != credential.roomId) {
        throw const FormatException();
      }
      return (resultHash: hash, result: result);
    } on FormatException {
      throw const LanException('invalid_response');
    } catch (error) {
      if (isNetworkFailure(error)) {
        throw const LanException('network_error');
      }
      rethrow;
    }
  }

  Future<void> acknowledgeResult(
    LanEndpoint endpoint,
    LanCredential credential,
    String resultHash,
  ) async {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(resultHash)) {
      throw const LanException('invalid_request');
    }
    final object = await _request(
      endpoint.resolve('/lan/v1/rooms/${credential.roomId}/result-ack'),
      'POST',
      {'resumeToken': credential.resumeToken, 'resultHash': resultHash},
    );
    if (!hasExactJsonKeys(object, const {'schemaVersion', 'acknowledged'}) ||
        object['schemaVersion'] != 1 ||
        object['acknowledged'] != true) {
      throw const LanException('invalid_response');
    }
  }

  Future<Map<String, Object?>> _request(
    Uri uri,
    String method,
    Map<String, Object?> body,
  ) async {
    final request = http.Request(method, uri)
      ..followRedirects = false
      ..maxRedirects = 0
      ..headers['Accept'] = 'application/json'
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode(body);
    try {
      final streamed = await _client.send(request).timeout(timeout);
      if (streamed.isRedirect ||
          streamed.statusCode >= 300 && streamed.statusCode < 400) {
        await streamed.stream.drain<void>();
        throw const LanException('redirect_rejected');
      }
      if (streamed.contentLength case final length?
          when length > _maximumResponseBytes) {
        await streamed.stream.drain<void>();
        throw const LanException('invalid_response');
      }
      final bytes = <int>[];
      await for (final chunk in streamed.stream.timeout(timeout)) {
        if (bytes.length + chunk.length > _maximumResponseBytes) {
          throw const LanException('invalid_response');
        }
        bytes.addAll(chunk);
      }
      final object = decodeStrictJsonObject(Uint8List.fromList(bytes));
      if (streamed.statusCode >= 200 && streamed.statusCode < 300) {
        return object;
      }
      throw _decodeError(object, streamed.statusCode);
    } on LanException {
      rethrow;
    } on TimeoutException {
      throw const LanException('timeout');
    } on http.ClientException {
      throw const LanException('network_error');
    } on FormatException {
      throw const LanException('invalid_response');
    }
  }

  static LanException _decodeError(Map<String, Object?> object, int status) {
    if (!hasExactJsonKeys(object, const {'error'}) ||
        object['error'] is! Map<String, Object?>) {
      return const LanException('invalid_response');
    }
    final error = object['error']! as Map<String, Object?>;
    if (!hasExactJsonKeys(error, const {'code', 'message', 'details'}) ||
        error['code'] is! String ||
        error['message'] is! String ||
        error['details'] is! Map<String, Object?> ||
        (error['details']! as Map<String, Object?>).isNotEmpty) {
      return const LanException('invalid_response');
    }
    final code = error['code']! as String;
    const known = {
      'invalid_request',
      'room_key_invalid',
      'resume_invalid',
      'join_expired',
      'room_locked',
      'match_not_finished',
      'result_hash_mismatch',
      'ticket_invalid',
      'stale_revision',
      'action_conflict',
      'internal_error',
    };
    if (!known.contains(code) || status < 400 || status > 599) {
      return const LanException('invalid_response');
    }
    return LanException(code, authoritative: status < 500);
  }

  static LanLaunchReceipt _launchReceipt(
    Map<String, Object?> object,
    String expectedMatchId, {
    required String resumeToken,
  }) {
    if (!hasExactJsonKeys(object, const {
          'schemaVersion',
          'matchId',
          'gameId',
          'playerId',
          'launchTicket',
          'expiresAt',
        }) ||
        object['schemaVersion'] != 1 ||
        object['matchId'] != expectedMatchId ||
        object['gameId'] != 'gomoku' ||
        object['playerId'] is! String ||
        object['launchTicket'] is! String ||
        object['expiresAt'] is! int ||
        !isCanonicalLanUuid(object['playerId']! as String) ||
        !isCanonicalLanCredential(object['launchTicket']! as String) ||
        !isCanonicalLanCredential(resumeToken)) {
      throw const LanException('invalid_response');
    }
    final expiresAt = DateTime.fromMillisecondsSinceEpoch(
      object['expiresAt']! as int,
      isUtc: true,
    );
    return LanLaunchReceipt(
      matchId: expectedMatchId,
      gameId: 'gomoku',
      playerId: object['playerId']! as String,
      launchTicket: object['launchTicket']! as String,
      resumeToken: resumeToken,
      expiresAt: expiresAt,
    );
  }

  void close() => _client.close();
}
