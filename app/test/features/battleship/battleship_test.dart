import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/core/api/api_error.dart';
import 'package:gamebox/design_system/gamebox_theme.dart';
import 'package:gamebox/features/battleship/battleship_api.dart';
import 'package:gamebox/features/battleship/battleship_controller.dart';
import 'package:gamebox/features/battleship/battleship_models.dart';
import 'package:gamebox/features/battleship/battleship_lobby.dart';
import 'package:gamebox/features/battleship/battleship_page.dart';

const user = '11111111-1111-4111-8111-111111111111';
const opponent = '22222222-2222-4222-8222-222222222222';
const matchId = '33333333-3333-4333-8333-333333333333';
List<FleetShip> fleet() => [
  for (var i = 0; i < 5; i++) FleetShip(i, i * 10, false),
];
Map<String, Object?> state({
  String phase = 'placement',
  bool turn = false,
  bool ready = false,
}) => {
  'id': matchId,
  'revision': 0,
  'opponentId': opponent,
  'opponentName': '舰长乙',
  'phase': phase,
  'yourTurn': turn,
  'ready': ready,
  'enemyReady': ready,
  'ownShips': ready ? fleet().map((s) => s.toJson()).toList() : [],
  'enemyShips': <Object?>[],
  'shots': <Object?>[],
  'incoming': <Object?>[],
  'winner': '',
  'endOffer': '',
  'rematchRequested': false,
  'enemyRematchRequested': false,
  'nextMatchId': '',
};

class MemoryPending implements SeaPendingStore {
  Map<String, Object?>? value;
  @override
  Future<Map<String, Object?>?> read(String key) async => value;
  @override
  Future<void> write(String key, Map<String, Object?>? v) async {
    value = v;
  }
}

class FakeSea implements BattleshipApi {
  FakeSea(this.json);
  Map<String, Object?> json;
  final calls = <Map<String, Object?>>[];
  Completer<SeaMatch>? held;
  Completer<SeaMatch>? heldGet;
  bool fail = false;
  @override
  String get userId => user;
  @override
  Future<SeaMatch> get(String id) async =>
      heldGet == null ? SeaMatch(json) : heldGet!.future;
  @override
  Future<SeaMatch> act(String id, Map<String, Object?> a) async {
    calls.add(a);
    if (held != null) return held!.future;
    if (fail) throw const ApiError(code: 'network_error', message: '网络失败');
    json = {...json, 'revision': (json['revision'] as int) + 1};
    if (a['kind'] == 'save' || a['kind'] == 'ready')
      json = {...json, 'ownShips': a['ships'], 'ready': a['kind'] == 'ready'};
    if (a['kind'] == 'fire')
      json = {
        ...json,
        'yourTurn': false,
        'shots': [
          {'cell': a['cell'], 'hit': false},
        ],
      };
    return SeaMatch(json);
  }

  @override
  Future<SeaMatch> create(String id, String opponent) => get(id);
  @override
  Future<SeaPage<SeaMatch>> matches([String after = '']) async =>
      SeaPage([SeaMatch(json)], '');
  @override
  Future<SeaPage<SeaOpponent>> opponents([String after = '']) async =>
      const SeaPage([SeaOpponent(opponent, '舰长乙')], '');
}

void main() {
  for (final rematch in [false, true]) {
    testWidgets(
      'theme rebuild preserves routed match controller rematch=$rematch',
      (tester) async {
        final api = FakeSea(
          rematch
              ? {
                  ...state(phase: 'finished', ready: true),
                  'nextMatchId': matchId,
                }
              : state(phase: 'battle', ready: true, turn: true),
        );
        final store = MemoryPending();
        final home = rematch
            ? BattleshipPage(
                controller: BattleshipController(api, matchId, store),
              )
            : BattleshipLobby(api: api, store: store);
        late StateSetter changeTheme;
        var dark = false;
        await tester.pumpWidget(
          StatefulBuilder(
            builder: (context, setState) {
              changeTheme = setState;
              return MaterialApp(
                theme: dark ? GameboxTheme.dark() : GameboxTheme.light(),
                home: home,
              );
            },
          ),
        );
        await tester.pumpAndSettle();
        if (rematch) {
          api.json = state(phase: 'battle', ready: true, turn: true);
          await tester.tap(find.byKey(const Key('sea-next')));
        } else {
          await tester.tap(find.text('舰长乙'));
        }
        await tester.pumpAndSettle();
        final controller = tester
            .widget<BattleshipPage>(find.byType(BattleshipPage))
            .controller;
        expect(find.text('轮到你了'), findsOneWidget);
        changeTheme(() => dark = true);
        await tester.pumpAndSettle();
        expect(
          tester.widget<BattleshipPage>(find.byType(BattleshipPage)).controller,
          same(controller),
        );
        expect(find.text('轮到你了'), findsOneWidget);
        expect(find.text('正在加载对局'), findsNothing);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      },
    );
  }

  test('manual fleets reject overlap and boundary violations', () {
    expect(validFleet([const FleetShip(0, 9, false)]), isFalse);
    expect(
      validFleet([const FleetShip(0, 0, false), const FleetShip(1, 0, true)]),
      isFalse,
    );
    expect(
      validFleet([const FleetShip(0, 0, false), const FleetShip(1, 10, false)]),
      isTrue,
    );
  });
  test(
    'silent polling keeps input usable and cannot roll back an accepted shot',
    () async {
      final api = FakeSea(state(phase: 'battle', turn: true, ready: true));
      final c = BattleshipController(api, matchId, MemoryPending());
      await c.start();
      final old = SeaMatch(api.json);
      api.heldGet = Completer<SeaMatch>();
      final polling = c.refresh(silent: true);
      expect(c.canAct, isTrue);
      await c.submit('fire', cell: 4);
      api.heldGet!.complete(old);
      await polling;
      expect(c.match!.revision, 1);
      expect(c.match!.shots.single.cell, 4);
      c.dispose();
    },
  );
  test('invalid authority data fails closed', () {
    expect(
      () => SeaMatch({...state(), 'yourTurn': true}),
      throwsFormatException,
    );
    expect(
      () => SeaMatch({
        ...state(),
        'ownShips': [
          {'id': 0, 'cell': 9, 'vertical': false},
        ],
      }),
      throwsFormatException,
    );
    expect(
      () => SeaMatch({
        ...state(),
        'shots': [
          {'cell': 100, 'hit': true},
        ],
      }),
      throwsFormatException,
    );
  });
  test(
    'uncertain requests persist and replay exact identity after reopening',
    () async {
      final api = FakeSea(state(phase: 'battle', turn: true, ready: true))
        ..fail = true;
      final store = MemoryPending();
      var c = BattleshipController(api, matchId, store);
      await c.start();
      await c.submit('fire', cell: 15);
      expect(c.match!.shots, isEmpty);
      expect(store.value, isNotNull);
      final action = store.value;
      c.dispose();
      c = BattleshipController(api, matchId, store);
      await c.start();
      expect(c.canAct, isFalse);
      api.fail = false;
      await c.retry();
      expect(api.calls.last, same(action));
      expect(c.match!.shots.single.cell, 15);
      expect(store.value, isNull);
      c.dispose();
    },
  );
  test('pending and background prevent double submission', () async {
    final api = FakeSea(state(phase: 'battle', turn: true, ready: true))
      ..held = Completer<SeaMatch>();
    final c = BattleshipController(api, matchId, MemoryPending());
    await c.start();
    final sent = c.submit('fire', cell: 2);
    await Future<void>.delayed(Duration.zero);
    await c.submit('fire', cell: 3);
    expect(api.calls.length, 1);
    expect(c.match!.shots, isEmpty);
    c.setForeground(false);
    api.held!.complete(SeaMatch(api.json));
    await sent;
    expect(c.canAct, isFalse);
    c.dispose();
  });
  for (final dark in [false, true]) {
    testWidgets(
      'native board requires explicit fire and follows accepted state ${dark ? 'dark' : 'light'}',
      (tester) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final api = FakeSea(state(phase: 'battle', turn: true, ready: true));
        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? GameboxTheme.dark() : GameboxTheme.light(),
            home: BattleshipPage(
              controller: BattleshipController(api, matchId, MemoryPending()),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('sea-cell-15')));
        await tester.pump();
        expect(api.calls, isEmpty);
        expect(find.text('向 B6 开火'), findsOneWidget);
        await tester.tap(find.text('向 B6 开火'));
        await tester.pumpAndSettle();
        expect(api.calls.single['kind'], 'fire');
        expect(find.text('等待对方出手'), findsWidgets);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  for (final scenario in ['empty', 'rotate', 'overlap', 'edge']) {
    testWidgets('rotate selected ship: $scenario', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final ships = <FleetShip>[
        if (scenario != 'empty')
          FleetShip(0, scenario == 'edge' ? 90 : 0, false),
        if (scenario == 'overlap') const FleetShip(4, 10, false),
      ];
      final api = FakeSea({
        ...state(),
        'ownShips': ships.map((s) => s.toJson()).toList(),
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: GameboxTheme.light(),
          home: BattleshipPage(
            controller: BattleshipController(api, matchId, MemoryPending()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('随机布阵'), findsNothing);
      final rotate = find.byKey(const Key('sea-rotate'));
      await tester.ensureVisible(rotate);
      await tester.pumpAndSettle();
      expect(find.text('旋转舰船'), findsOneWidget);
      if (scenario == 'empty') {
        expect(tester.widget<OutlinedButton>(rotate).onPressed, isNull);
      } else {
        await tester.tap(rotate);
        await tester.pumpAndSettle();
        if (scenario == 'rotate') {
          expect(api.calls, hasLength(1));
          expect(SeaMatch(api.json).ownShips.single.cells, [0, 10, 20, 30, 40]);
          final cell = find.byKey(const ValueKey('sea-cell-1'));
          await tester.ensureVisible(cell);
          await tester.pumpAndSettle();
          await tester.tap(cell);
          await tester.pumpAndSettle();
          expect(SeaMatch(api.json).ownShips.single.cells, [1, 11, 21, 31, 41]);
        } else {
          expect(api.calls, isEmpty);
          expect(find.text('这里放不下这艘船'), findsOneWidget);
          expect(SeaMatch(api.json).ownShips.first.vertical, isFalse);
        }
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  }
  testWidgets('manual placement persists; ready locks editing', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = FakeSea(state());
    await tester.pumpWidget(
      MaterialApp(
        theme: GameboxTheme.light(),
        home: BattleshipPage(
          controller: BattleshipController(api, matchId, MemoryPending()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sea-cell-0')));
    await tester.pumpAndSettle();
    expect(api.calls.single['kind'], 'save');
    expect(SeaMatch(api.json).ownShips.single.cells, [0, 1, 2, 3, 4]);
    for (var id = 1; id < 5; id++) {
      final chip = find.byKey(ValueKey('sea-ship-$id'));
      await tester.ensureVisible(chip);
      await tester.pumpAndSettle();
      await tester.tap(chip);
      final cell = find.byKey(ValueKey('sea-cell-${id * 10}'));
      await tester.ensureVisible(cell);
      await tester.pumpAndSettle();
      await tester.tap(cell);
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('准备好了'));
    await tester.pumpAndSettle();
    expect(SeaMatch(api.json).ready, isTrue);
    expect(find.text('等待对方布阵'), findsWidgets);
    expect(find.byKey(const Key('sea-rotate')), findsNothing);
    expect(find.text('随机布阵'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('resignation requires consequence confirmation', (tester) async {
    final api = FakeSea(state(phase: 'battle', turn: true, ready: true));
    await tester.pumpWidget(
      MaterialApp(
        theme: GameboxTheme.light(),
        home: BattleshipPage(
          controller: BattleshipController(api, matchId, MemoryPending()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('对局操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('认输'));
    await tester.pumpAndSettle();
    expect(api.calls, isEmpty);
    expect(find.text('对方将获得本局胜利。'), findsOneWidget);
    await tester.tap(find.text('继续对局'));
    await tester.pumpAndSettle();
    expect(api.calls, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
}
