import 'dart:math';

import 'package:flutter/material.dart';

import 'format.dart';

/// Colours for the storage bar, in a fixed order that is never cycled: the
/// first bucket always wears the first colour, so a bucket keeps its colour
/// when another appears or disappears. Checked for colour-blind separation
/// against the app's ink background.
///
/// Anything past the fourth slot belongs in an "Other" segment drawn in
/// [mutedUsageColor], not in a made-up fifth hue.
const _slots = [
  Color(0xFFC4802B),
  Color(0xFF0EA396),
  Color(0xFF6D7DF0),
  Color(0xFFE05590),
];

List<Color> usageColors() => _slots;

Color mutedUsageColor(ColorScheme scheme) =>
    scheme.onSurfaceVariant.withValues(alpha: 0.45);

/// How many segments get their own colour before the rest are pooled.
const usageColorSlots = 4;

class UsageSegment {
  final String label;
  final int bytes;
  final Color color;

  /// A short aside shown beside the label, e.g. "this app".
  final String? note;

  const UsageSegment({
    required this.label,
    required this.bytes,
    required this.color,
    this.note,
  });
}

/// A single bar split into [segments], largest first, with a hairline of
/// background between them so neighbouring colours never touch.
class UsageBar extends StatelessWidget {
  final List<UsageSegment> segments;

  /// The width the bar stands for. Bigger than the segments' sum makes this
  /// a meter — a disk gauge — with the rest left as empty track. Null means
  /// the segments fill it, showing shares of what is stored.
  final int? total;
  final double height;
  final double gap;

  const UsageBar({
    super.key,
    required this.segments,
    this.total,
    this.height = 16,
    this.gap = 2,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final track = scheme.surfaceContainerHighest;
    final radius = BorderRadius.circular(height / 2);
    final shown = segments.where((s) => s.bytes > 0).toList();
    final stored = shown.fold(0, (sum, s) => sum + s.bytes);
    // A meter never overflows: an allowance already spent still reads full.
    final total = this.total == null || this.total! < stored
        ? stored
        : this.total!;
    if (total == 0) {
      return Semantics(
        label: 'Nothing stored yet',
        child: Container(
          height: height,
          decoration: BoxDecoration(color: track, borderRadius: radius),
        ),
      );
    }
    return Semantics(
      label: [
        for (final s in shown) '${s.label} ${storageSize(s.bytes)}',
      ].join(', '),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Every segment stays visible, even a sliver of an index file, so
          // widths get a floor and then shrink back to fit.
          const floor = 4.0;
          final room = max(
            0.0,
            constraints.maxWidth - gap * (shown.length - 1),
          );
          var widths = [
            for (final s in shown) max(floor, room * s.bytes / total),
          ];
          final over = widths.fold(0.0, (sum, w) => sum + w) - room;
          if (over > 0) {
            final slack = [for (final w in widths) max(0.0, w - floor)];
            final spare = slack.fold(0.0, (sum, s) => sum + s);
            if (spare > 0) {
              widths = [
                for (var i = 0; i < widths.length; i++)
                  widths[i] - over * slack[i] / spare,
              ];
            }
          }
          return ClipRRect(
            borderRadius: radius,
            child: SizedBox(
              height: height,
              child: Row(
                children: [
                  for (var i = 0; i < shown.length; i++) ...[
                    if (i > 0) SizedBox(width: gap),
                    Container(width: widths[i], color: shown[i].color),
                  ],
                  Expanded(child: ColoredBox(color: track)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// One line under a [UsageBar]: a colour chip, what it is, and how big.
class UsageLegendRow extends StatelessWidget {
  final UsageSegment segment;
  final int total;
  final String? trailing;
  final bool dense;

  const UsageLegendRow({
    super.key,
    required this.segment,
    required this.total,
    this.trailing,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final share = total == 0 ? 0 : (segment.bytes * 100 / total).round();
    return Padding(
      padding: EdgeInsets.symmetric(vertical: dense ? 3 : 5),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: segment.color,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(
                text: segment.label,
                children: [
                  if (segment.note != null)
                    TextSpan(
                      text: '  ${segment.note}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: dense
                  ? theme.textTheme.bodyMedium
                  : theme.textTheme.bodyLarge,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            trailing ?? '${storageSize(segment.bytes)} · $share%',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
