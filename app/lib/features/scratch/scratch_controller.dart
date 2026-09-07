import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'scratch_catalog.dart';
export 'scratch_catalog.dart';

abstract interface class ScratchStore {
  Future<String?> read();
  Future<void> write(String value);
}

final class SecureScratchStore implements ScratchStore {
  static const _key = 'gamebox.catScratch.flutter.v1';
  final _storage = const FlutterSecureStorage();
  @override
  Future<String?> read() => _storage.read(key: _key);
  @override
  Future<void> write(String value) => _storage.write(key: _key, value: value);
}

ScratchCollectible drawScratchCollectible(double Function() random) {
  final roll = random();
  final tier = roll < .7
      ? 0
      : roll < .94
      ? 1
      : roll < .995
      ? 2
      : 3;
  final pool = scratchCollectibles.where((cat) => cat.rarity == tier).toList();
  return pool[(random() * pool.length).floor()];
}

/// Immutable presentation receipt; quantities reflect this draw, not a later one.
final class CardDrawResult {
  const CardDrawResult({
    required this.card,
    required this.serial,
    required this.isNew,
    required this.count,
  });
  final ScratchCollectible card;
  final int serial, count;
  final bool isNew;
}

final class ScratchController extends ChangeNotifier {
  ScratchController({required this.store, double Function()? random})
    : random = random ?? Random.secure().nextDouble;
  final ScratchStore store;
  final double Function() random;
  final counts = List.filled(scratchCollectibles.length, 0);
  final firstFound = List<String?>.filled(scratchCollectibles.length, null);
  // Retained to round-trip legacy collections, though the showcase was removed.
  final favorites = <int>[];
  ScratchCollectible cat = scratchCollectibles.first;
  bool claimed = false,
      isNew = false,
      loading = true,
      saving = false,
      unsaved = false;
  bool _disposed = false;
  String? error;
  int serial = 1;
  int get total => counts.fold(0, (a, b) => a + b);
  int get collected => counts.where((count) => count > 0).length;
  bool get interactive => !loading && !saving && error == null;
  CardDrawResult? get lastResult => claimed
      ? CardDrawResult(
          card: cat,
          serial: serial,
          isNew: isNew,
          count: counts[cat.index],
        )
      : null;
  Future<void> _writes = Future.value();
  int _revision = 0;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> load() async {
    loading = true;
    error = null;
    _changed();
    try {
      final raw = await store.read();
      if (_disposed) return;
      final migrated = raw != null ? _restore(raw) : false;
      if (raw == null) cat = drawScratchCollectible(random);
      loading = false;
      if (raw == null || migrated) {
        await persist();
      } else {
        _changed();
      }
    } catch (_) {
      if (_disposed) return;
      loading = false;
      error = '无法读取收藏，原存档已保留。请重试。';
      _changed();
    }
  }

  Map<String, Object?> _snapshot() => {
    'version': 2,
    'counts': counts,
    'firstFound': firstFound,
    'favorites': favorites,
    'cat': cat.index,
    'claimed': claimed,
    'isNew': isNew,
    'serial': serial,
  };

  bool _restore(String raw) {
    final data = jsonDecode(raw) as Map<String, dynamic>;
    final version = data['version'];
    final savedCounts = (data['counts'] as List).cast<int>();
    final savedFirst = (data['firstFound'] as List).cast<String?>();
    final savedFavorites = (data['favorites'] as List).cast<int>();
    final catIndex = data['cat'] as int;
    final savedClaimed = data['claimed'] as bool;
    final savedWinning = version == 1
        ? (data['winning'] as bool? ?? true)
        : true;
    if ((version != 1 && version != 2) ||
        (savedCounts.length != scratchLegacyCatalogSize &&
            savedCounts.length != scratchCollectibles.length) ||
        savedFirst.length != savedCounts.length ||
        savedCounts.any((v) => v < 0) ||
        catIndex < 0 ||
        catIndex >= savedCounts.length ||
        savedFavorites.length > 6 ||
        savedFavorites.toSet().length != savedFavorites.length ||
        savedFavorites.any(
          (i) => i < 0 || i >= savedCounts.length || savedCounts[i] == 0,
        ) ||
        (savedClaimed && savedWinning && savedCounts[catIndex] == 0) ||
        data['serial'] is! int ||
        (data['serial'] as int) < 1 ||
        data['isNew'] is! bool) {
      throw const FormatException('Invalid collection');
    }
    for (var i = 0; i < savedCounts.length; i++) {
      if (savedCounts[i] > 0 &&
          (savedFirst[i] == null ||
              DateTime.tryParse(savedFirst[i]!) == null)) {
        throw const FormatException('Invalid collection date');
      }
    }
    if (version == 1) _validateLegacySurface(data, savedClaimed);
    // Apply only after the entire save validates. A corrupt save is never overwritten.
    counts.fillRange(0, counts.length, 0);
    counts.setAll(0, savedCounts);
    firstFound.fillRange(0, firstFound.length, null);
    firstFound.setAll(0, savedFirst);
    favorites
      ..clear()
      ..addAll(savedFavorites);
    cat = scratchCollectibles[catIndex];
    claimed = savedClaimed && savedWinning;
    isNew = claimed && data['isNew'] as bool;
    serial = data['serial'] as int;
    // Retire an already revealed empty ticket; its stored candidate becomes the
    // next guaranteed draw, awarded only on an explicit draw action.
    if (savedClaimed && !savedWinning) serial++;
    return version == 1 || savedCounts.length != counts.length;
  }

  void _validateLegacySurface(Map<String, dynamic> data, bool savedClaimed) {
    final mode = data['mode'] as int;
    final opened = (data['opened'] as List).cast<int>().toSet();
    if (mode < 0 ||
        mode > 2 ||
        opened.any((i) => i < 0 || i >= [1, 4, 2][mode]) ||
        (mode == 2 && opened.contains(1) && !opened.contains(0)) ||
        (savedClaimed && opened.length != [1, 4, 2][mode])) {
      throw const FormatException('Invalid legacy reveal');
    }
    final masks = data['strokes'] as List;
    if (masks.length != 4) throw const FormatException('Invalid legacy masks');
    for (final mask in masks) {
      final segments = mask as List;
      if (segments.length > 1024)
        throw const FormatException('Too many strokes');
      for (final stroke in segments) {
        final values = (stroke as List).cast<num>();
        if (values.length != 5 ||
            values.any((v) => !v.isFinite || v < 0 || v > 1)) {
          throw const FormatException('Invalid legacy stroke');
        }
      }
    }
  }

  Future<void> persist() {
    if (loading || _disposed) return Future.value();
    final snapshot = jsonEncode(_snapshot());
    final revision = ++_revision;
    saving = true;
    unsaved = true;
    _changed();
    _writes = _writes.then((_) async {
      try {
        await store.write(snapshot);
        if (revision == _revision) {
          saving = false;
          unsaved = false;
          error = null;
          _changed();
        }
      } catch (_) {
        if (revision == _revision) {
          saving = false;
          error = '收藏尚未保存，请重试后继续。';
          _changed();
        }
      }
    });
    return _writes;
  }

  Future<void> retry() => unsaved ? persist() : load();

  /// Commits exactly one guaranteed card. The caller must check [unsaved] before
  /// presenting success; retry saves this same receipt without another award.
  Future<CardDrawResult?> draw() async {
    if (!interactive || _disposed) return null;
    if (claimed) {
      cat = drawScratchCollectible(random);
      serial++;
    }
    claimed = true;
    isNew = counts[cat.index] == 0;
    counts[cat.index]++;
    firstFound[cat.index] ??= DateTime.now().toIso8601String();
    final receipt = lastResult!;
    await persist();
    return receipt;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
