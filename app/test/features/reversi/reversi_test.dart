import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/core/platform/game_launch_request.dart';
import 'package:gamebox/design_system/gamebox_theme.dart';
import 'package:gamebox/features/reversi/reversi_controller.dart';
import 'package:gamebox/features/reversi/reversi_launcher.dart';
import 'package:gamebox/features/home/home_api.dart';
import 'package:gamebox/features/reversi/reversi_models.dart';
import 'package:gamebox/features/reversi/reversi_page.dart';
import 'package:gamebox/features/reversi/reversi_transport.dart';

const black = '11111111-1111-4111-8111-111111111111';
const white = '22222222-2222-4222-8222-222222222222';
const match = '33333333-3333-4333-8333-333333333333';
Map<String, Object?> opening() {
  final board = List.filled(64, 0);
  board[27] = board[36] = 2;
  board[28] = board[35] = 1;
  return {
    'status': 'active',
    'board': board,
    'boardSize': 8,
    'blackUserId': black,
    'whiteUserId': white,
    'nextColor': 'black',
    'winnerUserId': null,
    'result': null,
    'legalMoves': [
      {'x': 3, 'y': 2},
      {'x': 2, 'y': 3},
      {'x': 5, 'y': 4},
      {'x': 4, 'y': 5},
    ],
    'blackCount': 2,
    'whiteCount': 2,
    'passedColor': null,
    'lastMove': null,
  };
}

Map<String, Object?> afterMove() {
  final s = opening();
  final b = s['board'] as List<int>;
  b[19] = b[27] = 1;
  return {
    ...s,
    'board': b,
    'blackCount': 4,
    'whiteCount': 1,
    'nextColor': 'white',
    'lastMove': {'x': 3, 'y': 2},
    'legalMoves': [
      {'x': 2, 'y': 2},
      {'x': 4, 'y': 2},
      {'x': 2, 'y': 4},
    ],
  };
}

final class SocketFake implements ReversiTransport {
  final incoming = StreamController<Object?>.broadcast(sync: true);
  final sent = <Map<String, dynamic>>[];
  @override
  Stream<Object?> get messages => incoming.stream;
  @override
  void send(String message) =>
      sent.add(jsonDecode(message) as Map<String, dynamic>);
  @override
  Future<void> close() async {}
  void emit(String type, Map<String, Object?> payload, {int revision = 0}) =>
      incoming.add(
        jsonEncode({
          'protocolVersion': 1,
          'gameId': 'reversi',
          'matchId': match,
          'type': type,
          'revision': revision,
          'payload': payload,
        }),
      );
  void ready({Map<String, Object?>? state, int revision = 0}) {
    emit('platform.connected', {'userId': black, 'resumeToken': 'test-resume'});
    emit('platform.snapshot', state ?? opening(), revision: revision);
  }
}

ReversiController controller(SocketFake socket) => ReversiController(
  request: GameLaunchRequest(
    gameId: 'reversi',
    matchId: match,
    launchTicket: 'test-ticket',
    wsUrl: 'ws://localhost:1/v1/ws',
  ),
  freshTicket: () async => 'fresh-ticket',
  connect: (_) async => socket,
);

final class UnusedHomeApi implements HomeApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('launcher retains connection across route rebuilds', (
    tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (_) async => null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: key, home: const Scaffold()),
    );
    unawaited(
      ReversiLauncher(navigatorKey: key, api: UnusedHomeApi()).launch(
        GameLaunchRequest(
          gameId: 'reversi',
          matchId: match,
          launchTicket: 'test-ticket',
          wsUrl: 'ws://localhost:1/v1/ws',
        ),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final context = tester.element(find.byType(ReversiPage));
    final first = tester
        .widget<ReversiPage>(find.byType(ReversiPage))
        .controller;
    final route = ModalRoute.of(context)! as MaterialPageRoute<void>;
    expect((route.builder(context) as ReversiPage).controller, same(first));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 11));
  });
  test(
    'snapshot rejects corrupt board, counts, players and terminal state',
    () {
      expect(ReversiSnapshot.fromJson(0, opening()).legalMoves, {
        19,
        26,
        37,
        44,
      });
      for (final patch in [
        {'board': List.filled(64, 3)},
        {'blackCount': 3},
        {'whiteUserId': black},
        {'status': 'finished'},
        {
          'legalMoves': [
            {'x': 3, 'y': 3},
          ],
        },
      ]) {
        expect(
          () => ReversiSnapshot.fromJson(0, {...opening(), ...patch}),
          throwsFormatException,
        );
      }
    },
  );
  test('pending move waits for authority and blocks duplicate and wrong-turn input', () async {
    final socket = SocketFake();
    final c = controller(socket);
    addTearDown(c.dispose);
    await c.start();
    socket.ready();
    c.move(19);
    c.move(26);
    expect(c.pending, true);
    expect(c.snapshot!.board[19], 0);
    socket.emit('platform.snapshot', opening());
    expect(c.pending, true);
    expect(
      socket.sent.where((m) => m['type'] == 'reversi.move.requested').length,
      1,
    );
    socket.emit('reversi.move.accepted', {}, revision: 1);
    expect(c.canAct, false);
    socket.emit('platform.snapshot', afterMove(), revision: 1);
    expect(c.pending, false);
    expect(c.snapshot!.board[19], 1);
    expect(c.myTurn, false);
    c.move(18);
    expect(
      socket.sent.where((m) => m['type'] == 'reversi.move.requested').length,
      1,
    );
    socket.emit('platform.snapshot', opening());
    expect(c.snapshot!.revision, 1);
  });
  test(
    'pause retains board, closes actions and resumes with server snapshot',
    () async {
      final socket = SocketFake();
      final c = controller(socket);
      addTearDown(c.dispose);
      await c.start();
      socket.ready();
      c.move(19);
      c.pause();
      expect(c.canAct, false);
      expect(c.pendingCell, null);
      expect(c.snapshot!.blackCount, 2);
      c.resume();
      await Future<void>.delayed(Duration.zero);
      expect(socket.sent.last['payload'], {'resumeToken': 'test-resume'});
      expect(c.canAct, false);
      socket.ready(state: afterMove(), revision: 1);
      expect(c.snapshot!.blackCount, 4);
      expect(c.canAct, true);
    },
  );
  test(
    'rejection retains confirmed board and resynchronizes before retry',
    () async {
      final socket = SocketFake();
      final c = controller(socket);
      addTearDown(c.dispose);
      await c.start();
      socket.ready();
      c.move(19);
      socket.emit('platform.error', {'code': 'stale_revision'});
      expect(c.canAct, false);
      expect(c.snapshot!.board[19], 0);
      socket.emit('platform.snapshot', opening());
      expect(c.pending, false);
      expect(c.myTurn, true);
      expect(c.error, isNotNull);
    },
  );
  for (final dark in [false, true]) {
    testWidgets(
      'production page legal input, rules, resignation and back ($dark)',
      (tester) async {
        tester.view.physicalSize = const Size(360, 780);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final socket = SocketFake();
        final c = controller(socket);
        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? GameboxTheme.dark() : GameboxTheme.light(),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ReversiPage(controller: c),
                    ),
                  ),
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        socket.ready();
        await tester.pumpAndSettle();
        expect(find.text('轮到你了'), findsOneWidget);
        await tester.tap(find.byKey(const Key('reversi-cell-19')));
        await tester.pump();
        expect(find.text('正在提交…'), findsOneWidget);
        socket.emit('platform.snapshot', afterMove(), revision: 1);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('reversi-rules')));
        await tester.pumpAndSettle();
        expect(find.text('黑白棋规则'), findsOneWidget);
        await tester.tap(find.text('知道了'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('reversi-menu')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('认输'));
        await tester.pumpAndSettle();
        expect(find.text('认输并结束这局黑白棋？'), findsOneWidget);
        await tester.tap(find.text('继续对局'));
        await tester.pumpAndSettle();
        expect(
          socket.sent.where((m) => m['type'] == 'reversi.resign.requested'),
          isEmpty,
        );
        await tester.tap(find.byKey(const Key('reversi-menu')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('认输'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('reversi-confirm-resign')));
        await tester.pump();
        expect(
          socket.sent
              .where((m) => m['type'] == 'reversi.resign.requested')
              .length,
          1,
        );
        socket.emit('platform.snapshot', {
          ...afterMove(),
          'status': 'finished',
          'nextColor': '',
          'legalMoves': [],
          'winnerUserId': white,
          'result': 'resignation',
        }, revision: 2);
        await tester.pumpAndSettle();
        expect(find.text('对方获胜'), findsOneWidget);
        await tester.tap(find.byKey(const Key('reversi-result-back')));
        await tester.pumpAndSettle();
        expect(find.text('打开'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('system back preserves active game and does not resign', (
    tester,
  ) async {
    final socket = SocketFake();
    final c = controller(socket);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => ReversiPage(controller: c),
              ),
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    socket.ready();
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('打开'), findsOneWidget);
    expect(
      socket.sent.where((m) => m['type'] == 'reversi.resign.requested'),
      isEmpty,
    );
  });
}
