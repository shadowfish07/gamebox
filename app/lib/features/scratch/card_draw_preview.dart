import 'scratch_controller.dart';
import 'scratch_social_api.dart';

/// Session-only draws: blank, rare, epic, legendary, then repeat.
/// Only the separate debug entrypoint imports this setup.
ScratchController createCardDrawPreviewController() {
  var calls = 0;
  return ScratchController(
    store: _PreviewStore(),
    random: () {
      final draw = (calls ~/ 3) % 4;
      final part = calls++ % 3;
      return switch (part) {
        0 => draw == 0 ? 0.9 : 0.0,
        1 => [0.0, 0.8, 0.96, 0.999][draw],
        _ => 0.0,
      };
    },
  );
}

class _PreviewStore implements ScratchStore {
  String? _value;
  @override
  Future<String?> read() async => _value;
  @override
  Future<void> write(String value) async => _value = value;
}

class CardDrawPreviewSocialApi implements ScratchSocialApi {
  const CardDrawPreviewSocialApi();
  @override
  bool get canSync => false;
  @override
  Future<ScratchPlayerPage> list([String after = '', int? card]) async =>
      const ScratchPlayerPage([], '');
  @override
  Future<void> sync(List<int> counts) async {}
}
