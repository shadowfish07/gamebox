import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/core/lan/lan_api.dart';
import 'package:gamebox/core/lan/lan_credential_store.dart';
import 'package:gamebox/core/lan/lan_models.dart';
import 'package:gamebox/core/platform/game_launch_request.dart';
import 'package:gamebox/core/platform/game_launcher.dart';
import 'package:gamebox/core/platform/lan_host_platform.dart';
import 'package:gamebox/features/lan/lan_room_controller.dart';
import 'package:gamebox/features/lan/lan_host_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final class TestHost implements LanHostPlatform {
  Completer<LanHostStatus>? statusGate;
  int closeCalls = 0;
  LanHostStatus status = const LanHostStatus(
    state: LanNativeState.empty,
    roomId: null,
    port: 0,
    gameRevision: 0,
    endpointChanged: false,
    endpoint: null,
  );
  @override
  Future<LanHostCreation> createRoom(String nickname) async => LanHostCreation(
    status: status,
    roomKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    joinExpiresAt: DateTime.fromMillisecondsSinceEpoch(
      1900000000000,
      isUtc: true,
    ),
  );
  @override
  Future<LanHostStatus> getStatus() async => statusGate?.future ?? status;
  @override
  Future<LanHostStatus> refreshEndpoint() async => status;
  @override
  Future<LanHostStatus> closeRoom(String mode) async {
    closeCalls += 1;
    status = const LanHostStatus(
      state: LanNativeState.empty,
      roomId: null,
      port: 0,
      gameRevision: 0,
      endpointChanged: false,
      endpoint: null,
    );
    return status;
  }

  @override
  Future<LanHostLaunch> issueHostLaunch() async => LanHostLaunch(
    matchId: '11111111-1111-4111-8111-111111111111',
    gameId: 'gomoku',
    playerId: '22222222-2222-4222-8222-222222222222',
    launchTicket: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    resumeToken: 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBA',
    wsUrl: 'ws://127.0.0.1:50000/lan/v1/ws',
    expiresAt: DateTime.fromMillisecondsSinceEpoch(1900000000000, isUtc: true),
  );
  @override
  Future<LanHostStatus> stopCompletedRoom({
    required bool allowMissingGuestAck,
  }) async => status;
}

final class MemoryLanStorage implements LanKeyValueStorage {
  final values = <String, String>{};
  @override
  Future<void> delete(String key) async => values.remove(key);
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

final class RecordingLauncher implements GameLauncher {
  GameLaunchRequest? request;
  @override
  Future<void> launch(GameLaunchRequest request) async =>
      this.request = request;
  @override
  Future<void> launchHostSmoke() async {}
}

void main() {
  const room = '11111111-1111-4111-8111-111111111111';
  const player = '22222222-2222-4222-8222-222222222222';
  const key = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

  test('creates host room, reports missing address, then exposes QR', () async {
    final host = TestHost();
    host.status = const LanHostStatus(
      state: LanNativeState.waiting,
      roomId: room,
      port: 50000,
      gameRevision: 0,
      endpointChanged: false,
      endpoint: null,
    );
    final controller = LanRoomController(
      host: host,
      api: LanApi(client: MockClient((_) async => http.Response('{}', 500))),
      credentialStore: LanCredentialStore(storage: MemoryLanStorage()),
      gameLauncher: RecordingLauncher(),
    );
    await controller.createHost('玩家甲');
    expect(
      controller.state,
      isA<LanWaitingForGuest>()
          .having((s) => s.qr, 'qr', isNull)
          .having((s) => s.errorCode, 'error', 'no_network_address'),
    );
    host.status = LanHostStatus(
      state: LanNativeState.waiting,
      roomId: room,
      port: 50000,
      gameRevision: 0,
      endpointChanged: false,
      endpoint: LanEndpoint.parse('192.168.4.1:50000'),
    );
    await controller.refreshEndpoint();
    expect(
      (controller.state as LanWaitingForGuest).qr!.encode(),
      startsWith('gamebox-lan://join?'),
    );
  });

  testWidgets('host cancellation states its consequence before closing', (
    tester,
  ) async {
    final host = TestHost()
      ..status = LanHostStatus(
        state: LanNativeState.waiting,
        roomId: room,
        port: 50000,
        gameRevision: 0,
        endpointChanged: false,
        endpoint: LanEndpoint.parse('192.168.4.1:50000'),
      );
    final api = LanApi(
      client: MockClient((_) async => http.Response('{}', 500)),
    );
    addTearDown(api.close);
    final controller = LanRoomController(
      host: host,
      api: api,
      credentialStore: LanCredentialStore(storage: MemoryLanStorage()),
      gameLauncher: RecordingLauncher(),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: LanHostPage(controller: controller, nickname: '玩家甲'),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('credential-qr-sensitive')), findsOneWidget);
    await tester.tap(find.byKey(const Key('cancel-lan-room')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('cancel-lan-room-confirmation')),
      findsOneWidget,
    );
    expect(find.text('对方将无法再通过当前二维码加入。'), findsOneWidget);
    expect(host.closeCalls, 0);

    await tester.tap(find.byKey(const Key('dismiss-cancel-lan-room')));
    await tester.pumpAndSettle();
    expect(host.closeCalls, 0);

    await tester.tap(find.byKey(const Key('cancel-lan-room')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-cancel-lan-room')));
    await tester.pumpAndSettle();
    expect(host.closeCalls, 1);
  });

  test('joins through production parser, commits credential and launches LAN', () async {
    final storage = MemoryLanStorage();
    final launcher = RecordingLauncher();
    final endpoint = LanEndpoint.parse('10.0.2.2:50000');
    final controller = LanRoomController(
      host: TestHost(),
      api: LanApi(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'schemaVersion': 1,
              'matchId': room,
              'gameId': 'gomoku',
              'playerId': player,
              'launchTicket': key,
              'expiresAt': 1900000000000,
            }),
            200,
          ),
        ),
      ),
      credentialStore: LanCredentialStore(storage: storage),
      gameLauncher: launcher,
      now: () =>
          DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true),
    );
    final raw =
        'gamebox-lan://join?v=1&room=$room&host=10.0.2.2&port=50000&key=$key&exp=1800000000000';
    await controller.joinRaw(raw, '玩家乙');
    expect(
      controller.state,
      isA<LanActive>().having((s) => s.role, 'role', 'guest'),
    );
    expect(launcher.request!.source, GameLaunchSource.lan);
    expect(launcher.request!.wsUrl, endpoint.webSocketUri.toString());
    expect(storage.values.values.single, contains('"kind":"credential"'));
  });

  test('ignores a host status response after disposal', () async {
    final host = TestHost();
    final gate = Completer<LanHostStatus>();
    host.statusGate = gate;
    final controller = LanRoomController(
      host: host,
      api: LanApi(client: MockClient((_) async => http.Response('{}', 500))),
      credentialStore: LanCredentialStore(storage: MemoryLanStorage()),
      gameLauncher: RecordingLauncher(),
    );

    final refresh = controller.refreshHostStatus();
    controller.dispose();
    gate.complete(host.status);

    await expectLater(refresh, completes);
  });
}
