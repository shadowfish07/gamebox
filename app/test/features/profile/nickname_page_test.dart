import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/core/profile/app_profile.dart';
import 'package:gamebox/core/profile/app_profile_store.dart';
import 'package:gamebox/core/profile/nickname_rules.dart';
import 'package:gamebox/features/profile/nickname_page.dart';
import 'package:gamebox/features/profile/profile_controller.dart';

void main() {
  testWidgets('first launch accepts one nickname and reaches saved callback', (
    tester,
  ) async {
    final controller = ProfileController(
      store: _MemoryStore(),
      nicknameRules: const _Rules(),
    );
    await controller.load();
    var saved = false;
    await tester.pumpWidget(
      MaterialApp(
        home: NicknamePage(controller: controller, onSaved: () => saved = true),
      ),
    );

    await tester.enterText(
      find.descendant(
        of: find.byKey(const Key('local-nickname')),
        matching: find.byType(TextField),
      ),
      '  小鱼  ',
    );
    await tester.tap(find.byKey(const Key('save-nickname')));
    await tester.pump();

    expect(controller.profile?.nickname, '小鱼');
    expect(saved, isTrue);
  });

  testWidgets('invalid nickname exposes only a stable local message', (
    tester,
  ) async {
    final controller = ProfileController(
      store: _MemoryStore(),
      nicknameRules: const _Rules(),
    );
    await controller.load();
    await tester.pumpWidget(
      MaterialApp(home: NicknamePage(controller: controller)),
    );

    await tester.enterText(find.byType(TextField), '鱼');
    await tester.tap(find.byKey(const Key('save-nickname')));
    await tester.pump();

    expect(find.text('昵称格式不正确，请重试'), findsOneWidget);
    expect(controller.status, ProfileStatus.needsNickname);
  });
}

final class _Rules implements NicknameRules {
  const _Rules();

  @override
  Future<String> normalize(String raw) async {
    final value = raw.trim();
    if (value.runes.length < 2) throw const NicknameValidationFailure();
    return value;
  }
}

final class _MemoryStore implements AppProfileStore {
  AppProfile? value;

  @override
  Future<AppProfile?> read() async => value;

  @override
  Future<void> write(AppProfile profile) async => value = profile;
}
