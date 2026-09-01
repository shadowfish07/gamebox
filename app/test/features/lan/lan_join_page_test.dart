import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/core/lan/lan_api.dart';
import 'package:gamebox/core/lan/lan_credential_store.dart';
import 'package:gamebox/features/lan/lan_join_page.dart';
import 'package:gamebox/features/lan/lan_room_controller.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'lan_room_controller_test.dart'
    show MemoryLanStorage, RecordingLauncher, TestHost;

void main() {
  testWidgets('camera is opt-in and manual input remains available', (
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
        home: LanJoinPage(controller: controller, nickname: '玩家'),
      ),
    );
    expect(find.byType(MobileScanner), findsNothing);
    expect(find.byKey(const Key('lan-manual-input')), findsOneWidget);
    expect(find.byKey(const Key('start-lan-scanner')), findsOneWidget);
    expect(
      find.bySemanticsIdentifier('submit-lan-manual-input'),
      findsOneWidget,
    );
  });
}
