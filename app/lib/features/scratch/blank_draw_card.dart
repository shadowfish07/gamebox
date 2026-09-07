import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../design_system/generated/gamebox_tokens.g.dart';
import 'scratch_surface.dart';

/// Cosmetic only: independent of prize RNG and stable when a receipt rebuilds.
int blankCardStyle(int serial) {
  final roll = math.Random(serial).nextDouble();
  return roll < .55
      ? 0
      : roll < .80
      ? 1
      : roll < .94
      ? 2
      : roll < .99
      ? 3
      : 4;
}

class BlankDrawCard extends StatelessWidget {
  const BlankDrawCard({super.key, required this.serial, this.reveal = 1});
  final int serial;
  final double reveal;

  @override
  Widget build(BuildContext context) {
    final style = blankCardStyle(serial);
    return ClipRRect(
      borderRadius: BorderRadius.circular(GameboxTokens.shape.card),
      child: CustomPaint(
        painter: _PaperPainter(style, reveal),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(GameboxTokens.shape.card),
            border: Border.all(color: ScratchArt.ink.withValues(alpha: .18)),
          ),
          child: Column(
            children: [
              const Spacer(),
              Text(
                '空白卡',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: ScratchArt.ink.withValues(alpha: .65),
                  letterSpacing: 4,
                ),
              ),
              SizedBox(height: GameboxTokens.spacing.section),
            ],
          ),
        ),
      ),
    );
  }
}

/// Game-owned paper textures, without series artwork or collectible rarity marks.
class _PaperPainter extends CustomPainter {
  _PaperPainter(this.style, this.reveal);
  final int style;
  final double reveal;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final ink = ScratchArt.ink;
    final paper = ScratchArt.paper;
    final foil = ScratchArt.foil;
    canvas.drawRect(rect, Paint()..color = paper);
    final random = math.Random(91 + style);
    final grain = Paint()..color = ink.withValues(alpha: .035);
    for (var i = 0; i < 650; i++) {
      final x = random.nextDouble() * size.width;
      final y = random.nextDouble() * size.height;
      canvas.drawLine(
        Offset(x, y),
        Offset(x + 1 + random.nextDouble() * 2, y),
        grain,
      );
    }
    final motif = Rect.fromLTWH(
      size.width * .12,
      size.height * .12,
      size.width * .76,
      size.height * .64,
    );
    canvas.save();
    canvas.clipRect(motif);
    if (style == 1) {
      for (var i = 0; i < 8; i++) {
        canvas.drawOval(
          Rect.fromCenter(
            center: Offset(size.width * (.2 + i * .09), size.height * .37),
            width: size.width * .8,
            height: size.height * (.16 + i * .05),
          ),
          Paint()
            ..color = ink.withValues(alpha: .035)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 8,
        );
      }
    } else if (style == 2) {
      for (double y = motif.top; y < motif.bottom; y += 22) {
        for (double x = motif.left; x < motif.right; x += 22) {
          final path = Path()
            ..moveTo(x, y - 8)
            ..lineTo(x + 8, y)
            ..lineTo(x, y + 8)
            ..lineTo(x - 8, y)
            ..close();
          canvas.drawPath(
            path.shift(const Offset(0, 1)),
            Paint()
              ..color = ScratchArt.onRarity.withValues(alpha: .8)
              ..style = PaintingStyle.stroke,
          );
          canvas.drawPath(
            path,
            Paint()
              ..color = ink.withValues(alpha: .10)
              ..style = PaintingStyle.stroke,
          );
        }
      }
    } else if (style >= 3) {
      canvas.drawRect(
        motif,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              paper,
              foil.withValues(alpha: .25),
              ScratchArt.onRarity.withValues(alpha: .85),
              paper,
            ],
          ).createShader(motif),
      );
      if (style == 4) {
        for (var i = 0; i < 42; i++) {
          final point = Offset(
            motif.left + random.nextDouble() * motif.width,
            motif.top + random.nextDouble() * motif.height,
          );
          canvas.drawCircle(
            point,
            .7 + random.nextDouble() * 1.5,
            Paint()
              ..color = ink.withValues(alpha: .12 + random.nextDouble() * .15),
          );
        }
      }
      if (reveal > .4 && reveal < 1) {
        final x = size.width * ((reveal - .4) / .6 * 2 - .5);
        canvas.drawRect(
          Rect.fromLTWH(x, 0, size.width * .3, size.height),
          Paint()
            ..shader = LinearGradient(
              colors: [
                ScratchArt.onRarity.withValues(alpha: 0),
                ScratchArt.onRarity.withValues(alpha: .6),
                ScratchArt.onRarity.withValues(alpha: 0),
              ],
            ).createShader(Rect.fromLTWH(x, 0, size.width * .3, size.height)),
        );
      }
    }
    canvas.restore();
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.deflate(12), const Radius.circular(8)),
      Paint()
        ..color = ink.withValues(alpha: .08)
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_PaperPainter oldDelegate) =>
      style != oldDelegate.style || reveal != oldDelegate.reveal;
}
