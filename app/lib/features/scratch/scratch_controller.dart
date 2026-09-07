import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'scratch_catalog.dart';
export 'scratch_catalog.dart';

enum ScratchMode {
  photo('拍立得', 1),
  paws('四枚爪印', 4),
  career('职业证', 2);

  const ScratchMode(this.label, this.regions);
  final String label;
  final int regions;
}

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

ScratchCat drawScratchCat(double Function() random) {
  final roll = random();
  final tier = roll < .7
      ? 0
      : roll < .94
      ? 1
      : roll < .995
      ? 2
      : 3;
  final pool = scratchCats.where((cat) => cat.rarity == tier).toList();
  return pool[(random() * pool.length).floor()];
}

final class ScratchMask extends ChangeNotifier {
  final List<List<double>> strokes = [];
  final _cells = List.filled(1024, false);
  var _covered = 0;
  double get coverage => _covered / 1024;
  void erase(
    double x0,
    double y0,
    double x1,
    double y1, {
    double radius = .085,
  }) {
    final before = _covered;
    final dx = x1 - x0, dy = y1 - y0;
    final length = dx * dx + dy * dy;
    for (var y = 0; y < 32; y++) {
      for (var x = 0; x < 32; x++) {
        final i = y * 32 + x;
        if (_cells[i]) continue;
        final px = (x + .5) / 32, py = (y + .5) / 32;
        final t = length == 0
            ? 0.0
            : (((px - x0) * dx + (py - y0) * dy) / length).clamp(0.0, 1.0);
        final ax = px - x0 - t * dx, ay = py - y0 - t * dy;
        if (ax * ax + ay * ay <= radius * radius) {
          _cells[i] = true;
          _covered++;
        }
      }
    }
    if (_covered > before) {
      strokes.add([x0, y0, x1, y1, radius]);
      notifyListeners();
    }
  }
}

final class ScratchController extends ChangeNotifier {
  ScratchController({required this.store, double Function()? random})
    : random = random ?? Random.secure().nextDouble;
  final ScratchStore store;
  final double Function() random;
  final counts = List.filled(24, 0);
  final firstFound = List<String?>.filled(24, null);
  final favorites = <int>[];
  final opened = <int>{};
  List<ScratchMask> masks = List.generate(4, (_) => ScratchMask());
  ScratchMode mode = ScratchMode.photo;
  ScratchCat cat = scratchCats.first;
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
      if (raw != null) {
        _restore(raw);
      } else {
        cat = drawScratchCat(random);
      }
      loading = false;
      if (raw == null) {
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
    'version': 1,
    'counts': counts,
    'firstFound': firstFound,
    'favorites': favorites,
    'cat': cat.index,
    'mode': mode.index,
    'claimed': claimed,
    'isNew': isNew,
    'serial': serial,
    'opened': opened.toList(),
    'strokes': masks.map((mask) => mask.strokes).toList(),
  };

  void _restore(String raw) {
    final data = jsonDecode(raw) as Map<String, dynamic>;
    final savedCounts = (data['counts'] as List).cast<int>();
    final savedFirst = (data['firstFound'] as List).cast<String?>();
    final savedFavorites = (data['favorites'] as List).cast<int>();
    final savedOpened = (data['opened'] as List).cast<int>().toSet();
    final catIndex = data['cat'] as int, modeIndex = data['mode'] as int;
    final savedClaimed = data['claimed'] as bool;
    if (data['version'] != 1 ||
        savedCounts.length != 24 ||
        savedFirst.length != 24 ||
        savedCounts.any((v) => v < 0) ||
        catIndex < 0 ||
        catIndex >= 24 ||
        modeIndex < 0 ||
        modeIndex >= 3 ||
        savedFavorites.length > 6 ||
        savedFavorites.toSet().length != savedFavorites.length ||
        savedFavorites.any((i) => i < 0 || i >= 24 || savedCounts[i] == 0) ||
        savedOpened.any(
          (i) => i < 0 || i >= ScratchMode.values[modeIndex].regions,
        ) ||
        (modeIndex == 2 &&
            savedOpened.contains(1) &&
            !savedOpened.contains(0)) ||
        (savedClaimed &&
            (savedCounts[catIndex] == 0 ||
                savedOpened.length != ScratchMode.values[modeIndex].regions)) ||
        data['serial'] is! int ||
        (data['serial'] as int) < 1 ||
        data['isNew'] is! bool) {
      throw const FormatException('Invalid scratch collection');
    }
    for (var i = 0; i < 24; i++) {
      if (savedCounts[i] > 0 &&
          (savedFirst[i] == null ||
              DateTime.tryParse(savedFirst[i]!) == null)) {
        throw const FormatException('Invalid collection date');
      }
    }
    final rawMasks = data['strokes'] as List;
    if (rawMasks.length != 4) throw const FormatException('Invalid masks');
    final restoredMasks = List.generate(4, (_) => ScratchMask());
    try {
      for (var i = 0; i < 4; i++) {
        final segments = rawMasks[i] as List;
        if (segments.length > 1024) {
          throw const FormatException('Too many strokes');
        }
        for (final item in segments) {
          final segment = (item as List)
              .cast<num>()
              .map((n) => n.toDouble())
              .toList();
          if (segment.length != 5 ||
              segment.any((n) => !n.isFinite || n < 0 || n > 1)) {
            throw const FormatException('Invalid stroke');
          }
          restoredMasks[i].erase(
            segment[0],
            segment[1],
            segment[2],
            segment[3],
            radius: segment[4],
          );
        }
      }
    } catch (_) {
      for (final mask in restoredMasks) {
        mask.dispose();
      }
      rethrow;
    }
    for (final mask in masks) {
      mask.dispose();
    }
    masks = restoredMasks;
    counts.setAll(0, savedCounts);
    firstFound.setAll(0, savedFirst);
    favorites
      ..clear()
      ..addAll(savedFavorites);
    opened
      ..clear()
      ..addAll(savedOpened);
    cat = scratchCats[catIndex];
    mode = ScratchMode.values[modeIndex];
    claimed = savedClaimed;
    isNew = data['isNew'] as bool;
    serial = data['serial'] as int;
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

  void _clearMasks() {
    // Keep notifier identities stable while their painters unmount/rebuild.
    for (final mask in masks) {
      mask.strokes.clear();
      mask._cells.fillRange(0, 1024, false);
      mask._covered = 0;
    }
    opened.clear();
  }

  Future<void> next() async {
    if (!interactive || !claimed) return;
    cat = drawScratchCat(random);
    serial++;
    claimed = false;
    isNew = false;
    _clearMasks();
    await persist();
  }

  Future<void> changeMode(ScratchMode value) async {
    if (!interactive || value == mode) return;
    mode = value;
    if (claimed) {
      cat = drawScratchCat(random);
      serial++;
      claimed = false;
      isNew = false;
    }
    _clearMasks();
    await persist();
  }

  Future<void> open(int region) async {
    if (loading ||
        error != null ||
        claimed ||
        region < 0 ||
        region >= mode.regions ||
        opened.contains(region)) {
      return;
    }
    if (mode == ScratchMode.career && region == 1 && !opened.contains(0)) {
      return;
    }
    opened.add(region);
    if (opened.length == mode.regions) {
      claimed = true;
      isNew = counts[cat.index] == 0;
      counts[cat.index]++;
      firstFound[cat.index] ??= DateTime.now().toIso8601String();
    }
    await persist();
  }

  Future<void> revealAll() async {
    if (!interactive || claimed) return;
    for (var i = 0; i < mode.regions; i++) {
      await open(i);
      if (error != null) break;
    }
  }

  Future<String> favorite(int index) async {
    if (index < 0 || index >= 24 || counts[index] == 0) return '先通过刮奖获得这只猫猫';
    if (!interactive) return '请等待收藏保存完成';
    if (favorites.contains(index)) {
      favorites.remove(index);
      await persist();
      return '已从展柜取下';
    }
    if (favorites.length == 6) return '展柜已满，请先取下一只猫猫';
    favorites.add(index);
    await persist();
    return '已放入展柜';
  }

  @override
  void dispose() {
    _disposed = true;
    for (final mask in masks) {
      mask.dispose();
    }
    super.dispose();
  }
}
