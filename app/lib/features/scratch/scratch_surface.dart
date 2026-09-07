import 'package:flutter/material.dart';

import '../../design_system/generated/gamebox_tokens.g.dart';

import 'scratch_controller.dart';

/// Game-owned paper and enamel art; public controls use the app ColorScheme.
abstract final class ScratchArt {
  static final paper = GameboxTokens.gameColors.scratchPaper;
  static final ink = GameboxTokens.gameColors.scratchInk;
  static final foil = GameboxTokens.gameColors.scratchFoil;
  static final rarityColors = [
    GameboxTokens.gameColors.scratchCommon,
    GameboxTokens.gameColors.scratchRare,
    GameboxTokens.gameColors.scratchEpic,
    GameboxTokens.gameColors.scratchLegendary,
  ];
  static const rarityIcons = [
    Icons.circle_outlined,
    Icons.auto_awesome,
    Icons.diamond_outlined,
    Icons.workspace_premium,
  ];
  static Color get onRarity => GameboxTokens.lightColorScheme.onPrimary;
}

/// Shared collectible tier identity across the result, album and details.
class ScratchRarityLabel extends StatelessWidget {
  const ScratchRarityLabel({super.key, required this.rarity, this.suffix = ''});
  final int rarity;
  final String suffix;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: ScratchArt.rarityColors[rarity],
      borderRadius: BorderRadius.circular(GameboxTokens.shape.input),
    ),
    child: Padding(
      padding: EdgeInsets.symmetric(
        horizontal: GameboxTokens.spacing.layout,
        vertical: GameboxTokens.spacing.base,
      ),
      child: Text(
        '${scratchRarities[rarity]}$suffix',
        maxLines: 1,
        style: Theme.of(context).textTheme.labelSmall
            ?.copyWith(color: ScratchArt.onRarity),
      ),
    ),
  );
}

class CollectibleArtwork extends StatelessWidget {
  const CollectibleArtwork({super.key, required this.cat, this.badge = false});
  final ScratchCollectible cat;
  final bool badge;
  @override
  Widget build(BuildContext context) {
    final rows = cat.artRows;
    final row = cat.artIndex ~/ 4;
    final height = rows[row + 1] - rows[row];
    final image = AspectRatio(
      aspectRatio: 1,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          return ClipRect(
            child: Stack(
              children: [
                Positioned(
                  left: -(cat.artIndex % 4) * width,
                  top: -rows[row] / height * width,
                  width: width * 4,
                  height: rows.last / height * width,
                  child: Image.asset(
                    cat.imageAsset,
                    fit: BoxFit.fill,
                    errorBuilder: (_, error, stack) => ColoredBox(
                      color: ScratchArt.paper,
                      child: Center(child: Icon(Icons.image_outlined)),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
    if (!badge) return image;
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [
            GameboxTokens.gameColors.scratchEnamelLight,
            ScratchArt.rarityColors[cat.rarity],
            GameboxTokens.gameColors.scratchEnamelShade,
          ],
        ),
      ),
      child: Padding(
        padding: EdgeInsets.all(GameboxTokens.spacing.base),
        child: ClipOval(child: image),
      ),
    );
  }
}
