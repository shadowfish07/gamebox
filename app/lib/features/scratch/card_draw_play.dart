import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design_system/generated/gamebox_tokens.g.dart';
import 'card_draw_flow.dart';
import 'blank_draw_card.dart';
import 'duplicate_collection_feedback.dart';
import 'scratch_controller.dart';
import 'scratch_surface.dart';
import 'scratch_reveal_effect.dart';

Duration cardRevealDuration(int rarity) => [
  GameboxTokens.motion.pageEnter,
  GameboxTokens.motion.slow * 2 + GameboxTokens.motion.fast,
  GameboxTokens.motion.slow * 4,
  GameboxTokens.motion.pageEnter * 5,
][rarity];

class CardDrawPlay extends StatefulWidget {
  const CardDrawPlay({super.key, required this.flow, required this.onDetail});
  final CardDrawFlow flow;
  final ValueChanged<ScratchCollectible> onDetail;
  @override
  State<CardDrawPlay> createState() => _CardDrawPlayState();
}

class _CardDrawPlayState extends State<CardDrawPlay> {
  bool pressed = false;
  final _recentAnchor = GlobalKey();
  final _stageAnchor = GlobalKey();

  Offset? _flightTarget() {
    final recent = _recentAnchor.currentContext?.findRenderObject();
    final stage = _stageAnchor.currentContext?.findRenderObject();
    if (recent is! RenderBox ||
        stage is! RenderBox ||
        !recent.hasSize ||
        !stage.hasSize)
      return null;
    return recent.localToGlobal(Offset(22, recent.size.height / 2)) -
        stage.localToGlobal(stage.size.center(Offset.zero));
  }

  @override
  Widget build(BuildContext context) {
    final flow = widget.flow;
    final collection = flow.collection;
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final busy = flow.phase == CardDrawPhase.saving;
    final revealing = flow.phase == CardDrawPhase.revealing;
    final celebrating = flow.phase == CardDrawPhase.celebrating;
    final returning = flow.phase == CardDrawPhase.returning;
    final enabled = flow.canDraw;
    final label = busy
        ? '正在保存'
        : revealing
        ? '正在翻牌'
        : celebrating
        ? '恭喜抽中'
        : flow.phase == CardDrawPhase.collecting
        ? '正在收卡'
        : flow.current == null
        ? '抽一张'
        : '再抽一张';
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: GameboxTokens.spacing.page),
      child: Column(
        children: [
          Row(
            children: [
              Icon(
                Icons.collections_bookmark_outlined,
                color: scheme.primary,
                size: GameboxTokens.spacing.page,
              ),
              SizedBox(width: GameboxTokens.spacing.compact),
              Text('收藏进度', style: text.labelLarge),
              const Spacer(),
              AnimatedSwitcher(
                key: const Key('scratch-progress'),
                duration: GameboxTokens.motion.standard,
                child: Text(
                  '${collection.collected} / ${scratchCollectibles.length}',
                  key: ValueKey('scratch-progress-${collection.collected}'),
                  style: text.titleMedium?.copyWith(color: scheme.primary),
                ),
              ),
            ],
          ),
          SizedBox(height: GameboxTokens.spacing.compact),
          SizedBox(
            height:
                GameboxTokens.components.minimumTouchTarget +
                GameboxTokens.spacing.compact,
            child: Row(
              children: [
                Text(
                  '最近获得',
                  style: text.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                SizedBox(width: GameboxTokens.spacing.layout),
                Expanded(
                  key: _recentAnchor,
                  child: flow.recent.isEmpty
                      ? const SizedBox.expand()
                      : ListView.separated(
                          key: const Key('draw-recent'),
                          scrollDirection: Axis.horizontal,
                          itemCount: flow.recent.length,
                          separatorBuilder: (_, _) =>
                              SizedBox(width: GameboxTokens.spacing.compact),
                          itemBuilder: (_, i) {
                            final result = flow.recent[i];
                            return GestureDetector(
                              onTap: () => widget.onDetail(result.card),
                              child: AspectRatio(
                                aspectRatio: .8,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: ScratchArt
                                        .rarityColors[result.card.rarity],
                                    borderRadius: BorderRadius.circular(
                                      GameboxTokens.shape.input,
                                    ),
                                  ),
                                  child: Padding(
                                    padding: EdgeInsets.all(
                                      GameboxTokens.spacing.base,
                                    ),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(
                                        GameboxTokens.shape.input,
                                      ),
                                      child: CollectibleArtwork(
                                        cat: result.card,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = math
                    .min(
                      320.0,
                      math.min(
                        constraints.maxWidth - 24,
                        (constraints.maxHeight - 32) * .73,
                      ),
                    )
                    .clamp(90.0, 320.0);
                return Stack(
                  clipBehavior: Clip.none,
                  fit: StackFit.expand,
                  children: [
                    if (revealing &&
                        flow.current?.winning == true &&
                        flow.current?.card.rarity == 3)
                      TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0, end: 1),
                        duration: cardRevealDuration(3),
                        builder: (_, t, _) => DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(
                              GameboxTokens.shape.floating,
                            ),
                            color: scheme.scrim.withValues(
                              alpha: math.sin(t * math.pi) * .22,
                            ),
                          ),
                        ),
                      ),
                    Center(
                      child: GestureDetector(
                        onTap: !enabled
                            ? null
                            : flow.current == null
                            ? flow.primary
                            : flow.current!.winning
                            ? () => widget.onDetail(flow.current!.card)
                            : flow.primary,
                        child: SizedBox(
                          key: _stageAnchor,
                          width: width,
                          child: CardDrawStage(
                            flightTarget: _flightTarget(),
                            key: ValueKey(
                              'draw-stage-${flow.current?.serial ?? 0}',
                            ),
                            result: flow.current,
                            playing: revealing,
                            collecting: flow.phase == CardDrawPhase.collecting,
                            waiting: busy,
                            onRevealed: flow.finishReveal,
                            onStory: flow.current?.winning == true
                                ? () => widget.onDetail(flow.current!.card)
                                : null,
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          SizedBox(height: GameboxTokens.spacing.compact),
          SizedBox(
            height: GameboxTokens.spacing.section,
            child: Center(
              child: Text(
                '免费抽卡',
                style: text.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          SizedBox(
            width: double.infinity,
            child: Listener(
              onPointerDown: (_) {
                if (widget.flow.canDraw) setState(() => pressed = true);
              },
              onPointerUp: (_) => setState(() => pressed = false),
              onPointerCancel: (_) => setState(() => pressed = false),
              child: AnimatedScale(
                scale: pressed && enabled ? .97 : 1,
                duration: GameboxTokens.motion.fast,
                child: FilledButton(
                  key: const Key('scratch-primary'),
                  onPressed: !enabled
                      ? null
                      : () {
                          HapticFeedback.selectionClick();
                          flow.primary();
                        },
                  style: FilledButton.styleFrom(
                    animationDuration: GameboxTokens.motion.standard,
                    disabledBackgroundColor: celebrating
                        ? scheme.primaryContainer
                        : returning
                        ? scheme.primary
                        : null,
                    disabledForegroundColor: celebrating
                        ? scheme.onPrimaryContainer
                        : returning
                        ? scheme.onPrimary
                        : null,
                  ),
                  child: AnimatedSwitcher(
                    duration: GameboxTokens.motion.standard,
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, .25),
                          end: Offset.zero,
                        ).animate(animation),
                        child: child,
                      ),
                    ),
                    child: Row(
                      key: ValueKey(label),
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          celebrating
                              ? Icons.auto_awesome
                              : Icons.style_outlined,
                        ),
                        SizedBox(width: GameboxTokens.spacing.compact),
                        Text(label),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          SizedBox(height: GameboxTokens.spacing.layout),
        ],
      ),
    );
  }
}

Widget _newLabel(BuildContext context) => DecoratedBox(
  decoration: BoxDecoration(
    color: Theme.of(context).colorScheme.primaryContainer,
    borderRadius: BorderRadius.circular(GameboxTokens.shape.input),
  ),
  child: Padding(
    padding: EdgeInsets.symmetric(
      horizontal: GameboxTokens.spacing.compact,
      vertical: GameboxTokens.spacing.base,
    ),
    child: Text(
      'NEW',
      style: Theme.of(context).textTheme.labelSmall
          ?.copyWith(color: Theme.of(context).colorScheme.onPrimaryContainer),
    ),
  ),
);

class CardDrawStage extends StatefulWidget {
  const CardDrawStage({
    super.key,
    required this.result,
    required this.playing,
    required this.collecting,
    required this.waiting,
    required this.onRevealed,
    this.flightTarget,
    this.onStory,
  });
  final CardDrawResult? result;
  final bool playing, collecting, waiting;
  final VoidCallback onRevealed;
  final VoidCallback? onStory;
  final Offset? flightTarget;
  @override
  State<CardDrawStage> createState() => _CardDrawStageState();
}

class _CardDrawStageState extends State<CardDrawStage>
    with TickerProviderStateMixin {
  late final AnimationController _reveal = AnimationController(
    vsync: this,
    duration: cardRevealDuration(
      (widget.result?.winning == true ? widget.result!.card.rarity : 0),
    ),
  );
  late final AnimationController _collect = AnimationController(
    vsync: this,
    duration: GameboxTokens.motion.standard,
  );
  late final AnimationController _duplicate = AnimationController(
    vsync: this,
    duration: GameboxTokens.motion.slow * 2,
    value: widget.playing ? 0 : 1,
  );
  bool _duplicateStarted = false;
  bool _sounded = false;
  @override
  void initState() {
    super.initState();
    _reveal.addListener(() {
      if (!_duplicateStarted &&
          widget.playing &&
          widget.result?.winning == true &&
          !widget.result!.isNew &&
          _reveal.value >= .64) {
        _duplicateStarted = true;
        _duplicate.forward();
      }
      if (!_sounded &&
          widget.playing &&
          widget.result?.winning == true &&
          _reveal.value >= .5) {
        _sounded = true;
        SystemSound.play(SystemSoundType.click);
        switch ((widget.result?.winning == true
            ? widget.result!.card.rarity
            : 0)) {
          case 3:
            HapticFeedback.heavyImpact();
          case 2:
            HapticFeedback.mediumImpact();
          default:
            HapticFeedback.lightImpact();
        }
      }
    });
    _reveal.addStatusListener((status) {
      if (status == AnimationStatus.completed && widget.playing)
        widget.onRevealed();
    });
    if (widget.playing) {
      _reveal.forward();
    } else {
      _reveal.value = 1;
    }
  }

  @override
  void didUpdateWidget(CardDrawStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.playing && oldWidget.playing) {
      // A skipped reveal settles immediately; a natural reveal lets the small
      // card finish landing without delaying the next draw.
      if (!_reveal.isCompleted) _duplicate.value = 1;
      _reveal.stop();
    }
    if (widget.collecting) _duplicate.value = 1;
    if (widget.collecting && !oldWidget.collecting) _collect.forward(from: 0);
    if (!widget.collecting) _collect.value = 0;
  }

  @override
  void dispose() {
    _reveal.dispose();
    _collect.dispose();
    _duplicate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([_reveal, _collect, _duplicate]),
    builder: (context, _) {
      final t = widget.playing ? _reveal.value : 1.0;
      final flip = ((t - .14) / .5).clamp(0.0, 1.0);
      final front = widget.result != null && !widget.waiting && flip >= .5;
      final angle = !widget.playing
          ? 0.0
          : front
          ? (1 - flip) * math.pi
          : -flip * math.pi;
      final flight = Curves.easeInCubic.transform(_collect.value);
      return LayoutBuilder(
        builder: (context, constraints) {
          final target =
              widget.flightTarget ??
              Offset(-constraints.maxWidth * .36, -constraints.maxWidth * .85);
          return CustomPaint(
            painter: widget.collecting && widget.result!.isNew
                ? _NewCardTrail(
                    target,
                    flight,
                    ScratchArt.rarityColors[widget.result!.card.rarity],
                  )
                : null,
            child: Transform.translate(
              offset:
                  (widget.result?.winning == true
                      ? target * flight
                      : Offset(0, 12 * flight)) +
                  Offset(
                    0,
                    math.min(12.0, constraints.maxWidth * .06) * (1 - t),
                  ),
              child: Transform.scale(
                scale:
                    1 - flight * (widget.result?.winning == true ? .82 : .08),
                child: Opacity(
                  opacity: 1 - flight * .7,
                  child: Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()
                      ..setEntry(3, 2, .0008)
                      ..rotateY(angle),
                    child: AspectRatio(
                      aspectRatio: .73,
                      child: front
                          ? _front(context, flip == 1 || t > .4)
                          : _back(context),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
    },
  );

  Widget _front(BuildContext context, bool revealed) {
    final result = widget.result!;
    if (!result.winning) return _miss(context);
    final color = ScratchArt.rarityColors[result.card.rarity];
    final text = Theme.of(context).textTheme;
    return DecoratedBox(
      key: const Key('draw-card-front'),
      decoration: BoxDecoration(
        color: ScratchArt.paper,
        borderRadius: BorderRadius.circular(GameboxTokens.shape.card),
        border: Border.all(color: color, width: GameboxTokens.spacing.base),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: .24),
            blurRadius: 22,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Padding(
        padding: EdgeInsets.all(GameboxTokens.spacing.compact),
        child: Column(
          children: [
            DecoratedBox(
              key: const Key('scratch-rarity-banner'),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(GameboxTokens.shape.input),
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: GameboxTokens.spacing.compact,
                  vertical: GameboxTokens.spacing.base,
                ),
                child: Row(
                  children: [
                    Icon(
                      ScratchArt.rarityIcons[result.card.rarity],
                      color: ScratchArt.onRarity,
                      size: GameboxTokens.spacing.page,
                    ),
                    SizedBox(width: GameboxTokens.spacing.base),
                    Flexible(
                      child: Text(
                        '${scratchRarities[result.card.rarity]}收藏',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.labelSmall?.copyWith(
                          color: ScratchArt.onRarity,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(height: GameboxTokens.spacing.compact),
            Expanded(
              child: Center(
                child: AspectRatio(
                  aspectRatio: 1,
                  child: ScratchRevealEffect(
                    revealed: revealed,
                    rarity: result.card.rarity,
                    enabled: widget.playing,
                    playOnMount: widget.playing,
                    duration: cardRevealDuration(result.card.rarity) * .58,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(
                        GameboxTokens.shape.input,
                      ),
                      child: CollectibleArtwork(cat: result.card),
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(height: GameboxTokens.spacing.compact),
            Text(
              '${result.card.job} · ${result.card.name}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.titleSmall?.copyWith(color: ScratchArt.ink),
            ),
            SizedBox(height: GameboxTokens.spacing.base),
            SizedBox(
              height: GameboxTokens.components.minimumTouchTarget,
              child: result.isNew
                  ? Row(
                      children: [
                        Expanded(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Row(
                              children: [
                                _newLabel(context),
                                SizedBox(width: GameboxTokens.spacing.base),
                                Text(
                                  '首次相遇',
                                  style: text.labelSmall?.copyWith(
                                    color: ScratchArt.ink,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        DrawStoryButton(onPressed: widget.onStory),
                      ],
                    )
                  : DuplicateCollectionFeedback(
                      count: result.count,
                      progress: _duplicate.value,
                      onStory: widget.onStory,
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _miss(BuildContext context) => BlankDrawCard(
    key: const Key('draw-empty-result'),
    serial: widget.result!.serial,
    reveal: widget.playing ? _reveal.value : 1,
  );

  Widget _back(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final tier = widget.result?.winning == true
        ? widget.result!.card.rarity
        : null;
    final tint = widget.playing && tier != null
        ? ScratchArt.rarityColors[tier]
        : scheme.primary;
    return DecoratedBox(
      key: const Key('draw-card-back'),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(GameboxTokens.shape.card),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.primaryContainer, scheme.surfaceContainerHigh],
        ),
        border: Border.all(color: tint, width: GameboxTokens.spacing.base),
        boxShadow: widget.playing
            ? [
                BoxShadow(
                  color: tint.withValues(alpha: .4),
                  blurRadius: 26,
                  spreadRadius: 3,
                ),
              ]
            : null,
      ),
      child: Padding(
        padding: EdgeInsets.all(GameboxTokens.spacing.layout),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: scheme.primary.withValues(alpha: .3)),
            borderRadius: BorderRadius.circular(GameboxTokens.shape.input),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.auto_awesome,
                color: tint,
                size: GameboxTokens.spacing.section,
              ),
              SizedBox(height: GameboxTokens.spacing.section),
              Icon(
                Icons.pets,
                color: scheme.onPrimaryContainer,
                size: GameboxTokens.components.minimumTouchTarget,
              ),
              SizedBox(height: GameboxTokens.spacing.layout),
              Text(
                '百 业 收 藏',
                style: text.titleMedium?.copyWith(
                  color: scheme.onPrimaryContainer,
                ),
              ),
              SizedBox(height: GameboxTokens.spacing.section),
              Text(
                widget.waiting ? '正在保存' : '下一位，会是谁？',
                style: text.labelSmall?.copyWith(
                  color: scheme.onPrimaryContainer,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NewCardTrail extends CustomPainter {
  _NewCardTrail(this.target, this.progress, this.color);
  final Offset target;
  final double progress;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0 || progress >= 1) return;
    final start =
        size.center(Offset.zero) + target * math.max(0, progress - .4);
    final end = size.center(Offset.zero) + target * progress;
    final fade = math.sin(progress * math.pi);
    canvas.drawLine(
      start,
      end,
      Paint()
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 16 * fade
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4)
        ..shader = LinearGradient(
          colors: [
            color.withValues(alpha: 0),
            color.withValues(alpha: .6 * fade),
          ],
          begin: Alignment.bottomRight,
          end: Alignment.topLeft,
        ).createShader(Rect.fromPoints(start, end).inflate(1)),
    );
  }

  @override
  bool shouldRepaint(_NewCardTrail oldDelegate) =>
      progress != oldDelegate.progress ||
      target != oldDelegate.target ||
      color != oldDelegate.color;
}
