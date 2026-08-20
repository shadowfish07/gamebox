import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/core/api/api_error.dart';
import 'package:gamebox/core/platform/game_launch_request.dart';
import 'package:gamebox/core/platform/game_launcher.dart';
import 'package:gamebox/features/gomoku/gomoku_models.dart';
import 'package:gamebox/features/gomoku/gomoku_repository.dart';
import 'package:gamebox/features/home/home_api.dart';
import 'package:gamebox/features/home/home_controller.dart';

void main() {
  const matchId = '33333333-3333-4333-8333-333333333333';
  const opponentId = '22222222-2222-4222-8222-222222222222';
  var now = DateTime.utc(2026, 8, 20, 12);

  setUp(() => now = DateTime.utc(2026, 8, 20, 12));

  test('start refreshes immediately and polls only while foreground', () async {
    final scheduler = _FakeScheduler();
    final api = _FakeHomeApi()..onStatus = () async => const GomokuIdleStatus();
    final controller = _controller(api, scheduler: scheduler, now: () => now);

    controller.start();
    await _flush();

    expect(api.statusCalls, 1);
    expect(controller.status, isA<GomokuIdleStatus>());
    expect(controller.lastUpdatedAt, now);
    expect(scheduler.activePeriods, [const Duration(seconds: 10)]);

    now = now.add(const Duration(seconds: 10));
    scheduler.fire();
    await _flush();
    expect(api.statusCalls, 2);
    expect(controller.lastUpdatedAt, now);

    controller.pauseForeground();
    expect(scheduler.activePeriods, isEmpty);
    scheduler.fireCancelledCallbacks();
    await _flush();
    expect(api.statusCalls, 2);

    now = now.add(const Duration(minutes: 1));
    controller.resumeForeground();
    await _flush();
    expect(api.statusCalls, 3);
    expect(controller.lastUpdatedAt, now);
    expect(scheduler.activePeriods, [const Duration(seconds: 10)]);
  });

  test(
    'latest of many overlapping refreshes is the only response published',
    () async {
      const requestCount = 64;
      final pending = List.generate(
        requestCount,
        (_) => Completer<GomokuStatus>(),
      );
      var next = 0;
      final api = _FakeHomeApi()..onStatus = () => pending[next++].future;
      final controller = _controller(api, now: () => now);
      final revisions = <int>[];
      controller.addListener(() {
        final state = controller.status;
        if (state is GomokuActiveStatus) revisions.add(state.match.revision);
      });

      final requests = List.generate(requestCount, (_) => controller.refresh());
      expect(api.statusCalls, requestCount);
      pending.last.complete(_active(revision: requestCount - 1));
      await requests.last;
      for (var index = requestCount - 2; index >= 0; index -= 1) {
        pending[index].complete(_active(revision: index));
      }
      await Future.wait(requests);

      expect((controller.status as GomokuActiveStatus).match.revision, 63);
      expect(revisions, [63]);
    },
  );

  test('dispose cancels polling and late completions never notify', () async {
    final pending = Completer<GomokuStatus>();
    final scheduler = _FakeScheduler();
    final api = _FakeHomeApi()..onStatus = () => pending.future;
    final controller = _controller(api, scheduler: scheduler, now: () => now);
    var notifications = 0;
    controller.addListener(() => notifications += 1);
    controller.start();
    final beforeDispose = notifications;

    controller.dispose();
    expect(scheduler.activePeriods, isEmpty);
    pending.complete(const GomokuIdleStatus());
    await _flush();
    scheduler.fireCancelledCallbacks();
    await _flush();

    expect(notifications, beforeDispose);
    expect(api.statusCalls, 1);
  });

  test('opening an active match launches then refreshes immediately', () async {
    final trace = <String>[];
    final api = _FakeHomeApi()
      ..onStatus = () async {
        trace.add('status');
        return _active(revision: 4);
      }
      ..onTicket = (id) async {
        trace.add('ticket:$id');
        return _ticket(id, now);
      };
    final launcher = _FakeLauncher(trace);
    final controller = _controller(api, launcher: launcher, now: () => now);
    await controller.refresh();
    trace.clear();

    final error = await controller.openActiveMatch();

    expect(error, isNull);
    expect(trace, ['ticket:$matchId', 'launch:$matchId', 'status']);
    expect(controller.isLaunching, isFalse);
  });

  test(
    'a pending launch blocks cancellation through the shared mutation',
    () async {
      final launched = Completer<void>();
      final api = _FakeHomeApi()
        ..onStatus = () async {
          return _active(revision: 0);
        }
        ..onTicket = (id) async {
          return _ticket(id, now);
        }
        ..onCancel = (_) => Future<void>.error(
          StateError('cancel must not run while launch is pending'),
        );
      final launcher = _FakeLauncher(<String>[])
        ..onLaunch = (_) => launched.future;
      final controller = _controller(api, launcher: launcher, now: () => now);
      await controller.refresh();

      final opening = controller.openActiveMatch();
      await _flush();
      final blockedCancel = controller.cancelActiveMatch();

      expect(identical(opening, blockedCancel), isTrue);
      expect(controller.isLaunching, isTrue);
      expect(controller.isCancelling, isFalse);
      expect(controller.canCancel, isFalse);
      expect(api.cancelCalls, 0);

      launched.complete();
      expect(await opening, isNull);
      expect(await blockedCancel, isNull);
      expect(api.cancelCalls, 0);
    },
  );

  test(
    'a pending cancel blocks launch and deduplicates cancellation',
    () async {
      final cancelled = Completer<void>();
      var didCancel = false;
      final api = _FakeHomeApi()
        ..onStatus = () async {
          return didCancel ? const GomokuIdleStatus() : _active(revision: 0);
        }
        ..onTicket = (id) {
          return Future<GomokuLaunchTicket>.error(
            StateError('ticket must not be requested while cancel is pending'),
          );
        }
        ..onCancel = (_) async {
          await cancelled.future;
          didCancel = true;
        };
      final controller = _controller(api, now: () => now);
      await controller.refresh();

      final cancelling = controller.cancelActiveMatch();
      final duplicate = controller.cancelActiveMatch();
      final blockedOpen = controller.openActiveMatch();

      expect(identical(cancelling, duplicate), isTrue);
      expect(identical(cancelling, blockedOpen), isTrue);
      expect(controller.isCancelling, isTrue);
      expect(controller.isLaunching, isFalse);
      expect(api.ticketCalls, 0);

      cancelled.complete();
      expect(await cancelling, isNull);
      expect(await blockedOpen, isNull);
      expect(api.cancelCalls, 1);
      expect(controller.status, isA<GomokuIdleStatus>());
    },
  );

  test(
    'concurrent create taps share one mutation and the unified openMatch',
    () async {
      final create = Completer<CreatedGomokuMatch>();
      final trace = <String>[];
      final api = _FakeHomeApi()
        ..onCreate = (id) {
          trace.add('create:$id');
          return create.future;
        }
        ..onTicket = (id) async {
          trace.add('ticket:$id');
          return _ticket(id, now);
        }
        ..onStatus = () async {
          trace.add('status');
          return _active();
        };
      final controller = _controller(
        api,
        launcher: _FakeLauncher(trace),
        now: () => now,
      );

      final first = controller.createAndOpen(opponentId);
      final second = controller.createAndOpen(opponentId);
      expect(identical(first, second), isTrue);
      expect(controller.isCreating, isTrue);
      create.complete(const CreatedGomokuMatch(id: matchId, gameId: 'gomoku'));

      expect(await first, isNull);
      expect(trace, [
        'create:$opponentId',
        'ticket:$matchId',
        'launch:$matchId',
        'status',
      ]);
      expect(controller.isCreating, isFalse);
    },
  );

  test(
    'launcher failure after create refetches the recoverable active match',
    () async {
      final api = _FakeHomeApi()
        ..onCreate = (_) async {
          return const CreatedGomokuMatch(id: matchId, gameId: 'gomoku');
        }
        ..onTicket = (id) async {
          return _ticket(id, now);
        }
        ..onStatus = () async {
          return _active();
        };
      final launcher = _FakeLauncher(<String>[])
        ..error = const GameLaunchException('launch_failed');
      final controller = _controller(api, launcher: launcher, now: () => now);

      final error = await controller.createAndOpen(opponentId);

      expect(error?.code, 'launch_failed');
      expect(error?.message, '无法启动游戏，请重试');
      expect(controller.status, isA<GomokuActiveStatus>());
      expect(controller.isCreating, isFalse);
      expect(api.statusCalls, 1);
    },
  );

  test(
    'cancel is available only at revision zero and uses server errors',
    () async {
      final api = _FakeHomeApi()
        ..onStatus = () async => const GomokuIdleStatus();
      final controller = _controller(api, now: () => now);

      await controller.refresh();
      expect(controller.canCancel, isFalse);
      expect((await controller.cancelActiveMatch())?.code, 'invalid_state');
      expect(api.cancelCalls, 0);

      api.onStatus = () async => _active(revision: 0);
      await controller.refresh();
      expect(controller.canCancel, isTrue);
      api.onCancel = (_) => Future<void>.error(
        const ApiError(code: 'match_not_cancellable', message: '对局无法取消'),
      );

      final error = await controller.cancelActiveMatch();

      expect(error?.code, 'match_not_cancellable');
      expect(error?.message, '对局无法取消');
      expect(controller.status, isA<GomokuActiveStatus>());
    },
  );

  test(
    'successful cancellation refreshes to idle without local revision guesses',
    () async {
      var cancelled = false;
      final api = _FakeHomeApi()
        ..onStatus = () async {
          return cancelled ? const GomokuIdleStatus() : _active(revision: 0);
        }
        ..onCancel = (_) async {
          cancelled = true;
        };
      final controller = _controller(api, now: () => now);
      await controller.refresh();

      final error = await controller.cancelActiveMatch();

      expect(error, isNull);
      expect(controller.status, isA<GomokuIdleStatus>());
      expect(api.cancelCalls, 1);
      expect(api.statusCalls, 2);
    },
  );

  test(
    'cancel completion owns a newer refresh than intervening work',
    () async {
      final cancelBarrier = Completer<void>();
      final intervening = Completer<GomokuStatus>();
      final authoritative = Completer<GomokuStatus>();
      var statusCall = 0;
      final api = _FakeHomeApi()
        ..onStatus = () {
          return switch (++statusCall) {
            1 => Future.value(_active(revision: 0)),
            2 => intervening.future,
            3 => authoritative.future,
            _ => Future.error(StateError('unexpected status call')),
          };
        }
        ..onCancel = (_) => cancelBarrier.future;
      final controller = _controller(api, now: () => now);
      await controller.refresh();

      final cancelling = controller.cancelActiveMatch();
      final olderRefresh = controller.refresh();
      cancelBarrier.complete();
      await _flush();
      expect(api.statusCalls, 3);

      authoritative.complete(const GomokuIdleStatus());
      expect(await cancelling, isNull);
      intervening.complete(_active(revision: 99));
      await olderRefresh;

      expect(controller.status, isA<GomokuIdleStatus>());
    },
  );

  test(
    'launch completion owns a newer refresh than intervening work',
    () async {
      final launchBarrier = Completer<void>();
      final intervening = Completer<GomokuStatus>();
      final authoritative = Completer<GomokuStatus>();
      var statusCall = 0;
      final api = _FakeHomeApi()
        ..onStatus = () {
          return switch (++statusCall) {
            1 => Future.value(_active(revision: 0)),
            2 => intervening.future,
            3 => authoritative.future,
            _ => Future.error(StateError('unexpected status call')),
          };
        }
        ..onTicket = (id) async {
          return _ticket(id, now);
        };
      final launcher = _FakeLauncher(<String>[])
        ..onLaunch = (_) => launchBarrier.future;
      final controller = _controller(api, launcher: launcher, now: () => now);
      await controller.refresh();

      final opening = controller.openActiveMatch();
      await _flush();
      final olderRefresh = controller.refresh();
      launchBarrier.complete();
      await _flush();
      expect(api.statusCalls, 3);

      authoritative.complete(_active(revision: 2));
      expect(await opening, isNull);
      intervening.complete(_active(revision: 99));
      await olderRefresh;

      expect((controller.status as GomokuActiveStatus).match.revision, 2);
    },
  );

  test(
    'create completion owns a newer refresh than intervening work',
    () async {
      final createBarrier = Completer<CreatedGomokuMatch>();
      final launchReached = Completer<void>();
      final intervening = Completer<GomokuStatus>();
      final authoritative = Completer<GomokuStatus>();
      var statusCall = 0;
      final api = _FakeHomeApi()
        ..onStatus = () {
          return switch (++statusCall) {
            1 => Future.value(const GomokuIdleStatus()),
            2 => intervening.future,
            3 => authoritative.future,
            _ => Future.error(StateError('unexpected status call')),
          };
        }
        ..onCreate = (_) {
          return createBarrier.future;
        }
        ..onTicket = (id) async {
          return _ticket(id, now);
        };
      final launcher = _FakeLauncher(<String>[])
        ..onLaunch = (_) async {
          launchReached.complete();
        };
      final controller = _controller(api, launcher: launcher, now: () => now);
      await controller.refresh();

      final creating = controller.createAndOpen(opponentId);
      final olderRefresh = controller.refresh();
      createBarrier.complete(
        const CreatedGomokuMatch(id: matchId, gameId: 'gomoku'),
      );
      await launchReached.future;
      await _flush();
      expect(api.statusCalls, 3);

      authoritative.complete(_active(revision: 0));
      expect(await creating, isNull);
      intervening.complete(const GomokuIdleStatus());
      await olderRefresh;

      expect(controller.status, isA<GomokuActiveStatus>());
    },
  );

  test(
    'disposing a pending mutation prevents sync and later mutations',
    () async {
      final launchBarrier = Completer<void>();
      final api = _FakeHomeApi()
        ..onStatus = () async {
          return _active(revision: 0);
        }
        ..onTicket = (id) async {
          return _ticket(id, now);
        };
      final launcher = _FakeLauncher(<String>[])
        ..onLaunch = (_) => launchBarrier.future;
      final controller = _controller(api, launcher: launcher, now: () => now);
      await controller.refresh();
      var notifications = 0;
      controller.addListener(() => notifications += 1);

      final opening = controller.openActiveMatch();
      await _flush();
      final beforeDispose = notifications;
      controller.dispose();
      launchBarrier.complete();

      expect(await opening, isNull);
      expect(notifications, beforeDispose);
      expect(api.statusCalls, 1);
      expect((await controller.cancelActiveMatch())?.code, 'invalid_state');
      expect(api.cancelCalls, 0);
    },
  );

  test('newer refresh cannot leave superseded action flags stuck', () async {
    final create = Completer<CreatedGomokuMatch>();
    final launch = Completer<void>();
    final cancel = Completer<void>();
    final api = _FakeHomeApi()
      ..onStatus = () async {
        return _active(revision: 0);
      }
      ..onCreate = (_) {
        return create.future;
      }
      ..onTicket = (id) async {
        return _ticket(id, now);
      }
      ..onCancel = (_) {
        return cancel.future;
      };
    final launcher = _FakeLauncher(<String>[])..onLaunch = (_) => launch.future;
    final controller = _controller(api, launcher: launcher, now: () => now);
    await controller.refresh();

    final creating = controller.createAndOpen(opponentId);
    expect(controller.isCreating, isTrue);
    await controller.refresh();
    create.complete(const CreatedGomokuMatch(id: matchId, gameId: 'gomoku'));
    await _flush();
    launch.complete();
    await creating;
    expect(controller.isCreating, isFalse);

    final launchAgain = Completer<void>();
    launcher.onLaunch = (_) => launchAgain.future;
    final opening = controller.openActiveMatch();
    expect(controller.isLaunching, isTrue);
    await controller.refresh();
    launchAgain.complete();
    await opening;
    expect(controller.isLaunching, isFalse);

    final cancelling = controller.cancelActiveMatch();
    expect(controller.isCancelling, isTrue);
    await controller.refresh();
    cancel.complete();
    await cancelling;
    expect(controller.isCancelling, isFalse);
  });
}

HomeController _controller(
  _FakeHomeApi api, {
  _FakeLauncher? launcher,
  HomePollScheduler? scheduler,
  required DateTime Function() now,
}) => HomeController(
  repository: GomokuRepository(
    api: api,
    gameLauncher: launcher ?? _FakeLauncher(<String>[]),
    apiBaseUri: Uri.parse('https://gamebox.test'),
    now: now,
  ),
  scheduler: scheduler,
  now: now,
);

GomokuActiveStatus _active({int revision = 0}) => GomokuActiveStatus(
  match: GomokuActiveMatch(
    id: '33333333-3333-4333-8333-333333333333',
    opponent: const GomokuOpponentIdentity(
      id: '22222222-2222-4222-8222-222222222222',
      nickname: '小猫',
    ),
    color: GomokuColor.black,
    revision: revision,
  ),
);

GomokuLaunchTicket _ticket(String id, DateTime now) => GomokuLaunchTicket(
  matchId: id,
  gameId: 'gomoku',
  launchTicket: 'launch-ticket',
  expiresAt: now.add(const Duration(minutes: 1)),
);

Future<void> _flush() async {
  await Future<void>.value();
  await Future<void>.value();
}

final class _FakeScheduler implements HomePollScheduler {
  final List<_FakeScheduledCall> _calls = [];

  List<Duration> get activePeriods => [
    for (final call in _calls)
      if (!call.cancelled) call.period,
  ];

  @override
  HomeScheduledCall schedulePeriodic(
    Duration period,
    void Function() callback,
  ) {
    final call = _FakeScheduledCall(period, callback);
    _calls.add(call);
    return call;
  }

  void fire() {
    for (final call in List<_FakeScheduledCall>.of(_calls)) {
      if (!call.cancelled) call.callback();
    }
  }

  void fireCancelledCallbacks() {
    for (final call in List<_FakeScheduledCall>.of(_calls)) {
      if (call.cancelled) call.callback();
    }
  }
}

final class _FakeScheduledCall implements HomeScheduledCall {
  _FakeScheduledCall(this.period, this.callback);

  final Duration period;
  final void Function() callback;
  bool cancelled = false;

  @override
  void cancel() => cancelled = true;
}

final class _FakeLauncher implements GameLauncher {
  _FakeLauncher(this.trace);

  final List<String> trace;
  Object? error;
  Future<void> Function(GameLaunchRequest request)? onLaunch;

  @override
  Future<void> launch(GameLaunchRequest request) async {
    trace.add('launch:${request.matchId}');
    if (error != null) throw error!;
    await onLaunch?.call(request);
  }

  @override
  Future<void> launchHostSmoke() =>
      Future<void>.error(StateError('unexpected host smoke'));
}

final class _FakeHomeApi implements HomeApi {
  Future<GomokuStatus> Function()? onStatus;
  Future<CreatedGomokuMatch> Function(String id)? onCreate;
  Future<GomokuLaunchTicket> Function(String id)? onTicket;
  Future<void> Function(String id)? onCancel;
  int statusCalls = 0;
  int cancelCalls = 0;
  int createCalls = 0;
  int ticketCalls = 0;

  @override
  Future<GomokuStatus> fetchStatus() {
    statusCalls += 1;
    return onStatus?.call() ??
        Future<GomokuStatus>.error(StateError('unexpected status'));
  }

  @override
  Future<CreatedGomokuMatch> createMatch(String opponentId) {
    createCalls += 1;
    return onCreate?.call(opponentId) ??
        Future<CreatedGomokuMatch>.error(StateError('unexpected create'));
  }

  @override
  Future<GomokuLaunchTicket> createLaunchTicket(String matchId) {
    ticketCalls += 1;
    return onTicket?.call(matchId) ??
        Future<GomokuLaunchTicket>.error(StateError('unexpected ticket'));
  }

  @override
  Future<void> cancelMatch(String matchId) {
    cancelCalls += 1;
    return onCancel?.call(matchId) ??
        Future<void>.error(StateError('unexpected cancel'));
  }

  @override
  Future<List<GomokuOpponent>> fetchOpponents() async => const [];
}
