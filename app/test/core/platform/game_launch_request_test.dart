import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/core/platform/game_launch_request.dart';

void main() {
  const validMatchId = '11111111-1111-4111-8111-111111111111';

  GameLaunchRequest requestFor({
    String matchId = validMatchId,
    String wsUrl = 'wss://games.example.com/matches',
  }) {
    return GameLaunchRequest(
      gameId: 'gomoku',
      matchId: matchId,
      launchTicket: '--opaque-ticket',
      wsUrl: wsUrl,
    );
  }

  test('accepts the Godot launch-config UUID parity table', () {
    for (final matchId in [
      validMatchId,
      '550e8400-e29b-41d4-a716-446655440000',
    ]) {
      expect(() => requestFor(matchId: matchId), returnsNormally);
    }
  });

  test('rejects invalid UUIDs from the Godot launch-config parity table', () {
    for (final matchId in [
      '',
      'm1',
      '550e8400-e29b-41d4-a716-446655440000'.toUpperCase(),
      '00000000-0000-0000-0000-000000000000',
      '11111111-1111-6111-8111-111111111111',
      '11111111-1111-4111-7111-111111111111',
      '111111111111-4111-8111-111111111111',
    ]) {
      expect(() => requestFor(matchId: matchId), throwsArgumentError);
    }
  });

  test('accepts the Godot launch-config websocket URL parity table', () {
    for (final wsUrl in [
      'ws://10.0.2.2:8080/v1/ws',
      'wss://games.example.com',
      'ws://localhost',
      'ws://192.168.1.1',
      'ws://[2001:db8::1]:8080/v1/ws',
      'wss://games.example.com/path%20segment?mode=fast#anchor',
    ]) {
      expect(() => requestFor(wsUrl: wsUrl), returnsNormally);
    }
  });

  test(
    'rejects invalid websocket URLs from the Godot launch-config parity table',
    () {
      for (final wsUrl in [
        'https://games.example.com',
        'ws://',
        'ftp://games.example.com',
        'not-a-url',
        'ws://host:0',
        'ws://host:99999',
        'ws://host\t/path',
        'ws://host\n/path',
        'ws://[2001:db8::1',
        'ws://[:1:2:3:4:5:6:7:8]',
        'ws://[1:2:3:4:5:6:7:8:]',
        'ws://2001:db8::1',
        'ws://user@host',
        r'ws://host\path',
        'ws://host%2f.example',
        'ws://api..example',
        'ws://-api.example',
        'ws://api-.example',
        'ws://256.0.0.1',
        'ws://[2001:db8::1]:65536',
      ]) {
        expect(() => requestFor(wsUrl: wsUrl), throwsArgumentError);
      }
    },
  );
}
