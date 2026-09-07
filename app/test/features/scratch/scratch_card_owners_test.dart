import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/features/scratch/scratch_card_owners.dart';
import 'package:gamebox/features/scratch/scratch_social_api.dart';

import 'scratch_social_test.dart' show FakeSocial;

class OwnersApi extends FakeSocial {
  bool error = true, empty = false;
  Completer<void>? wait;
  final queries = <String>[];
  @override
  Future<ScratchPlayerPage> list([String after = '', int? card]) async {
    queries.add('$card:$after');
    await wait?.future;
    if (error) throw StateError('offline');
    return ScratchPlayerPage(
      empty
          ? []
          : [
              ScratchPlayer(
                userId: after.isEmpty
                    ? '11111111-1111-4111-8111-111111111111'
                    : '22222222-2222-4222-8222-222222222222',
                nickname: after.isEmpty ? '玩家甲' : '玩家乙',
                counts: List.generate(24, (i) => i == 13 ? 7 : 0),
                updatedAt: DateTime(2026),
              ),
            ],
      after.isEmpty && !empty ? '11111111-1111-4111-8111-111111111111' : '',
    );
  }
}

void main() {
  testWidgets('owners query current card, retry, page and open collection', (
    tester,
  ) async {
    final api = OwnersApi();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ScratchCardOwners(api: api, card: 13),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('暂时无法读取玩家'), findsOneWidget);
    api.error = false;
    api.wait = Completer<void>();
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    api.wait!.complete();
    await tester.pumpAndSettle();
    expect(find.text('玩家甲'), findsOneWidget);
    expect(find.text('7 张'), findsOneWidget);
    await tester.tap(find.text('查看更多玩家'));
    await tester.pumpAndSettle();
    expect(api.queries.last, '13:11111111-1111-4111-8111-111111111111');
    expect(find.text('玩家乙'), findsOneWidget);
    await tester.tap(find.text('玩家甲'));
    await tester.pumpAndSettle();
    expect(find.text('玩家甲的收藏'), findsOneWidget);
  });
  testWidgets('no owners has clear empty state', (tester) async {
    final api = OwnersApi()
      ..error = false
      ..empty = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ScratchCardOwners(api: api, card: 0)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('暂无持有玩家记录'), findsOneWidget);
    expect(find.text('查看更多玩家'), findsNothing);
  });
}
