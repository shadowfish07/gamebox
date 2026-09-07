import 'package:flutter/material.dart';

import '../../design_system/generated/gamebox_tokens.g.dart';
import 'scratch_catalog.dart';
import 'scratch_surface.dart';

/// Full-bleed artwork with a tier-colored caption, shared by both albums.
class ScratchCollectibleCard extends StatelessWidget {
  const ScratchCollectibleCard({
    super.key,
    required this.item,
    required this.count,
    this.onTap,
  });
  final ScratchCollectible item;
  final int count;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final owned = count > 0;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final color = owned
        ? ScratchArt.rarityColors[item.rarity]
        : scheme.surfaceContainerHighest;
    final foreground = owned ? ScratchArt.onRarity : scheme.onSurfaceVariant;
    return Material(
      color: color,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(GameboxTokens.shape.card),
        side: BorderSide(color: owned ? color : scheme.outlineVariant),
      ),
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (owned)
                    CollectibleArtwork(cat: item)
                  else
                    ColoredBox(
                      color: scheme.surfaceContainerLow,
                      child: Icon(
                        Icons.lock_outline,
                        size: 32,
                        color: scheme.outline,
                      ),
                    ),
                  if (owned)
                    Positioned(
                      top: 0,
                      right: 0,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.only(
                            bottomLeft: Radius.circular(
                              GameboxTokens.shape.input,
                            ),
                          ),
                        ),
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: GameboxTokens.spacing.compact,
                            vertical: GameboxTokens.spacing.base,
                          ),
                          child: Text(
                            '×$count',
                            style: text.labelSmall?.copyWith(color: foreground),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: GameboxTokens.spacing.compact,
                  vertical: GameboxTokens.spacing.base,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      owned ? item.job : '未获得',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.titleSmall?.copyWith(color: foreground),
                    ),
                    if (owned) ...[
                      SizedBox(height: GameboxTokens.spacing.base),
                      Text(
                        scratchRarities[item.rarity],
                        style: text.labelSmall?.copyWith(color: foreground),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
