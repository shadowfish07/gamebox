import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/features/scratch/card_draw_sound.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  Completer<void>? preparing;
  var failSource = false;
  setUp(() {
    calls.clear();
    preparing = null;
    failSource = false;
    for (final path in [
      'audio/kenney-casino/card-place-3.ogg',
      'audio/kenney-jingles/jingles_STEEL16.ogg',
      'audio/kenney-jingles/jingles_STEEL12.ogg',
      'audio/kenney-jingles/jingles_STEEL02.ogg',
    ]) {
      AudioCache.instance.loadedFiles[path] = File('assets/$path').absolute.uri;
    }
    final messenger = binding.defaultBinaryMessenger;
    for (final name in [
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (_) async => null,
      );
    }
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (call) async {
        calls.add(call);
        final id = (call.arguments as Map)['playerId'];
        final events = 'xyz.luan/audioplayers/events/$id';
        if (call.method == 'create') {
          messenger.setMockMethodCallHandler(
            MethodChannel(events),
            (_) async => null,
          );
        }
        if (call.method == 'setSourceUrl') {
          await preparing?.future;
          await messenger.handlePlatformMessage(
            events,
            const StandardMethodCodec().encodeSuccessEnvelope({
              'event': 'audio.onPrepared',
              'value': true,
            }),
            (_) {},
          );
          if (failSource) throw PlatformException(code: 'source_unavailable');
        }
        if (call.method == 'getDuration' || call.method == 'getCurrentPosition')
          return 0;
        return null;
      },
    );
  });

  for (final (rarity, file) in [
    (0, 'kenney-casino/card-place-3.ogg'),
    (1, 'kenney-jingles/jingles_STEEL16.ogg'),
    (2, 'kenney-jingles/jingles_STEEL12.ogg'),
    (3, 'kenney-jingles/jingles_STEEL02.ogg'),
  ]) {
    test(
      'tier $rarity preloads its selected file and releases its player',
      () async {
        final sound = CardDrawSound(rarity: rarity);
        sound.prepare();
        await sound.play();
        expect(
          calls.where((c) => c.method == 'setSourceUrl').single.arguments,
          containsPair('url', endsWith('/assets/audio/$file')),
        );
        expect(calls.where((c) => c.method == 'resume'), hasLength(1));
        await sound.dispose();
        expect(calls.where((c) => c.method == 'dispose'), hasLength(1));
      },
    );
  }

  test('leaving during preparation suppresses delayed playback', () async {
    preparing = Completer<void>();
    final sound = CardDrawSound();
    final playing = sound.play();
    final disposing = sound.dispose();
    preparing!.complete();
    await Future.wait([playing, disposing]);
    expect(calls.where((c) => c.method == 'resume'), isEmpty);
    expect(calls.where((c) => c.method == 'dispose'), hasLength(1));
  });

  test('an unavailable sound remains optional', () async {
    failSource = true;
    final sound = CardDrawSound();
    await sound.play();
    expect(calls.where((c) => c.method == 'resume'), isEmpty);
    await sound.dispose();
  });
}
