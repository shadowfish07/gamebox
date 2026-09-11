import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:gamebox/features/scratch/card_draw_play.dart';
import 'package:gamebox/features/scratch/scratch_controller.dart';
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
      'audio/card-draw/rare.wav',
      'audio/card-draw/epic.wav',
      'audio/card-draw/legendary.wav',
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
    (1, 'card-draw/rare.wav'),
    (2, 'card-draw/epic.wav'),
    (3, 'card-draw/legendary.wav'),
  ]) {
    test(
      'tier $rarity preloads its selected file and releases its player',
      () async {
        final sound = CardDrawSound(rarity: rarity);
        await sound.prepare();
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

  for (var rarity = 0; rarity < 4; rarity++) {
    for (final slowPreparation in [false, true]) {
      testWidgets(
        'tier $rarity reveal cue (slow preparation: $slowPreparation)',
        (tester) async {
          if (slowPreparation) preparing = Completer<void>();
          final haptics = <MethodCall>[];
          binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            (call) async {
              if (call.method == 'HapticFeedback.vibrate') haptics.add(call);
              return null;
            },
          );
          addTearDown(
            () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
              SystemChannels.platform,
              null,
            ),
          );
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: 220,
                    child: CardDrawStage(
                      result: CardDrawResult(
                        card: scratchCollectibles.firstWhere(
                          (card) => card.rarity == rarity,
                        ),
                        serial: 1,
                        isNew: true,
                        count: 1,
                      ),
                      playing: true,
                      collecting: false,
                      waiting: false,
                      onRevealed: () {},
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          await tester.runAsync(() async {
            await Future<void>.delayed(Duration.zero);
          });
          final cueTime = cardRevealDuration(rarity) * .4;
          await tester.pump(cueTime - const Duration(milliseconds: 1));
          expect(calls.where((c) => c.method == 'resume'), isEmpty);
          expect(haptics, isEmpty);
          expect(find.byKey(const Key('scratch-reveal-burst')), findsNothing);
          await tester.pump(const Duration(milliseconds: 2));
          await tester.pump();
          expect(find.byKey(const Key('scratch-reveal-burst')), findsOneWidget);
          expect(
            calls.where((c) => c.method == 'resume'),
            hasLength(slowPreparation ? 0 : 1),
          );
          expect(haptics, hasLength(1));
          if (slowPreparation) {
            preparing!.complete();
            await tester.runAsync(() async {
              await Future<void>.delayed(Duration.zero);
            });
          }
          await tester.pump(cardRevealDuration(rarity));
          expect(
            calls.where((c) => c.method == 'resume'),
            hasLength(slowPreparation ? 0 : 1),
          );
          expect(haptics, hasLength(1));
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        },
      );
    }
  }

  test('preparation after the reveal cue does not play a late sound', () async {
    preparing = Completer<void>();
    final sound = CardDrawSound();
    final ready = sound.prepare();
    final playing = sound.play();
    preparing!.complete();
    await ready;
    await playing;
    expect(calls.where((c) => c.method == 'resume'), isEmpty);
    await sound.dispose();
  });

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
    await sound.prepare();
    await sound.play();
    expect(calls.where((c) => c.method == 'resume'), isEmpty);
    await sound.dispose();
  });
}
