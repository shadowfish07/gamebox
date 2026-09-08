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
    this.enabled = true,
    this.playOnMount = false,
    this.duration,
  });

  final bool revealed;
  final int rarity;
  final Widget child;
  final bool enabled, playOnMount;
  final Duration? duration;

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
  void initState() {
    super.initState();
    if (widget.playOnMount && widget.enabled && widget.revealed) _play();
  }

  void _play() {
    _animation.duration =
        widget.duration ??
        GameboxTokens.motion.slow * [2, 4, 6, 9][widget.rarity];
    _animation.forward(from: 0);
  }

  @override
  void didUpdateWidget(ScratchRevealEffect oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.revealed || !widget.enabled) {
      _animation.reset();
    } else if (!oldWidget.revealed) {
      // Build longer game-art sequences from the shared motion beat.
      _play();
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
        return Stack(
          fit: StackFit.passthrough,
          clipBehavior: Clip.none,
          children: [
            if (playing)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _CardHaloPainter(t, widget.rarity),
                  ),
                ),
              ),
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
        );
      },
    ),
  );
}

// The opaque production card covers the inner half of this soft outline.
// No scrim or rectangular light panel is painted behind the play area.
class _CardHaloPainter extends CustomPainter {
  _CardHaloPainter(this.t, this.rarity);
  final double t;
  final int rarity;

  @override
  void paint(Canvas canvas, Size size) {
    final fade = math.sin(math.pi * t);
    if (fade <= 0) return;
    final frame = RRect.fromRectAndRadius(
      (Offset.zero & size).inflate(1 + rarity.toDouble()),
      Radius.circular(GameboxTokens.shape.card + rarity),
    );
    canvas.drawRRect(
      frame,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 + rarity * 2.0
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 3 + rarity * 3.0)
        ..color = ScratchArt.rarityColors[rarity].withValues(
          alpha: fade * [.12, .24, .32, .42][rarity],
        ),
    );
  }

  @override
  bool shouldRepaint(_CardHaloPainter oldDelegate) =>
      t != oldDelegate.t || rarity != oldDelegate.rarity;
}

class _RevealPainter extends CustomPainter {
  _RevealPainter(this.t, this.rarity);
  final double t;
  final int rarity;

  @override
  void paint(Canvas canvas, Size size) {
    if (t <= 0 || t >= 1) return;
    final color = ScratchArt.rarityColors[rarity];
    final light = Color.lerp(color, ScratchArt.paper, .4)!;
    final fade = math.sin(math.pi * t);
    final bounds = Offset.zero & size;
    final frame = RRect.fromRectAndRadius(
      bounds.deflate(1),
      Radius.circular(GameboxTokens.shape.card),
    );

    // Sweep only the card's rim. The portrait, title and collection feedback
    // stay untouched, including while the card is still turning toward us.
    final rim = Path()
      ..fillType = PathFillType.evenOdd
      ..addRRect(frame)
      ..addRRect(frame.deflate(GameboxTokens.spacing.base));
    canvas.save();
    canvas.clipPath(rim);
    canvas.drawRRect(
      frame,
      Paint()..color = light.withValues(alpha: fade * .1),
    );
    final sweep = Curves.easeInOutCubic.transform(t);
    final x = size.width * (-.4 + sweep * 1.8);
    final band = Rect.fromLTWH(
      x - size.width * .15,
      0,
      size.width * .3,
      size.height,
    );
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = LinearGradient(
          colors: [
            light.withValues(alpha: 0),
            light.withValues(alpha: .6 * fade),
            light.withValues(alpha: 0),
          ],
        ).createShader(band),
    );
    canvas.restore();

    const anchors = [
      Offset(0, .16),
      Offset(1, .28),
      Offset(.82, 0),
      Offset(0, .68),
      Offset(1, .82),
      Offset(.22, 1),
      Offset(.12, 0),
      Offset(1, .53),
      Offset(0, .4),
      Offset(.73, 1),
      Offset(.48, 0),
      Offset(.48, 1),
      Offset(0, .88),
      Offset(1, .1),
      Offset(0, .05),
      Offset(1, .95),
      Offset(.95, 0),
      Offset(.07, 1),
      Offset(0, .54),
      Offset(1, .65),
    ];
    final count = [0, 6, 12, 20][rarity];
    // The empty center is a geometric guarantee, not an opacity illusion.
    canvas.save();
    canvas.clipPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(bounds.inflate(40))
        ..addRRect(frame.deflate(1)),
    );
    for (var i = 0; i < count; i++) {
      final delay = (i % 4) * .045;
      final phase = ((t - delay) / (1 - delay)).clamp(0.0, 1.0);
      final opacity = math.pow(math.sin(math.pi * phase), .65).toDouble();
      if (opacity <= 0) continue;
      final anchor = anchors[i];
      final normal = Offset(
        anchor.dx == 0
            ? -1
            : anchor.dx == 1
            ? 1
            : 0,
        anchor.dy == 0
            ? -1
            : anchor.dy == 1
            ? 1
            : 0,
      );
      final tangent = Offset(-normal.dy, normal.dx);
      final travel = Curves.easeOutCubic.transform(phase);
      final position =
          Offset(anchor.dx * size.width, anchor.dy * size.height) +
          normal * (8 + travel * (normal.dy == 0 ? 5 + rarity * 4 : 3)) +
          tangent * phase * 7;
      final radius =
          (4.0 + rarity * 2 + i % 3) *
          (.6 + .4 * opacity) *
          (normal.dy == 0 ? 1 : .8);
      // Short outward trails and a luminous core make the particles readable
      // at phone scale without lifting the opacity of the whole card halo.
      canvas.drawLine(
        position - normal * (3 + rarity * 2),
        position,
        Paint()
          ..strokeWidth = 1.2
          ..strokeCap = StrokeCap.round
          ..color = color.withValues(alpha: opacity * .4),
      );
      canvas.drawCircle(
        position,
        radius * .7,
        Paint()
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3)
          ..color = color.withValues(alpha: opacity * .28),
      );
      final star = Path()
        ..moveTo(position.dx, position.dy - radius)
        ..quadraticBezierTo(
          position.dx + radius * .12,
          position.dy - radius * .12,
          position.dx + radius * .7,
          position.dy,
        )
        ..quadraticBezierTo(
          position.dx + radius * .12,
          position.dy + radius * .12,
          position.dx,
          position.dy + radius,
        )
        ..quadraticBezierTo(
          position.dx - radius * .12,
          position.dy + radius * .12,
          position.dx - radius * .7,
          position.dy,
        )
        ..quadraticBezierTo(
          position.dx - radius * .12,
          position.dy - radius * .12,
          position.dx,
          position.dy - radius,
        )
        ..close();
      canvas.drawPath(star, Paint()..color = color.withValues(alpha: opacity));
      canvas.drawCircle(
        position,
        radius * .18,
        Paint()..color = ScratchArt.paper.withValues(alpha: opacity),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RevealPainter oldDelegate) =>
      t != oldDelegate.t || rarity != oldDelegate.rarity;
}
