import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../design_system/generated/gamebox_tokens.g.dart';
import 'scratch_controller.dart';

enum CardDrawPhase {
  idle,
  saving,
  revealing,
  celebrating,
  returning,
  settled,
  collecting,
  failed,
}

/// Storage owns awards; reveal and result feedback completion own pacing.
/// Repeated input is ignored until the entire presentation has finished.
final class CardDrawFlow extends ChangeNotifier {
  CardDrawFlow(this.collection) : current = collection.lastResult;
  final ScratchController collection;
  CardDrawResult? current, _pending;
  final recent = <CardDrawResult>[];
  CardDrawPhase phase = CardDrawPhase.idle;
  bool _disposed = false, _foreground = true;
  Timer? _timer;
  bool get canDraw =>
      !_disposed &&
      _foreground &&
      collection.interactive &&
      (phase == CardDrawPhase.idle || phase == CardDrawPhase.settled);
  static final celebrationDuration = GameboxTokens.motion.slow * 3;
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void primary() {
    if (!canDraw) return;
    if (current == null) {
      unawaited(_draw());
    } else {
      _advance();
    }
  }

  Future<void> _draw() async {
    if (_disposed || !_foreground) return;
    phase = CardDrawPhase.saving;
    _changed();
    final receipt = await collection.draw();
    if (_disposed) return;
    if (receipt == null) {
      phase = collection.error == null
          ? CardDrawPhase.idle
          : CardDrawPhase.failed;
      _changed();
      return;
    }
    _pending = receipt;
    if (collection.unsaved || collection.error != null) {
      phase = CardDrawPhase.failed;
      _changed();
      return;
    }
    _present(receipt);
  }

  void _present(CardDrawResult receipt) {
    _pending = null;
    current = receipt;
    phase = _foreground ? CardDrawPhase.revealing : CardDrawPhase.settled;
    _changed();
  }

  Future<void> retry() async {
    await collection.retry();
    if (_disposed || !collection.interactive || collection.unsaved) return;
    if (_pending case final receipt?) {
      _present(receipt);
    } else {
      current = collection.lastResult;
      phase = CardDrawPhase.idle;
      _changed();
    }
  }

  void finishReveal() {
    if (_disposed || phase != CardDrawPhase.revealing) return;
    _timer?.cancel();
    if (current?.winning == true && _foreground) {
      phase = CardDrawPhase.celebrating;
      _timer = Timer(celebrationDuration, () {
        phase = CardDrawPhase.returning;
        _changed();
        // Keep input locked while the success label leaves the button.
        _timer = Timer(GameboxTokens.motion.standard, () {
          phase = CardDrawPhase.settled;
          _changed();
        });
      });
    } else {
      phase = CardDrawPhase.settled;
    }
    _changed();
  }

  void _advance() {
    if (_disposed || !_foreground || !collection.interactive) return;
    _timer?.cancel();
    phase = CardDrawPhase.collecting;
    _changed();
    _timer = Timer(GameboxTokens.motion.standard, () {
      if (_disposed || !_foreground) return;
      if (current case final receipt?) {
        if (receipt.winning &&
            (recent.isEmpty || recent.first.serial != receipt.serial)) {
          recent.insert(0, receipt);
          if (recent.length > 6) recent.removeLast();
        }
      }
      unawaited(_draw());
    });
  }

  void suspend() {
    _foreground = false;
    _timer?.cancel();
    if (phase != CardDrawPhase.saving && phase != CardDrawPhase.failed)
      phase = CardDrawPhase.settled;
    _changed();
  }

  void resume() {
    _foreground = true;
    _changed();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
