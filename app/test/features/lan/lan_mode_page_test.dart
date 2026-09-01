import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/core/lan/lan_api.dart';
import 'package:gamebox/core/lan/lan_credential_store.dart';
import 'package:gamebox/features/lan/lan_mode_page.dart';

import 'lan_room_controller_test.dart'
    show MemoryLanStorage, RecordingLauncher, TestHost;

import 'package:gamebox/features/lan/lan_room_controller.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;

void main() {
  testWidgets('offers create and scan without public authentication', (
    tester,
  ) async {
    final controller = LanRoomController(
      host: TestHost(),
      api: LanApi(client: MockClient((_) async => http.Response('{}', 500))),
      credentialStore: LanCredentialStore(storage: MemoryLanStorage()),
      gameLauncher: RecordingLauncher(),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: LanModePage(controller: controller, nickname: '本地玩家'),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('create-lan-room')), findsOneWidget);
    expect(find.byKey(const Key('join-lan-room')), findsOneWidget);
    expect(find.textContaining('不需要互联网'), findsOneWidget);
  });
}
