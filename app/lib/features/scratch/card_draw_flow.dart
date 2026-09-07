import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../design_system/generated/gamebox_tokens.g.dart';
import 'scratch_controller.dart';

enum CardDrawPhase { idle, saving, revealing, settled, collecting, failed }

/// Storage owns awards; animation completion owns pacing. A second tap queues
/// at most one card. Navigation/backgrounding cancels it, never a saved award.
final class CardDrawFlow extends ChangeNotifier {
  CardDrawFlow(this.collection) : current = collection.lastResult;
  final ScratchController collection;
  CardDrawResult? current, _pending;
  final recent = <CardDrawResult>[];
  CardDrawPhase phase = CardDrawPhase.idle;
  bool _queued = false, _disposed = false, _foreground = true;
  Timer? _timer;
  bool get queued => _queued;
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void primary() {
    if (!_foreground ||
        _disposed ||
        phase == CardDrawPhase.failed ||
        collection.error != null)
      return;
    if (phase == CardDrawPhase.saving || phase == CardDrawPhase.collecting) {
      _queued = true;
      _changed();
      return;
    }
    if (phase == CardDrawPhase.revealing) {
      _queued = true;
      finishReveal();
      return;
    }
    if (!collection.interactive) return;
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
      _queued = false;
      phase = collection.error == null
          ? CardDrawPhase.idle
          : CardDrawPhase.failed;
      _changed();
      return;
    }
    _pending = receipt;
    if (collection.unsaved || collection.error != null) {
      phase = CardDrawPhase.failed;
      _queued = false;
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
    if (_foreground && _queued) {
      // Give a committed card a readable reveal before consuming the one tap
      // queued during saving. There is no unattended or batch draw mode.
      _timer = Timer(
        receipt.winning && receipt.card.rarity >= 2
            ? GameboxTokens.motion.pageEnter * 5
            : GameboxTokens.motion.pageEnter,
        finishReveal,
      );
    }
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
    phase = CardDrawPhase.settled;
    if (_queued) {
      _advance();
    } else {
      _changed();
    }
  }

  void _advance() {
    if (_disposed || !_foreground || !collection.interactive) return;
    _timer?.cancel();
    _queued = false;
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
    _queued = false;
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
