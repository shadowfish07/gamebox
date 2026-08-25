import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/core/platform/game_launch_request.dart';
import 'package:gamebox/core/platform/game_launcher.dart';
import 'package:gamebox/core/platform/method_channel_game_launcher.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('me.zqydev.gamebox/game_launcher');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('launchGame sends the approved request values exactly once', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    final request = GameLaunchRequest(
      gameId: 'match-three',
      matchId: '550e8400-e29b-41d4-a716-446655440000',
      launchTicket: '--opaque-launch-ticket',
      wsUrl: 'wss://gamebox.example.com/matches/550e8400',
    );

    await MethodChannelGameLauncher().launch(request);

    expect(calls, hasLength(1));
    expect(calls.single.method, 'launchGame');
    expect(calls.single.arguments, {
      'gameId': 'match-three',
      'matchId': '550e8400-e29b-41d4-a716-446655440000',
      'launchTicket': '--opaque-launch-ticket',
      'wsUrl': 'wss://gamebox.example.com/matches/550e8400',
      'source': 'public',
    });
    expect((calls.single.arguments as Map<Object?, Object?>).keys, {
      'gameId',
      'matchId',
      'launchTicket',
      'wsUrl',
      'source',
    });
  });

  test('rejects invalid launch inputs before invoking the channel', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls += 1;
      return null;
    });

    expect(
      () => GameLaunchRequest(
        gameId: '   ',
        matchId: '550e8400-e29b-41d4-a716-446655440000',
        launchTicket: 'ticket',
        wsUrl: 'wss://gamebox.example.com',
      ),
      throwsArgumentError,
    );
    expect(
      () => GameLaunchRequest(
        gameId: 'match-three',
        matchId: 'not-a-uuid',
        launchTicket: 'ticket',
        wsUrl: 'wss://gamebox.example.com',
      ),
      throwsArgumentError,
    );
    expect(
      () => GameLaunchRequest(
        gameId: 'match-three',
        matchId: '550E8400-E29B-41D4-A716-446655440000',
        launchTicket: 'ticket',
        wsUrl: 'wss://gamebox.example.com',
      ),
      throwsArgumentError,
    );
    expect(
      () => GameLaunchRequest(
        gameId: 'match-three',
        matchId: '550e8400-e29b-41d4-a716-446655440000',
        launchTicket: 'ticket',
        wsUrl: 'https://gamebox.example.com',
      ),
      throwsArgumentError,
    );
    expect(
      () => GameLaunchRequest(
        gameId: 'match-three',
        matchId: '550e8400-e29b-41d4-a716-446655440000',
        launchTicket: 'ticket',
        wsUrl: 'wss://',
      ),
      throwsArgumentError,
    );
    expect(
      () => GameLaunchRequest(
        gameId: 'match-three',
        matchId: '550e8400-e29b-41d4-a716-446655440000',
        launchTicket: '   ',
        wsUrl: 'wss://gamebox.example.com',
      ),
      throwsArgumentError,
    );

    expect(calls, 0);
  });

  test(
    'keeps an opaque ticket opaque in failures and accepts leading dashes',
    () async {
      const ticket = '--opaque-launch-ticket';
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'unavailable', message: ticket);
      });
      final request = GameLaunchRequest(
        gameId: 'match-three',
        matchId: '550e8400-e29b-41d4-a716-446655440000',
        launchTicket: ticket,
        wsUrl: 'ws://localhost:8080',
      );

      await expectLater(
        MethodChannelGameLauncher().launch(request),
        throwsA(
          isA<GameLaunchException>().having(
            (error) => error.code,
            'code',
            'unavailable',
          ),
        ),
      );

      try {
        await MethodChannelGameLauncher().launch(request);
      } catch (error) {
        expect(error.toString(), isNot(contains(ticket)));
      }
    },
  );

  test('launchHostSmoke invokes its method without arguments', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });

    await MethodChannelGameLauncher().launchHostSmoke();

    expect(calls, hasLength(1));
    expect(calls.single.method, 'launchHostSmoke');
    expect(calls.single.arguments, isNull);
  });

  test('maps a missing platform handler to a safe launch exception', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw MissingPluginException();
    });

    await expectLater(
      MethodChannelGameLauncher().launchHostSmoke(),
      throwsA(
        isA<GameLaunchException>().having(
          (error) => error.code,
          'code',
          'missing_plugin',
        ),
      ),
    );
  });
}
