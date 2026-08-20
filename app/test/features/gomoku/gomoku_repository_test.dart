import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/core/platform/game_launch_request.dart';
import 'package:gamebox/core/platform/game_launcher.dart';
import 'package:gamebox/features/gomoku/gomoku_models.dart';
import 'package:gamebox/features/gomoku/gomoku_repository.dart';
import 'package:gamebox/features/home/home_api.dart';

void main() {
  const matchId = '33333333-3333-4333-8333-333333333333';
  const opponentId = '22222222-2222-4222-8222-222222222222';
  final now = DateTime.utc(2026, 8, 20, 12);

  for (final entry in {
    'http://10.0.2.2:8080': 'ws://10.0.2.2:8080/v1/ws',
    'https://games.example.test': 'wss://games.example.test/v1/ws',
    'https://[2001:db8::1]:8443': 'wss://[2001:db8::1]:8443/v1/ws',
  }.entries) {
    test('openMatch maps ${entry.key} to the exact websocket origin', () async {
      final trace = <String>[];
      final api = _FakeHomeApi()
        ..onTicket = (requestedMatchId) async {
          trace.add('ticket:$requestedMatchId');
          return _ticket(matchId, now);
        };
      final launcher = _FakeGameLauncher(trace);
      final repository = GomokuRepository(
        api: api,
        gameLauncher: launcher,
        apiBaseUri: Uri.parse(entry.key),
        now: () => now,
      );

      await repository.openMatch(matchId);

      expect(trace, ['ticket:$matchId', 'launch:$matchId']);
      expect(launcher.request?.gameId, 'gomoku');
      expect(launcher.request?.matchId, matchId);
      expect(launcher.request?.launchTicket, 'launch-ticket');
      expect(launcher.request?.wsUrl, entry.value);
    });
  }

  test('openMatch awaits only the native Activity-start future', () async {
    final launchStarted = Completer<void>();
    final activityStarted = Completer<void>();
    final api = _FakeHomeApi()..onTicket = (_) async => _ticket(matchId, now);
    final launcher = _FakeGameLauncher(<String>[])
      ..onLaunch = (_) {
        launchStarted.complete();
        return activityStarted.future;
      };
    final repository = GomokuRepository(
      api: api,
      gameLauncher: launcher,
      apiBaseUri: Uri.parse('https://games.example.test'),
      now: () => now,
    );

    var completed = false;
    final opening = repository.openMatch(matchId).then((_) => completed = true);
    await launchStarted.future;
    expect(completed, isFalse);

    activityStarted.complete();
    await opening;
    expect(completed, isTrue);
  });

  test(
    'createAndOpen obtains the match id then calls the same launch flow',
    () async {
      final trace = <String>[];
      final api = _FakeHomeApi()
        ..onCreate = (id) async {
          trace.add('create:$id');
          return const CreatedGomokuMatch(id: matchId, gameId: 'gomoku');
        }
        ..onTicket = (id) async {
          trace.add('ticket:$id');
          return _ticket(id, now);
        };
      final launcher = _FakeGameLauncher(trace);
      final repository = GomokuRepository(
        api: api,
        gameLauncher: launcher,
        apiBaseUri: Uri.parse('http://10.0.2.2:8080'),
        now: () => now,
      );

      final createdMatchId = await repository.createAndOpen(opponentId);

      expect(createdMatchId, matchId);
      expect(trace, [
        'create:$opponentId',
        'ticket:$matchId',
        'launch:$matchId',
      ]);
    },
  );

  test(
    'expired or cross-match launch tickets fail before native launch',
    () async {
      final cases = <String, GomokuLaunchTicket>{
        'expired': _ticket(matchId, now.subtract(const Duration(minutes: 2))),
        'cross-match': _ticket(opponentId, now),
      };
      for (final entry in cases.entries) {
        final api = _FakeHomeApi()..onTicket = (_) async => entry.value;
        final launcher = _FakeGameLauncher(<String>[]);
        final repository = GomokuRepository(
          api: api,
          gameLauncher: launcher,
          apiBaseUri: Uri.parse('https://games.example.test'),
          now: () => now,
        );

        await expectLater(
          repository.openMatch(matchId),
          throwsA(isA<GomokuLaunchConfigurationException>()),
        );
        expect(launcher.calls, 0, reason: entry.key);
      }
    },
  );

  test('repository rejects any API base URL that is not an HTTP origin', () {
    for (final value in [
      'ws://games.example.test',
      'https://user@games.example.test',
      'https://games.example.test/base',
      'https://games.example.test?query=1',
      'https://games.example.test#fragment',
    ]) {
      expect(
        () => GomokuRepository(
          api: _FakeHomeApi(),
          gameLauncher: _FakeGameLauncher(<String>[]),
          apiBaseUri: Uri.parse(value),
          now: () => now,
        ),
        throwsArgumentError,
        reason: value,
      );
    }
  });
}

GomokuLaunchTicket _ticket(String matchId, DateTime now) => GomokuLaunchTicket(
  matchId: matchId,
  gameId: 'gomoku',
  launchTicket: 'launch-ticket',
  expiresAt: now.add(const Duration(minutes: 1)),
);

final class _FakeGameLauncher implements GameLauncher {
  _FakeGameLauncher(this.trace);

  final List<String> trace;
  Future<void> Function(GameLaunchRequest request)? onLaunch;
  GameLaunchRequest? request;
  int calls = 0;

  @override
  Future<void> launch(GameLaunchRequest request) {
    calls += 1;
    this.request = request;
    trace.add('launch:${request.matchId}');
    return onLaunch?.call(request) ?? Future<void>.value();
  }

  @override
  Future<void> launchHostSmoke() =>
      Future<void>.error(StateError('unexpected host smoke'));
}

final class _FakeHomeApi implements HomeApi {
  Future<CreatedGomokuMatch> Function(String opponentId)? onCreate;
  Future<GomokuLaunchTicket> Function(String matchId)? onTicket;

  @override
  Future<void> cancelMatch(String matchId) =>
      Future<void>.error(StateError('unexpected cancel'));

  @override
  Future<CreatedGomokuMatch> createMatch(String opponentId) =>
      onCreate?.call(opponentId) ??
      Future<CreatedGomokuMatch>.error(StateError('unexpected create'));

  @override
  Future<GomokuLaunchTicket> createLaunchTicket(String matchId) =>
      onTicket?.call(matchId) ??
      Future<GomokuLaunchTicket>.error(StateError('unexpected ticket'));

  @override
  Future<List<GomokuOpponent>> fetchOpponents() =>
      Future<List<GomokuOpponent>>.error(StateError('unexpected opponents'));

  @override
  Future<GomokuStatus> fetchStatus() =>
      Future<GomokuStatus>.error(StateError('unexpected status'));
}
