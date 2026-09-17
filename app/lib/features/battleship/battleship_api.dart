import '../../core/api/api_client.dart';
import '../../core/api/api_error.dart';
import '../gomoku/gomoku_models.dart' show isCanonicalGameboxUuid;
import 'battleship_models.dart';

final class SeaOpponent {
  const SeaOpponent(this.id, this.nickname);
  final String id, nickname;
}

final class SeaPage<T> {
  const SeaPage(this.items, this.nextCursor);
  final List<T> items;
  final String nextCursor;
}

abstract interface class BattleshipApi {
  String get userId;
  Future<SeaPage<SeaMatch>> matches([String after = '']);
  Future<SeaPage<SeaOpponent>> opponents([String after = '']);
  Future<SeaMatch> create(String id, String opponent);
  Future<SeaMatch> get(String id);
  Future<SeaMatch> act(String id, Map<String, Object?> action);
}

final class HttpBattleshipApi implements BattleshipApi {
  HttpBattleshipApi(
    this.client, {
    required this.userId,
    required this.accessToken,
    required this.onUnauthorized,
  });
  final ApiClient client;
  @override
  final String userId;
  final AccessTokenProvider accessToken;
  final UnauthorizedHandler onUnauthorized;
  Future<Map<String, Object?>> _get(String path) => client.getJson(
    '/v1/battleship/$path',
    accessToken: accessToken,
    onUnauthorized: onUnauthorized,
  );
  Future<Map<String, Object?>> _post(String path, Map<String, Object?> body) =>
      client.postJson(
        '/v1/battleship/$path',
        body,
        accessToken: accessToken,
        onUnauthorized: onUnauthorized,
      );
  T _parse<T>(T Function() parse) {
    try {
      return parse();
    } on FormatException {
      throw const ApiError(code: 'invalid_response', message: '无法读取对局，请重试');
    } on TypeError {
      throw const ApiError(code: 'invalid_response', message: '无法读取对局，请重试');
    }
  }

  String _cursor(Map<String, Object?> j) {
    final c = j['nextCursor'];
    if (c is! String || c.isNotEmpty && !isCanonicalGameboxUuid(c)) {
      throw const FormatException();
    }
    return c;
  }

  List<Object?> _items(Map<String, Object?> j, String key) {
    final l = j[key];
    if (l is! List || l.length > 30) throw const FormatException();
    return l;
  }

  @override
  Future<SeaPage<SeaMatch>> matches([String after = '']) async {
    final j = await _get('matches?after=${Uri.encodeQueryComponent(after)}');
    return _parse(
      () => SeaPage(
        _items(
          j,
          'matches',
        ).map((v) => SeaMatch(v as Map<String, Object?>)).toList(),
        _cursor(j),
      ),
    );
  }

  @override
  Future<SeaPage<SeaOpponent>> opponents([String after = '']) async {
    final j = await _get('opponents?after=${Uri.encodeQueryComponent(after)}');
    return _parse(
      () => SeaPage(
        _items(j, 'players').map((v) {
          final m = v as Map<String, Object?>;
          final id = m['id'], n = m['nickname'];
          if (id is! String ||
              !isCanonicalGameboxUuid(id) ||
              n is! String ||
              n.trim().isEmpty ||
              n.length > 100) {
            throw const FormatException();
          }
          return SeaOpponent(id, n);
        }).toList(),
        _cursor(j),
      ),
    );
  }

  @override
  Future<SeaMatch> create(String id, String opponent) async {
    final j = await _post('matches', {'id': id, 'opponentId': opponent});
    return _parse(() => SeaMatch(j));
  }

  @override
  Future<SeaMatch> get(String id) async {
    final j = await _get('matches/$id');
    return _parse(() => SeaMatch(j));
  }

  @override
  Future<SeaMatch> act(String id, Map<String, Object?> action) async {
    final j = await _post('matches/$id/actions', action);
    return _parse(() => SeaMatch(j));
  }
}
