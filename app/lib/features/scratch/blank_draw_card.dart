import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../design_system/generated/gamebox_tokens.g.dart';
import 'scratch_surface.dart';

/// Cosmetic weights only; never consumes the collectible prize random source.
int blankCardStyleForRoll(double roll) => roll < .30
    ? 0
    : roll < .60
    ? 1
    : roll < .80
    ? 2
    : roll < .95
    ? 3
    : 4;

/// Stable across rebuilds and restored receipts, without storing a collection.
int blankCardStyle(int serial) =>
    blankCardStyleForRoll(math.Random(serial).nextDouble());

class BlankDrawCard extends StatelessWidget {
  const BlankDrawCard({super.key, required this.serial, this.reveal = 1});
  final int serial;
  final double reveal;
  static const asset = 'assets/scratch/blank-atlas.png';
  static const names = ['深海', '陶土', '雾紫', '黑银', '极光'];
  // Source rectangles in the approved five-card art sheet. Runtime clipping
  // uses the original art rather than approximating it with painted patterns.
  static const _left = [25.0, 355.0, 684.0, 1014.0, 1352.0];

  @override
  Widget build(BuildContext context) {
    final style = blankCardStyle(serial);
    final foreground = ScratchArt.onRarity;
    return ClipRRect(
      borderRadius: BorderRadius.circular(GameboxTokens.shape.card),
      child: LayoutBuilder(
        builder: (context, constraints) => Stack(
          fit: StackFit.expand,
          children: [
            Positioned(
              left: -_left[style] / 307 * constraints.maxWidth,
              top: -175 / 592 * constraints.maxHeight,
              width: 1691 / 307 * constraints.maxWidth,
              height: 930 / 592 * constraints.maxHeight,
              child: Image.asset(asset, fit: BoxFit.fill),
            ),
            if (style >= 3 && reveal > .4 && reveal < 1)
              IgnorePointer(
                child: CustomPaint(painter: _Sheen(reveal, foreground)),
              ),
            Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                width: double.infinity,
                padding: EdgeInsets.all(GameboxTokens.spacing.layout),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Theme.of(context).colorScheme.scrim.withValues(alpha: 0),
                      Theme.of(context).colorScheme.scrim
                          .withValues(alpha: .65),
                    ],
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '空白卡',
                      style: Theme.of(context).textTheme.labelLarge
                          ?.copyWith(color: foreground, letterSpacing: 3),
                    ),
                    SizedBox(height: GameboxTokens.spacing.base),
                    Text(
                      names[style],
                      style: Theme.of(context).textTheme.labelSmall
                          ?.copyWith(color: foreground.withValues(alpha: .75)),
                    ),
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

class _Sheen extends CustomPainter {
  _Sheen(this.reveal, this.color);
  final double reveal;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final x = size.width * ((reveal - .4) / .6 * 2 - .5);
    final rect = Rect.fromLTWH(x, 0, size.width * .3, size.height);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: [
            color.withValues(alpha: 0),
            color.withValues(alpha: .25),
            color.withValues(alpha: 0),
          ],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_Sheen oldDelegate) =>
      reveal != oldDelegate.reveal || color != oldDelegate.color;
}
