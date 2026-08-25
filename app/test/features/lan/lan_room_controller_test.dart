import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/core/lan/lan_api.dart';
import 'package:gamebox/core/lan/lan_credential_store.dart';
import 'package:gamebox/core/lan/lan_models.dart';
import 'package:gamebox/core/platform/game_launch_request.dart';
import 'package:gamebox/core/platform/game_launcher.dart';
import 'package:gamebox/core/platform/lan_host_platform.dart';
import 'package:gamebox/features/lan/lan_room_controller.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final class TestHost implements LanHostPlatform {
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
  Future<LanHostStatus> getStatus() async => status;
  @override
  Future<LanHostStatus> refreshEndpoint() async => status;
  @override
  Future<LanHostStatus> closeRoom(String mode) async {
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
    launchTicket: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    wsUrl: 'ws://127.0.0.1:50000/v1/ws',
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
}
