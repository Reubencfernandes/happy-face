import 'package:flutter/material.dart';

/// A placeholder in the shape of the thing that is coming.
///
/// Used instead of a spinner where the layout is known in advance: measuring
/// storage means one request per bucket, so the wait is long enough that a
/// lone spinner says nothing about what will appear. Blocks in the right
/// places do, and the card doesn't jump when the numbers arrive.
class Skeleton extends StatefulWidget {
  final double? width;
  final double height;
  final double radius;

  /// Staggers the sweep, so a stack of blocks reads as one surface being
  /// lit rather than several things flashing at once.
  final double delay;

  /// A share of the width it is given, for a line of text whose length is
  /// only known once the text is there.
  final double? widthFactor;

  const Skeleton({
    super.key,
    this.width,
    this.widthFactor,
    this.height = 14,
    this.radius = 7,
    this.delay = 0,
  });

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void initState() {
    super.initState();
    _sweep.repeat();
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = scheme.surfaceContainerHighest.withValues(alpha: 0.5);
    final lit = scheme.surfaceContainerHighest.withValues(alpha: 0.9);
    // Someone who has asked for less motion gets the block without the sweep.
    final still = MediaQuery.disableAnimationsOf(context);

    Widget block = AnimatedBuilder(
      animation: _sweep,
      builder: (context, _) {
        final t = ((_sweep.value + widget.delay) % 1) * 2 - 0.5;
        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius),
            gradient: still
                ? null
                : LinearGradient(
                    begin: Alignment(t - 0.6, 0),
                    end: Alignment(t + 0.6, 0),
                    colors: [base, lit, base],
                  ),
            color: still ? base : null,
          ),
          child: SizedBox(width: widget.width, height: widget.height),
        );
      },
    );
    final factor = widget.widthFactor;
    if (factor != null) {
      block = FractionallySizedBox(
        alignment: Alignment.centerLeft,
        widthFactor: factor.clamp(0.0, 1.0),
        child: block,
      );
    }
    return Semantics(label: 'Loading', child: block);
  }
}
