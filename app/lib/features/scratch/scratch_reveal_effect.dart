import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../design_system/generated/gamebox_tokens.g.dart';
import 'scratch_surface.dart';

/// Game-owned reveal choreography. Only a fresh reveal plays; restored prizes
/// and returning from the album remain still. Painting never intercepts input.
class ScratchRevealEffect extends StatefulWidget {
  const ScratchRevealEffect({
    super.key,
    required this.revealed,
    required this.rarity,
    required this.child,
  });

  final bool revealed;
  final int rarity;
  final Widget child;

  @override
  State<ScratchRevealEffect> createState() => _ScratchRevealEffectState();
}

class _ScratchRevealEffectState extends State<ScratchRevealEffect>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation = AnimationController(vsync: this)
    ..addStatusListener((_) {
      if (mounted) setState(() {});
    });

  @override
  void didUpdateWidget(ScratchRevealEffect oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.revealed) {
      _animation.reset();
    } else if (!oldWidget.revealed) {
      // Build longer game-art sequences from the shared motion beat.
      _animation.duration = GameboxTokens.motion.slow * [2, 4, 6, 9][widget.rarity];
      _animation.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: AnimatedBuilder(
      animation: _animation,
      child: widget.child,
      builder: (context, child) {
        final playing = _animation.isAnimating && widget.revealed;
        final t = _animation.value;
        final pulse = math.sin(math.pi * (t / .38).clamp(0.0, 1.0));
        return Transform.scale(
          scale: playing ? 1 - (.025 + widget.rarity * .008) * pulse : 1,
          child: Stack(
            fit: StackFit.passthrough,
            children: [
              child!,
              if (playing)
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      key: const Key('scratch-reveal-burst'),
                      painter: _RevealPainter(t, widget.rarity),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    ),
  );
}

class _RevealPainter extends CustomPainter {
  _RevealPainter(this.t, this.rarity);
  final double t;
  final int rarity;

  @override
  void paint(Canvas canvas, Size size) {
    if (t <= 0 || t >= 1) return;
    final color = ScratchArt.rarityColors[rarity];
    final light = Color.lerp(color, ScratchArt.paper, .8)!;
    final center = size.center(Offset.zero);
    final radius = size.shortestSide * .5;
    final fade = math.sin(math.pi * t).clamp(0.0, 1.0);
    final bounds = Offset.zero & size;
    canvas.save();
    canvas.clipRRect(
      RRect.fromRectAndRadius(
        bounds,
        Radius.circular(GameboxTokens.shape.input),
      ),
    );

    // Leave the face clear: the soft glow lives at the portrait's perimeter.
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = RadialGradient(
          colors: [
            color.withValues(alpha: 0),
            color.withValues(alpha: 0),
            color.withValues(alpha: fade * (.22 + rarity * .09)),
          ],
          stops: const [0, .55, 1],
        ).createShader(bounds),
    );

    if (rarity >= 2) {
      final rings = rarity == 3 ? 3 : 1;
      for (var i = 0; i < rings; i++) {
        final phase = ((t - i * .1) / .65).clamp(0.0, 1.0);
        if (phase <= 0 || phase >= 1) continue;
        canvas.drawCircle(
          center,
          radius * (.5 + phase * .85),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = (1 - phase) * (rarity == 3 ? 4 : 2)
            ..color = light.withValues(alpha: (1 - phase) * .8),
        );
      }
    }

    if (rarity == 3) {
      // A rotating crown of rays, with a transparent center for the artwork.
      for (var i = 0; i < 16; i++) {
        final angle = i * math.pi / 8 + t * .3;
        final start =
            center + Offset(math.cos(angle), math.sin(angle)) * radius * .68;
        final end =
            center + Offset(math.cos(angle), math.sin(angle)) * radius * 1.4;
        canvas.drawLine(
          start,
          end,
          Paint()
            ..strokeWidth = i.isEven ? 5 : 2
            ..shader = LinearGradient(
              colors: [
                color.withValues(alpha: 0),
                light.withValues(alpha: fade * .5),
              ],
            ).createShader(Rect.fromPoints(start, end).inflate(1)),
        );
      }
    }

    // Common gets a single gentle sheen; higher tiers add outward starbursts.
    if (rarity > 0) {
      final count = [0, 10, 22, 38][rarity];
      for (var i = 0; i < count; i++) {
        final delay = (i % 5) * .035;
        final phase = ((t - delay) / (1 - delay)).clamp(0.0, 1.0);
        if (phase <= 0 || phase >= 1) continue;
        final angle = i * 2.39996;
        final travel = Curves.easeOutCubic.transform(phase);
        final distance = radius * (.48 + travel * (.45 + (i % 3) * .12));
        final position =
            center +
            Offset(math.cos(angle), math.sin(angle)) * distance +
            Offset(0, phase * phase * radius * .12);
        final opacity = math.sin(math.pi * phase);
        final starSize = (2.5 + (i % 4) * 1.4) * opacity;
        canvas.save();
        canvas.translate(position.dx, position.dy);
        canvas.rotate(angle + phase * .7);
        final path = Path();
        for (var point = 0; point < 8; point++) {
          final a = point * math.pi / 4;
          final r = point.isEven ? starSize : starSize * .25;
          if (point == 0) {
            path.moveTo(math.cos(a) * r, math.sin(a) * r);
          } else {
            path.lineTo(math.cos(a) * r, math.sin(a) * r);
          }
        }
        canvas.drawPath(
          path..close(),
          Paint()
            ..color = (i.isEven ? light : color).withValues(alpha: opacity),
        );
        canvas.restore();
      }
    }

    final sweep = (t / .65).clamp(0.0, 1.0);
    if (sweep > 0 && sweep < 1) {
      canvas.save();
      canvas.translate(size.width * (-.5 + sweep * 2), 0);
      canvas.skew(-.25, 0);
      final band = Rect.fromLTWH(
        -size.width * .16,
        0,
        size.width * .32,
        size.height,
      );
      canvas.drawRect(
        band,
        Paint()
          ..shader = LinearGradient(
            colors: [
              light.withValues(alpha: 0),
              light.withValues(alpha: .12 + rarity * .055),
              light.withValues(alpha: 0),
            ],
          ).createShader(band),
      );
      canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RevealPainter oldDelegate) =>
      t != oldDelegate.t || rarity != oldDelegate.rarity;
}
