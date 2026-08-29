final class GameDescriptor {
  const GameDescriptor({
    required this.id,
    required this.title,
    required this.playerCount,
  });

  final String id;
  final String title;
  final int playerCount;

  @override
  bool operator ==(Object other) =>
      other is GameDescriptor &&
      other.id == id &&
      other.title == title &&
      other.playerCount == playerCount;

  @override
  int get hashCode => Object.hash(id, title, playerCount);
}

const List<GameDescriptor> gameCatalog = <GameDescriptor>[
  GameDescriptor(id: 'gomoku', title: '五子棋', playerCount: 2),
  GameDescriptor(id: 'rps', title: '石头剪刀布', playerCount: 2),
];
