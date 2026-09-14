import 'package:flutter/material.dart';

import 'battleship_models.dart';

/// Dense playfield cells are the game-owned exception to 48dp public controls.
/// The entire cell is hittable; firing still requires the separate confirm button.
final class BattleshipBoard extends StatelessWidget {
  const BattleshipBoard({
    super.key,
    required this.ships,
    required this.shots,
    this.selected,
    this.preview,
    this.onCell,
    this.pending = false,
  });
  final List<FleetShip> ships;
  final List<FleetShot> shots;
  final int? selected;
  final FleetShip? preview;
  final ValueChanged<int>? onCell;
  final bool pending;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AspectRatio(
      aspectRatio: 1,
      child: LayoutBuilder(
        builder: (context, box) {
          final cell = box.maxWidth / 11;
          return Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _SeaPainter(
                    scheme,
                    Theme.of(context).textTheme.labelSmall!,
                    ships,
                    shots,
                    selected,
                    preview,
                    pending,
                  ),
                ),
              ),
              for (var i = 0; i < 100; i++)
                Positioned(
                  left: cell * (i % 10 + 1),
                  top: cell * (i ~/ 10 + 1),
                  width: cell,
                  height: cell,
                  child: Semantics(
                    identifier: 'sea-cell-$i',
                    child: GestureDetector(
                      key: ValueKey('sea-cell-$i'),
                      behavior: HitTestBehavior.opaque,
                      onTap: onCell == null ? null : () => onCell!(i),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

final class _SeaPainter extends CustomPainter {
  _SeaPainter(
    this.colors,
    this.label,
    this.ships,
    this.shots,
    this.selected,
    this.preview,
    this.pending,
  );
  final ColorScheme colors;
  final TextStyle label;
  final List<FleetShip> ships;
  final List<FleetShot> shots;
  final int? selected;
  final FleetShip? preview;
  final bool pending;
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.width / 11;
    Rect rect(int cell) =>
        Rect.fromLTWH((cell % 10 + 1) * c, (cell ~/ 10 + 1) * c, c, c);
    canvas.drawRect(
      Rect.fromLTWH(c, c, 10 * c, 10 * c),
      Paint()..color = colors.surfaceContainerLow,
    );
    for (final ship in ships) {
      for (final cell in ship.cells) {
        canvas.drawRect(
          rect(cell).deflate(c * .08),
          Paint()
            ..color = pending
                ? colors.primaryContainer
                : colors.secondaryContainer,
        );
      }
    }
    if (preview case final ship?) {
      for (final cell in ship.cells) {
        if (cell < 100) {
          canvas.drawRect(
            rect(cell).deflate(c * .08),
            Paint()..color = colors.primaryContainer,
          );
        }
      }
    }
    final grid = Paint()
      ..color = colors.outlineVariant
      ..strokeWidth = 1;
    for (var i = 1; i <= 11; i++) {
      canvas.drawLine(Offset(c * i, c), Offset(c * i, 11 * c), grid);
      canvas.drawLine(Offset(c, c * i), Offset(11 * c, c * i), grid);
    }
    for (var i = 0; i < 10; i++) {
      _text(
        canvas,
        '${i + 1}',
        Offset((i + 1.5) * c, c * .5),
        colors.onSurfaceVariant,
      );
      _text(
        canvas,
        String.fromCharCode(65 + i),
        Offset(c * .5, (i + 1.5) * c),
        colors.onSurfaceVariant,
      );
    }
    for (final ship in ships) {
      final hit = ship.cells.every(
        (c) => shots.any((s) => s.cell == c && s.hit),
      );
      {
        final a = rect(ship.cells.first), b = rect(ship.cells.last);
        canvas.drawRect(
          a.expandToInclude(b).deflate(c * .08),
          Paint()
            ..color = preview?.id == ship.id ? colors.primary : colors.secondary
            ..style = PaintingStyle.stroke
            ..strokeWidth = hit || preview?.id == ship.id ? 3 : 1.5,
        );
      }
    }
    for (final shot in shots) {
      final r = rect(shot.cell),
          p = Paint()
            ..color = shot.hit
                ? colors.onSecondaryContainer
                : colors.onSurfaceVariant
            ..strokeWidth = 2;
      if (shot.hit) {
        canvas.drawLine(
          r.topLeft + Offset(c * .3, c * .3),
          r.bottomRight - Offset(c * .3, c * .3),
          p,
        );
        canvas.drawLine(
          r.topRight + Offset(-c * .3, c * .3),
          r.bottomLeft + Offset(c * .3, -c * .3),
          p,
        );
      } else {
        canvas.drawCircle(r.center, c * .09, p);
      }
    }
    if (selected case final cell?) {
      final r = rect(cell).deflate(2);
      canvas.drawRect(
        r,
        Paint()
          ..color = colors.primary
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );
      if (pending) {
        canvas.drawCircle(
          r.center,
          c * .19,
          Paint()
            ..color = colors.primary
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
    }
  }

  void _text(Canvas canvas, String text, Offset center, Color color) {
    final p = TextPainter(
      text: TextSpan(
        text: text,
        style: label.copyWith(color: color),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    p.paint(canvas, center - Offset(p.width / 2, p.height / 2));
  }

  @override
  bool shouldRepaint(covariant _SeaPainter oldDelegate) => true;
}
