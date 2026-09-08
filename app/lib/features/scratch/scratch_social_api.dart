import '../../core/api/api_client.dart';
import '../../core/api/api_error.dart';
import '../auth/session_controller.dart';
import '../gomoku/gomoku_models.dart' show isCanonicalGameboxUuid;
import 'scratch_catalog.dart';

final class ScratchPlayer {
  const ScratchPlayer({
    required this.userId,
    required this.nickname,
    required this.counts,
    required this.updatedAt,
  });
  final String userId, nickname;
  final List<int> counts;
  final DateTime updatedAt;
  int get collected => counts.where((count) => count > 0).length;
  factory ScratchPlayer.fromJson(Map<String, Object?> json) {
    final id = json['userId'],
        name = json['nickname'],
        raw = json['counts'],
        time = json['updatedAt'];
    if (id is! String ||
        !isCanonicalGameboxUuid(id) ||
        name is! String ||
        name.trim().isEmpty ||
        name.length > 100 ||
        raw is! List ||
        (raw.length != scratchLegacyCatalogSize &&
            raw.length != scratchCollectibles.length) ||
        raw.any((v) => v is! int || v < 0 || v > 1000000000) ||
        time is! int ||
        time < 0 ||
        time > 8640000000000000) {
      throw const FormatException('Invalid collection');
    }
    return ScratchPlayer(
      userId: id,
      nickname: name,
      counts: List<int>.unmodifiable([
        ...raw.cast<int>(),
        ...List.filled(scratchCollectibles.length - raw.length, 0),
      ]),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(time),
    );
  }
}

final class ScratchPlayerPage {
  const ScratchPlayerPage(this.players, this.nextCursor);
  final List<ScratchPlayer> players;
  final String nextCursor;
}

abstract interface class ScratchSocialApi {
  bool get canSync;
  Future<ScratchPlayerPage> list([String after = '', int? card]);
  Future<void> sync(List<int> counts);
}

final class HttpScratchSocialApi implements ScratchSocialApi {
  HttpScratchSocialApi(this.client, [this.session]);
  final ApiClient client;
  final SessionController? session;
  @override
  bool get canSync => session?.accessToken != null;
  @override
  Future<ScratchPlayerPage> list([String after = '', int? card]) async {
    final query = <String, String>{
      'catalogSize': '${scratchCollectibles.length}',
      if (after.isNotEmpty) 'after': after,
      if (card != null) 'card': '$card',
    };
    final path = Uri(
      path: '/v1/scratch/collections',
      queryParameters: query.isEmpty ? null : query,
    ).toString();
    final json = await client.getJson(path);
    try {
      final raw = json['players'], cursor = json['nextCursor'];
      if (raw is! List ||
          raw.length > 30 ||
          cursor is! String ||
          (cursor.isNotEmpty && !isCanonicalGameboxUuid(cursor))) {
        throw const FormatException();
      }
      final players = raw
          .map(
            (v) => ScratchPlayer.fromJson(Map<String, Object?>.from(v as Map)),
          )
          .toList();
      if ((card != null && players.any((p) => p.counts[card] <= 0)) ||
          players.map((p) => p.userId).toSet().length != players.length ||
          (cursor.isNotEmpty &&
              (players.isEmpty ||
                  cursor != players.last.userId ||
                  cursor == after))) {
        throw const FormatException();
      }
      return ScratchPlayerPage(players, cursor);
    } catch (_) {
      throw const ApiError(code: 'invalid_response', message: '收藏数据暂时无法读取，请重试');
    }
  }

  @override
  Future<void> sync(List<int> counts) async {
    final response = await client.postJson(
      '/v1/scratch/collections/me',
      {'counts': counts},
      accessToken: () => session?.accessToken,
      onUnauthorized: session?.refresh,
    );
    if (response['published'] != true) {
      throw const ApiError(code: 'invalid_response', message: '收藏同步未完成，请重试');
    }
  }
}
