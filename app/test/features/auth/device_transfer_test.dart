import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:gamebox/core/api/api_client.dart';
import 'package:gamebox/core/auth/token_store.dart';
import 'package:gamebox/features/auth/auth_api.dart';
import 'package:gamebox/features/auth/session_controller.dart';
import 'package:gamebox/features/auth/device_transfer.dart';
import 'package:gamebox/features/auth/device_transfer_page.dart';
import 'package:gamebox/features/scratch/scratch_controller.dart';
import 'package:gamebox/design_system/gamebox_theme.dart';

class MemoryTransferStore implements TransferStore {
  final values = <String, String>{};
  String? failingRead;
  final reads = <String>[];
  @override
  Future<String?> read(String key) async {
    reads.add(key);
    if (key == failingRead) throw StateError('storage unavailable');
    return values[key];
  }
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class MemoryScratch implements ScratchStore {
  String? value;
  bool fail = false;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String v) async {
    if (fail) throw StateError('disk unavailable');
    value = v;
  }
}

class MemoryToken implements TokenStore {
  String? value;
  @override
  Future<String?> readRefreshToken() async => value;
  @override
  Future<void> writeRefreshToken(String v) async {
    value = v;
  }

  @override
  Future<void> deleteRefreshToken() async {
    value = null;
  }
}

Map<String, Object?> payload() => {
  'session': {
    'user': {'id': '11111111-1111-4111-8111-111111111111', 'nickname': 'Alice'},
    'accessToken': 'access',
    'refreshToken': 'refresh',
    'accessExpiresAt': DateTime.now()
        .add(const Duration(minutes: 15))
        .millisecondsSinceEpoch,
    'refreshExpiresAt': DateTime.now()
        .add(const Duration(days: 30))
        .millisecondsSinceEpoch,
  },
  'snapshot': jsonEncode({
    'version': 3,
    'counts': List.generate(48, (i) => i == 2 ? 4 : 0),
    'firstFound': List.generate(
      48,
      (i) => i == 2 ? '2026-09-01T00:00:00Z' : null,
    ),
    'favorites': [2],
    'cat': 2,
    'claimed': true,
    'winning': true,
    'isNew': false,
    'serial': 42,
  }),
};
http.Response response(Map<String, Object?> data, [int status = 200]) =>
    http.Response(
      jsonEncode(data),
      status,
      headers: {'content-type': 'application/json'},
    );
void main() {
  test('missing credentials cannot falsely confirm outgoing cancellation', () async {
    final journal = MemoryTransferStore()
      ..values[DeviceTransfer.outgoingKey] = 'pending';
    var requests = 0;
    final api = ApiClient(httpClient: MockClient((_) async {
      requests++;
      throw StateError('unauthenticated cancellation must not be sent');
    }));
    final session = SessionController(authApi: HttpAuthApi(api), tokenStore: MemoryToken());
    await session.restore();
    final transfer = DeviceTransfer(api: api, session: session, store: journal, scratchStore: MemoryScratch());
    await transfer.restoreIncoming();
    expect(await transfer.cancelOutgoing(), isFalse);
    expect(transfer.outgoing, isTrue);
    expect(journal.values[DeviceTransfer.outgoingKey], 'pending');
    expect(requests, 0);
    // An authoritative session_transferred response proves the code was
    // consumed and invalidated by the server, unlike simply losing a token.
    session.migratedAway = true;
    expect(await transfer.cancelOutgoing(), isTrue);
    expect(journal.values, isEmpty);
    expect(transfer.outgoing, isFalse);
    transfer.dispose();
    session.dispose();
    api.close();
  });
  for (final failingKey in [DeviceTransfer.incomingKey, DeviceTransfer.outgoingKey]) {
    test('startup retry rereads both journals after $failingKey fails', () async {
      final journal = MemoryTransferStore()
        ..failingRead = failingKey
        ..values[DeviceTransfer.outgoingKey] = 'pending';
      final token = MemoryToken()..value = 'stored-refresh';
      var cancellationFails = true;
      var cancellations = 0;
      final api = ApiClient(httpClient: MockClient((request) async {
        if (request.method == 'DELETE') {
          cancellations++;
          if (cancellationFails) throw http.ClientException('offline');
          return http.Response('', 204);
        }
        expect(request.url.path, '/v1/auth/refresh');
        return response({'session': payload()['session']});
      }));
      final session = SessionController(authApi: HttpAuthApi(api), tokenStore: token);
      final transfer = DeviceTransfer(api: api, session: session, store: journal, scratchStore: MemoryScratch());
      await transfer.restoreIncoming();
      expect(transfer.incoming, isTrue);
      expect(session.status, SessionStatus.restoring);
      journal.failingRead = null;
      journal.reads.clear();
      // The production retry button supplies the (empty) input field.
      await transfer.receive('');
      expect(journal.reads, containsAllInOrder([DeviceTransfer.incomingKey, DeviceTransfer.outgoingKey]));
      expect(cancellations, 1);
      expect(transfer.incoming, isTrue, reason: 'normal app use stays blocked while cancellation fails');
      expect(journal.values[DeviceTransfer.outgoingKey], 'pending');
      cancellationFails = false;
      // Successful retry must cancel the outstanding code before clearing the gate.
      transfer.addListener(() {
        if (!transfer.incoming) expect(journal.values, isEmpty);
      });
      await transfer.receive('');
      expect(cancellations, 2);
      expect(transfer.incoming, isFalse);
      expect(transfer.outgoing, isFalse);
      expect(session.status, SessionStatus.authenticated);
      expect(journal.values, isEmpty);
      transfer.dispose();
      session.dispose();
      api.close();
    });
  }
  test('durable receiver retries after lost response and restores before publishing session', () async {
    final journal = MemoryTransferStore();
    final scratch = MemoryScratch();
    final token = MemoryToken();
    String? receiver;
    var calls = 0;
    final api = ApiClient(
      httpClient: MockClient((r) async {
        final body = jsonDecode(r.body) as Map;
        expect(body['code'], 'ABCDEFG2');
        if (calls++ == 0) {
          receiver = body['receiver'] as String;
          throw http.ClientException('lost');
        }
        expect(body['receiver'], receiver);
        return response(payload());
      }),
    );
    var session = SessionController(
      authApi: HttpAuthApi(api),
      tokenStore: token,
    );
    await session.restore();
    var transfer = DeviceTransfer(
      api: api,
      session: session,
      store: journal,
      scratchStore: scratch,
    );
    await transfer.receive('abcd efg2');
    expect(transfer.incoming, isTrue);
    expect(session.session, isNull);
    transfer.dispose();
    session.dispose();
    session = SessionController(authApi: HttpAuthApi(api), tokenStore: token);
    session.addListener(() {
      if (session.session != null) {
        expect(jsonDecode(scratch.value!)['serial'], 42);
        expect(journal.values, isEmpty);
      }
    });
    transfer = DeviceTransfer(
      api: api,
      session: session,
      store: journal,
      scratchStore: scratch,
    );
    await transfer.restoreIncoming();
    expect(session.status, SessionStatus.authenticated);
    expect(token.value, 'refresh');
    expect(transfer.incoming, isFalse);
    transfer.dispose();
    session.dispose();
    api.close();
  });
  test('failed local restore keeps receipt and prevents authentication until retry', () async {
    final journal = MemoryTransferStore();
    final scratch = MemoryScratch()..fail = true;
    final token = MemoryToken();
    final api = ApiClient(
      httpClient: MockClient((_) async => response(payload())),
    );
    final session = SessionController(
      authApi: HttpAuthApi(api),
      tokenStore: token,
    );
    await session.restore();
    final transfer = DeviceTransfer(
      api: api,
      session: session,
      store: journal,
      scratchStore: scratch,
    );
    await transfer.receive('ABCDEFG2');
    expect(session.session, isNull);
    expect(token.value, isNull);
    expect(journal.values, isNotEmpty);
    scratch.fail = false;
    await transfer.receive();
    expect(session.status, SessionStatus.authenticated);
    transfer.dispose();
    session.dispose();
    api.close();
  });
  testWidgets(
    'receive page prevents double submit and retains code after invalid response',
    (tester) async {
      final pending = Completer<http.Response>();
      var calls = 0;
      final api = ApiClient(
        httpClient: MockClient((_) {
          calls++;
          return pending.future;
        }),
      );
      final session = SessionController(
        authApi: HttpAuthApi(api),
        tokenStore: MemoryToken(),
      );
      await session.restore();
      final transfer = DeviceTransfer(
        api: api,
        session: session,
        store: MemoryTransferStore(),
        scratchStore: MemoryScratch(),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: GameboxTheme.light(),
          home: DeviceTransferPage(transfer: transfer),
        ),
      );
      await tester.enterText(
        find.byKey(const Key('transfer-input')),
        'ABCDEFG2',
      );
      await tester.tap(find.text('迁入并登录'));
      await tester.pump();
      expect(find.text('正在迁入'), findsOneWidget);
      await transfer.receive('ABCDEFG2');
      expect(calls, 1);
      pending.complete(
        response({
          'error': {
            'code': 'transfer_invalid',
            'message': 'invalid',
            'details': <String, Object?>{},
          },
        }, 422),
      );
      await tester.pumpAndSettle();
      expect(find.text('迁移码无效、已过期或已使用'), findsOneWidget);
      expect(find.text('ABCDEFG2'), findsOneWidget);
      expect(transfer.incoming, isFalse);
      await tester.pumpWidget(const SizedBox());
      transfer.dispose();
      session.dispose();
      api.close();
    },
  );
  testWidgets('expired send page removes the code and offers regeneration', (
    tester,
  ) async {
    final api = ApiClient(
      httpClient: MockClient(
        (_) async => throw StateError('no automatic request'),
      ),
    );
    final session = SessionController(
      authApi: HttpAuthApi(api),
      tokenStore: MemoryToken(),
    );
    final transfer =
        DeviceTransfer(
            api: api,
            session: session,
            store: MemoryTransferStore(),
            scratchStore: MemoryScratch(),
          )
          ..outgoing = true
          ..code = 'ABCDEFG2'
          ..expiresAt = DateTime.now().subtract(const Duration(seconds: 1));
    await tester.pumpWidget(
      MaterialApp(
        theme: GameboxTheme.light(),
        home: DeviceTransferPage(transfer: transfer, sending: true),
      ),
    );
    expect(find.text('重新生成'), findsOneWidget);
    expect(find.byKey(const Key('transfer-code')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    transfer.dispose();
    session.dispose();
    api.close();
  });
  test('recovered counts keep unknown dates across another migration', () {
    final data =
        jsonDecode(payload()['snapshot'] as String) as Map<String, dynamic>;
    data['recoveredDates'] = true;
    data['firstFound'] = List<String?>.filled(48, null);
    final restored =
        jsonDecode(ScratchController.validateTransfer(jsonEncode(data))) as Map;
    expect(restored['counts'][2], 4);
    expect(restored['firstFound'][2], isNull);
    expect(restored['recoveredDates'], true);
  });
  test('corrupt collection is not accepted as transfer progress', () {
    expect(
      () => ScratchController.validateTransfer('{"version":3}'),
      throwsA(isA<Object>()),
    );
  });
}
