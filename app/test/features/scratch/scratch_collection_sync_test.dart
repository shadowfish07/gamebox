import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/features/scratch/scratch_collection_sync.dart';
import 'package:gamebox/features/scratch/scratch_controller.dart';

import 'scratch_controller_test.dart' show MemoryScratchStore;
import 'scratch_social_test.dart' show FakeSocial;

class SyncApi extends FakeSocial {
  final snapshots = <List<int>>[];
  bool offline = false;
  Completer<void>? upload;
  @override
  Future<void> sync(List<int> counts) async {
    snapshots.add(List.of(counts));
    await upload?.future;
    if (offline) throw StateError('offline');
  }
}

void main() {
  testWidgets(
    'restored collection and new wins auto sync; unchanged state does not upload',
    (tester) async {
      final c = ScratchController(store: MemoryScratchStore(), random: () => 0);
      final api = SyncApi();
      final sync = ScratchCollectionSync(c, api);
      expect(api.snapshots, isEmpty);
      await c.load();
      await tester.pump();
      expect(api.snapshots.length, 1);
      await c.revealAll();
      await tester.pump();
      expect(api.snapshots.last, c.counts);
      expect(api.snapshots.last.reduce((a, b) => a + b), 1);
      await sync.sync();
      expect(api.snapshots.length, 2);
      sync.dispose();
      c.dispose();
    },
  );
  testWidgets(
    'offline retries latest state; serial requests converge after changes during upload',
    (tester) async {
      final c = ScratchController(store: MemoryScratchStore(), random: () => 0);
      await c.load();
      final api = SyncApi()..offline = true;
      final sync = ScratchCollectionSync(c, api);
      await tester.pump();
      api.offline = false;
      api.upload = Completer<void>();
      await tester.pump(const Duration(seconds: 2));
      expect(api.snapshots.length, 2);
      await c.revealAll();
      expect(api.snapshots.length, 2);
      api.upload!.complete();
      await tester.pump();
      expect(api.snapshots.length, 3);
      expect(api.snapshots.last, c.counts);
      sync.dispose();
      c.dispose();
      await tester.pump(const Duration(minutes: 2));
      expect(api.snapshots.length, 3);
    },
  );
  testWidgets('guest and unreadable saves never overwrite remote collection', (
    tester,
  ) async {
    final c = ScratchController(store: MemoryScratchStore());
    await c.load();
    final api = SyncApi()..canSync = false;
    final sync = ScratchCollectionSync(c, api);
    await tester.pump();
    expect(api.snapshots, isEmpty);
    api.canSync = true;
    c.unsaved = true;
    await sync.sync();
    expect(api.snapshots, isEmpty);
    c.unsaved = false;
    c.error = 'read failed';
    await sync.sync();
    expect(api.snapshots, isEmpty);
    sync.dispose();
    c.dispose();
  });
}
