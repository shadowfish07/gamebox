import '../../core/api/strict_json.dart';
import '../gomoku/gomoku_models.dart';

const reversiGameId = 'reversi';

final class ReversiSnapshot {
  ReversiSnapshot._(
    this.revision,
    this.board,
    this.status,
    this.blackUserId,
    this.whiteUserId,
    this.nextColor,
    this.winnerUserId,
    this.result,
    this.legalMoves,
    this.blackCount,
    this.whiteCount,
    this.passedColor,
    this.lastMove,
  );

  factory ReversiSnapshot.fromJson(int revision, Map<String, Object?> json) {
    const fields = {
      'status',
      'board',
      'boardSize',
      'blackUserId',
      'whiteUserId',
      'nextColor',
      'winnerUserId',
      'result',
      'legalMoves',
      'blackCount',
      'whiteCount',
      'passedColor',
      'lastMove',
    };
    if (!hasExactJsonKeys(json, fields) ||
        revision < 0 ||
        revision > 61 ||
        json['boardSize'] != 8) {
      throw const FormatException('Invalid reversi snapshot');
    }
    final rawBoard = json['board'];
    if (rawBoard is! List ||
        rawBoard.length != 64 ||
        rawBoard.any((c) => c is! int || c < 0 || c > 2)) {
      throw const FormatException('Invalid board');
    }
    final board = List<int>.unmodifiable(rawBoard.cast<int>());
    final black = json['blackUserId'];
    final white = json['whiteUserId'];
    if (black is! String ||
        white is! String ||
        black == white ||
        !isCanonicalGameboxUuid(black) ||
        !isCanonicalGameboxUuid(white)) {
      throw const FormatException('Invalid players');
    }
    final status = json['status'];
    final next = json['nextColor'];
    final winner = json['winnerUserId'];
    final result = json['result'];
    final passed = json['passedColor'];
    final rawLegal = json['legalMoves'];
    if (!const {
          'active',
          'finished',
          'cancelled',
          'abandoned',
        }.contains(status) ||
        !const {'black', 'white', ''}.contains(next) ||
        (winner != null && winner != black && winner != white) ||
        !const {null, 'draw', 'majority', 'resignation'}.contains(result) ||
        !const {null, 'black', 'white'}.contains(passed) ||
        rawLegal is! List) {
      throw const FormatException('Invalid match state');
    }
    final legal = rawLegal.map(_cell).toSet();
    final b = board.where((c) => c == 1).length;
    final w = board.where((c) => c == 2).length;
    if (b != json['blackCount'] ||
        w != json['whiteCount'] ||
        legal.length != rawLegal.length ||
        legal.any((i) => board[i] != 0) ||
        (status == 'active' &&
            (next == '' ||
                legal.isEmpty ||
                winner != null ||
                result != null)) ||
        (status != 'active' && (next != '' || legal.isNotEmpty)) ||
        (status == 'finished' &&
            (result == null ||
                (result == 'draw'
                    ? winner != null || b != w
                    : winner == null)))) {
      throw const FormatException('Inconsistent match state');
    }
    return ReversiSnapshot._(
      revision,
      board,
      status as String,
      black,
      white,
      next as String,
      winner as String?,
      result as String?,
      Set<int>.unmodifiable(legal),
      b,
      w,
      passed as String?,
      json['lastMove'] == null ? null : _cell(json['lastMove']),
    );
  }
  final int revision;
  final List<int> board;
  final String status, blackUserId, whiteUserId, nextColor;
  final String? winnerUserId, result, passedColor;
  final Set<int> legalMoves;
  final int blackCount, whiteCount;
  final int? lastMove;
  bool get active => status == 'active';
  String colorFor(String userId) => userId == blackUserId ? 'black' : 'white';
  bool isTurn(String userId) =>
      active && (nextColor == 'black' ? blackUserId : whiteUserId) == userId;
}

int _cell(Object? value) {
  if (value is! Map<String, Object?> ||
      !hasExactJsonKeys(value, const {'x', 'y'})) {
    throw const FormatException('Invalid point');
  }
  final x = value['x'];
  final y = value['y'];
  if (x is! int || y is! int || x < 0 || x > 7 || y < 0 || y > 7) {
    throw const FormatException('Invalid point');
  }
  return y * 8 + x;
}
