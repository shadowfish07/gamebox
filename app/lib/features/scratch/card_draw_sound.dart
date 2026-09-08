import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// A preloaded, single-use reveal cue owned by one card animation.
class CardDrawSound {
  CardDrawSound({int rarity = 0})
    : _asset = switch (rarity) {
        1 => 'audio/card-draw/rare.wav',
        2 => 'audio/card-draw/epic.wav',
        3 => 'audio/card-draw/legendary.wav',
        _ => 'audio/kenney-casino/card-place-3.ogg',
      };

  final String _asset;
  AudioPlayer? _player;
  Future<void>? _ready;
  bool _disposed = false;
  bool _available = false;

  void prepare() {
    _ready ??= _prepare();
  }

  Future<void> _prepare() async {
    try {
      final player = _player = AudioPlayer();
      await player.setAudioContext(
        AudioContext(
          android: const AudioContextAndroid(
            contentType: AndroidContentType.sonification,
            usageType: AndroidUsageType.assistanceSonification,
            audioFocus: AndroidAudioFocus.none,
          ),
        ),
      );
      await player.setReleaseMode(ReleaseMode.stop);
      await player.setSource(AssetSource(_asset));
      _available = true;
    } on Exception catch (error) {
      // Optional feedback must never interrupt collection or saving.
      debugPrint('Card reveal audio unavailable: $error');
    }
  }

  Future<void> play() async {
    prepare();
    await _ready;
    if (_disposed || !_available) return;
    try {
      await _player?.resume();
    } on Exception catch (error) {
      debugPrint('Card reveal audio unavailable: $error');
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _ready;
    try {
      await _player?.dispose();
    } on Exception catch (error) {
      debugPrint('Card reveal audio cleanup failed: $error');
    }
  }
}
