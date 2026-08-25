import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/core/auth/token_store.dart';
import 'package:gamebox/core/lan/lan_credential_store.dart';
import 'package:gamebox/core/lan/lan_models.dart';
import 'package:gamebox/core/lan/private_ipv4.dart';

final class _MemoryStorage implements LanKeyValueStorage {
  final values = <String, String>{};
  @override
  Future<void> delete(String key) async => values.remove(key);
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

void main() {
  const room = '11111111-1111-4111-8111-111111111111';
  const player = '22222222-2222-4222-8222-222222222222';
  final endpoint = LanEndpoint(
    host: PrivateIpv4.parse('192.168.4.1'),
    port: 50000,
  );

  test('persists candidate before join and promotes the same token', () async {
    final storage = _MemoryStorage();
    final store = LanCredentialStore(storage: storage, random: Random(7));
    final candidate = await store.createCandidate(room, endpoint);
    expect(isCanonicalLanUuid(candidate.joinAttemptId), isTrue);
    expect(isCanonicalLanCredential(candidate.candidateResumeToken), isTrue);
    expect(
      storage.values.keys.single,
      startsWith(LanCredentialStore.keyPrefix),
    );
    expect(storage.values.keys.single, isNot(SecureTokenStore.refreshTokenKey));
    expect(
      (await store.readCandidate(room))!.candidateResumeToken,
      candidate.candidateResumeToken,
    );

    await store.commit(candidate, player);
    final credential = (await store.readCredential(room))!;
    expect(credential.playerId, player);
    expect(credential.resumeToken, candidate.candidateResumeToken);
    expect(credential.toString(), isNot(contains(credential.resumeToken)));
  });

  test(
    'retains candidates until explicit deletion and rejects corrupt data',
    () async {
      final storage = _MemoryStorage();
      final store = LanCredentialStore(storage: storage, random: Random(8));
      await store.createCandidate(room, endpoint);
      expect(await store.readCandidate(room), isNotNull);
      storage.values[storage.values.keys.single] = '{}';
      expect(
        () => store.readCandidate(room),
        throwsA(
          isA<LanException>().having(
            (e) => e.code,
            'code',
            'credential_corrupt',
          ),
        ),
      );
      await store.delete(room);
      expect(storage.values, isEmpty);
    },
  );
}
