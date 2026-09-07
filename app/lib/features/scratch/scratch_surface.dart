import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
    Icons.pets,
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

class CatArtwork extends StatelessWidget {
  const CatArtwork({super.key, required this.cat, this.badge = false});
  final ScratchCat cat;
  final bool badge;
  @override
  Widget build(BuildContext context) {
    const rows = [0, 304, 576, 838, 1096, 1319, 1536];
    final row = cat.index ~/ 4;
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
                  left: -(cat.index % 4) * width,
                  top: -rows[row] / height * width,
                  width: width * 4,
                  height: 1536 / height * width,
                  child: Image.asset(
                    'assets/scratch/cat-atlas.webp',
                    fit: BoxFit.fill,
                    errorBuilder: (_, error, stack) => ColoredBox(
                      color: ScratchArt.paper,
                      child: Center(child: Icon(Icons.pets)),
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

class ScratchSurface extends StatefulWidget {
  const ScratchSurface({
    super.key,
    required this.mask,
    required this.onComplete,
    required this.onEnd,
    this.clue = false,
    this.enabled = true,
  });
  final ScratchMask mask;
  final VoidCallback onComplete, onEnd;
  final bool clue, enabled;
  @override
  State<ScratchSurface> createState() => _ScratchSurfaceState();
}

class _ScratchSurfaceState extends State<ScratchSurface> {
  int? _pointer;
  Offset? _last;
  bool _complete = false;

  void _move(PointerEvent event) {
    if (_pointer != event.pointer || !widget.enabled || _complete) return;
    final size = context.size!;
    final point = Offset(
      (event.localPosition.dx / size.width).clamp(0.0, 1.0),
      (event.localPosition.dy / size.height).clamp(0.0, 1.0),
    );
    final previous = _last ?? point;
    widget.mask.erase(
      previous.dx,
      previous.dy,
      point.dx,
      point.dy,
      radius: widget.clue ? .16 : .085,
    );
    _last = point;
    if (widget.mask.coverage >= .65) {
      _complete = true;
      _pointer = null;
      _last = null;
      HapticFeedback.selectionClick();
      widget.onComplete();
    }
  }

  void _end(PointerEvent event) {
    if (_pointer != event.pointer) return;
    _pointer = null;
    _last = null;
    widget.onEnd();
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.opaque,
    onPointerDown: (event) {
      if (!widget.enabled || _pointer != null || _complete) return;
      _pointer = event.pointer;
      _last = null;
      _move(event);
    },
    onPointerMove: _move,
    onPointerUp: _end,
    onPointerCancel: _end,
    child: Semantics(
      container: true,
      label: widget.clue ? '职业线索涂层' : '猫猫照片涂层',
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _FoilPainter(widget.mask, widget.clue),
          size: Size.infinite,
        ),
      ),
    ),
  );
}

class _FoilPainter extends CustomPainter {
  _FoilPainter(this.mask, this.clue) : super(repaint: mask);
  final ScratchMask mask;
  final bool clue;
  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.saveLayer(bounds, Paint());
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            GameboxTokens.gameColors.scratchFoilLight,
            GameboxTokens.gameColors.scratchFoilShade,
            GameboxTokens.gameColors.scratchFoilGlint,
          ],
        ).createShader(bounds),
    );
    final hatch = Paint()
      ..color = GameboxTokens.lightColorScheme.onPrimary.withValues(alpha: .2)
      ..strokeWidth = 1;
    for (double x = -size.height; x < size.width; x += 10) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x + size.height, size.height),
        hatch,
      );
    }
    if (!clue) {
      final scale = math.min(size.width, size.height) / 140;
      canvas.save();
      canvas.translate(size.width / 2, size.height * .42);
      canvas.scale(scale);
      final paw = Paint()..color = GameboxTokens.gameColors.scratchPaw;
      for (final center in [
        const Offset(-18, -8),
        const Offset(-7, -18),
        const Offset(8, -18),
        const Offset(20, -6),
      ]) {
        canvas.drawOval(
          Rect.fromCenter(center: center, width: 12, height: 17),
          paw,
        );
      }
      canvas.drawOval(
        Rect.fromCenter(center: const Offset(0, 12), width: 32, height: 27),
        paw,
      );
      canvas.restore();
    }
    final text = TextPainter(
      text: TextSpan(
        text: clue
            ? '先刮开职业线索'
            : size.width < 150
            ? '刮一刮'
            : '好运，藏在这里',
        style: TextStyle(
          color: GameboxTokens.gameColors.scratchFoilInk,
          fontSize: clue
              ? 12
              : size.width < 150
              ? 11
              : 15,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width);
    text.paint(
      canvas,
      Offset(
        (size.width - text.width) / 2,
        (clue ? size.height / 2 : size.height * .73) - text.height / 2,
      ),
    );
    text.dispose();
    canvas.save();
    canvas.scale(size.width, size.height);
    final eraser = Paint()
      ..blendMode = BlendMode.clear
      ..strokeCap = StrokeCap.round;
    for (final stroke in mask.strokes) {
      eraser.strokeWidth = stroke[4] * 2;
      canvas.drawLine(
        Offset(stroke[0], stroke[1]),
        Offset(stroke[2], stroke[3]),
        eraser,
      );
      canvas.drawCircle(Offset(stroke[2], stroke[3]), stroke[4], eraser);
    }
    canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(_FoilPainter oldDelegate) => true;
}
