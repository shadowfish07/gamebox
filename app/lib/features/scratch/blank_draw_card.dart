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
  static const names = ['涟漪', '折光', '流纱', '银线', '微光'];

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(GameboxTokens.shape.card),
    child: CustomPaint(
      painter: _TransparentArt(blankCardStyle(serial), reveal),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(GameboxTokens.shape.card),
          border: Border.all(color: ScratchArt.ink.withValues(alpha: .15)),
        ),
        child: Column(
          children: [
            const Spacer(),
            Text(
              '空白卡',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: ScratchArt.ink.withValues(alpha: .65),
                letterSpacing: 3,
              ),
            ),
            SizedBox(height: GameboxTokens.spacing.section),
          ],
        ),
      ),
    ),
  );
}

/// Translucent, monochrome artwork on warm paper. No rectangular texture patch.
class _TransparentArt extends CustomPainter {
  _TransparentArt(this.style, this.reveal);
  final int style;
  final double reveal;

  @override
  void paint(Canvas canvas, Size size) {
    final ink = ScratchArt.ink;
    final white = ScratchArt.onRarity;
    final bounds = Offset.zero & size;
    canvas.drawRect(bounds, Paint()..color = ScratchArt.paper);
    canvas.drawRRect(
      RRect.fromRectAndRadius(bounds.deflate(12), const Radius.circular(8)),
      Paint()
        ..color = ink.withValues(alpha: .065)
        ..style = PaintingStyle.stroke,
    );
    canvas.save();
    canvas.translate(size.width * .5, size.height * .43);
    final scale = size.width / 250;
    canvas.scale(scale);
    final artBounds = Rect.fromCenter(
      center: Offset.zero,
      width: 220,
      height: 240,
    );
    final softInk = RadialGradient(
      colors: [
        ink.withValues(alpha: .18),
        ink.withValues(alpha: .07),
        ink.withValues(alpha: 0),
      ],
      stops: const [0, .65, 1],
    ).createShader(artBounds);
    final stroke = Paint()
      ..shader = softInk
      ..style = PaintingStyle.stroke
      ..strokeWidth = .7;
    switch (style) {
      case 0:
        canvas.rotate(-.32);
        for (var i = 0; i < 12; i++) {
          final r = 12.0 + i * 7;
          canvas.drawOval(
            Rect.fromCenter(
              center: Offset(i * .9, 0),
              width: r * 2,
              height: r * 1.4,
            ),
            stroke,
          );
          canvas.drawOval(
            Rect.fromCenter(
              center: Offset(i * .9, 1),
              width: r * 2,
              height: r * 1.4,
            ),
            Paint()
              ..color = white.withValues(alpha: .5)
              ..style = PaintingStyle.stroke
              ..strokeWidth = .8,
          );
        }
      case 1:
        final shapes = [
          Path()
            ..moveTo(-80, -58)
            ..quadraticBezierTo(-76, -68, -66, -63)
            ..lineTo(70, -28)
            ..quadraticBezierTo(79, -24, 74, -14)
            ..lineTo(22, 76)
            ..quadraticBezierTo(18, 83, 10, 77)
            ..close(),
          Path()
            ..moveTo(-60, 27)
            ..quadraticBezierTo(-69, 23, -63, 14)
            ..lineTo(10, -81)
            ..quadraticBezierTo(17, -90, 23, -79)
            ..lineTo(82, 54)
            ..quadraticBezierTo(87, 65, 74, 62)
            ..close(),
        ];
        for (var i = 0; i < shapes.length; i++) {
          canvas.drawPath(
            shapes[i],
            Paint()
              ..shader = LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  white.withValues(alpha: .85),
                  ink.withValues(alpha: .035),
                  white.withValues(alpha: .2),
                ],
              ).createShader(artBounds),
          );
          canvas.drawPath(
            shapes[i],
            Paint()
              ..color = ink.withValues(alpha: .095)
              ..style = PaintingStyle.stroke
              ..strokeWidth = .7,
          );
          canvas.drawPath(
            shapes[i].shift(const Offset(0, 1)),
            Paint()
              ..color = white.withValues(alpha: .8)
              ..style = PaintingStyle.stroke
              ..strokeWidth = .7,
          );
        }
      case 2:
        for (var i = 0; i < 30; i++) {
          final t = i / 29;
          final path = Path()
            ..moveTo(-88 + t * 22, -78 + t * 12)
            ..cubicTo(
              95,
              -62 + t * 38,
              -100,
              30 + t * 40,
              68 + t * 22,
              82 - t * 14,
            );
          canvas.drawPath(
            path,
            Paint()
              ..shader = softInk
              ..style = PaintingStyle.stroke
              ..strokeWidth = .75,
          );
          canvas.drawPath(
            path.shift(const Offset(.8, 0)),
            Paint()
              ..color = white.withValues(alpha: .25)
              ..style = PaintingStyle.stroke
              ..strokeWidth = .6,
          );
        }
      case 3:
        canvas.rotate(-.22);
        for (var i = 0; i < 34; i++) {
          final t = i / 33;
          final path = Path()
            ..moveTo(-85 + t * 160, -55 + math.sin(t * math.pi) * 24)
            ..cubicTo(
              110 - t * 220,
              -90,
              -115 + t * 220,
              100,
              -75 + t * 160,
              58 - math.sin(t * math.pi) * 20,
            );
          canvas.drawPath(path, stroke);
        }
      case 4:
        canvas.rotate(-.38);
        final oval = Rect.fromCenter(
          center: Offset.zero,
          width: 142,
          height: 186,
        );
        canvas.drawOval(
          oval,
          Paint()
            ..shader = RadialGradient(
              center: const Alignment(-.35, -.4),
              radius: .85,
              colors: [
                white.withValues(alpha: .92),
                white.withValues(alpha: .15),
                ink.withValues(alpha: .075),
                white.withValues(alpha: .55),
              ],
              stops: const [0, .45, .78, 1],
            ).createShader(oval),
        );
        canvas.drawOval(
          oval,
          Paint()
            ..color = ink.withValues(alpha: .07)
            ..style = PaintingStyle.stroke
            ..strokeWidth = .6,
        );
        final random = math.Random(47);
        for (var i = 0; i < 13; i++) {
          final x = (random.nextDouble() - .5) * 156;
          final y = (random.nextDouble() - .5) * 190;
          final length = 1.5 + random.nextDouble() * 2;
          final sparkle = Paint()
            ..color = ink.withValues(alpha: .16)
            ..strokeWidth = .65;
          canvas.drawLine(
            Offset(x - length, y),
            Offset(x + length, y),
            sparkle,
          );
          canvas.drawLine(
            Offset(x, y - length),
            Offset(x, y + length),
            sparkle,
          );
        }
    }
    // A soft, local highlight, never an opaque panel across the paper.
    if (style >= 3 && reveal > .4 && reveal < 1) {
      final x = ((reveal - .4) / .6 * 2 - 1) * 75;
      final glow = Rect.fromCenter(
        center: Offset(x, 0),
        width: 70,
        height: 150,
      );
      canvas.drawOval(
        glow,
        Paint()
          ..shader = RadialGradient(
            colors: [white.withValues(alpha: .65), white.withValues(alpha: 0)],
          ).createShader(glow),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TransparentArt oldDelegate) =>
      style != oldDelegate.style || reveal != oldDelegate.reveal;
}
