import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../design_system/generated/gamebox_tokens.g.dart';
import 'scratch_surface.dart';

/// Presentation only: the saved receipt remains the source of the final count.
class DuplicateCollectionFeedback extends StatelessWidget {
  const DuplicateCollectionFeedback({
    super.key,
    required this.count,
    required this.progress,
    required this.onStory,
  });

  final int count;
  final double progress;
  final VoidCallback? onStory;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    // This footer lives on fixed, light paper in both application schemes.
    final scheme = GameboxTokens.lightColorScheme;
    final arrival = Curves.easeOutCubic.transform(
      (progress / .8).clamp(0.0, 1.0),
    );
    final landed = progress >= .8;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: ScratchArt.ink.withValues(alpha: .15)),
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width:
                GameboxTokens.spacing.section + GameboxTokens.spacing.compact,
            height:
                GameboxTokens.spacing.section + GameboxTokens.spacing.compact,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                _card(-.18, const Offset(-4, 2), ScratchArt.paper),
                _card(.04, Offset.zero, ScratchArt.paper),
                Opacity(
                  opacity: (progress / .2).clamp(0.0, 1.0),
                  child: Transform.translate(
                    key: const Key('draw-duplicate-incoming'),
                    offset: Offset(18 * (1 - arrival), -28 * (1 - arrival)),
                    child: _card(
                      (.04 + .06 * arrival) * math.pi,
                      const Offset(4, -1),
                      scheme.primaryContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: GameboxTokens.spacing.base),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final compact =
                    constraints.maxWidth < GameboxTokens.spacing.section * 3;
                return Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      landed
                          ? (compact ? '已收藏' : '已收进收藏')
                          : (compact ? '收藏中' : '收进收藏'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.labelSmall?.copyWith(color: ScratchArt.ink),
                    ),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        '共 ${landed ? count : count - 1} 张',
                        key: const Key('draw-duplicate-count'),
                        style: text.labelMedium?.copyWith(
                          color: scheme.primary,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          DrawStoryButton(onPressed: onStory),
        ],
      ),
    );
  }

  Widget _card(double angle, Offset offset, Color fill) => Transform.translate(
    offset: offset,
    child: Transform.rotate(
      angle: angle,
      child: Container(
        width: GameboxTokens.spacing.page,
        height: GameboxTokens.spacing.section,
        decoration: BoxDecoration(
          color: fill,
          border: Border.all(color: ScratchArt.rarityColors.first),
          borderRadius: BorderRadius.circular(GameboxTokens.spacing.base),
        ),
      ),
    ),
  );
}

class DrawStoryButton extends StatelessWidget {
  const DrawStoryButton({super.key, required this.onPressed});
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => TextButton(
    key: const Key('draw-view-story'),
    onPressed: onPressed,
    style: TextButton.styleFrom(
      foregroundColor: GameboxTokens.lightColorScheme.primary,
      padding: EdgeInsets.symmetric(horizontal: GameboxTokens.spacing.base),
      minimumSize: Size(
        GameboxTokens.components.minimumTouchTarget,
        GameboxTokens.components.minimumTouchTarget,
      ),
      textStyle: Theme.of(context).textTheme.labelSmall,
    ),
    child: const Text('查看故事'),
  );
}
