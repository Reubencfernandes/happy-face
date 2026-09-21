import 'package:flutter/material.dart';

import '../app/session.dart';
import '../data/local_db.dart';
import 'format.dart';
import 'photo_thumb.dart';
import 'photo_viewer.dart';

/// One day that has photos: what to show in the square, and where that day
/// starts in the full list so the viewer can open there.
class _Day {
  final TimelineItem cover;
  final int index;
  final int count;
  const _Day(this.cover, this.index, this.count);
}

class _Month {
  final int year;
  final int month;
  final Map<int, _Day> days;
  const _Month(this.year, this.month, this.days);
}

/// The year at a glance: every month as a calendar, with the day's photo in
/// the square. Days with nothing stay empty, so gaps are as visible as
/// memories.
class CalendarView extends StatefulWidget {
  final Session session;
  final EdgeInsets padding;

  const CalendarView({
    super.key,
    required this.session,
    this.padding = EdgeInsets.zero,
  });

  @override
  State<CalendarView> createState() => _CalendarViewState();
}

class _CalendarViewState extends State<CalendarView> {
  static const _gap = 6.0;

  List<TimelineItem> _items = const [];
  List<_Month> _months = const [];
  int _revision = -1;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_onSession);
    _reload();
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSession);
    super.dispose();
  }

  void _onSession() {
    if (widget.session.revision != _revision) _reload();
  }

  void _reload() {
    final items = widget.session.db.timeline(limit: 1 << 30);
    final months = <String, _Month>{};
    for (var i = 0; i < items.length; i++) {
      final taken = items[i].localTakenAt;
      final key = '${taken.year}-${taken.month}';
      final month = months.putIfAbsent(
        key,
        () => _Month(taken.year, taken.month, {}),
      );
      final day = month.days[taken.day];
      // Newest first, so the first photo seen for a day is its cover.
      month.days[taken.day] = day == null
          ? _Day(items[i], i, 1)
          : _Day(day.cover, day.index, day.count + 1);
    }
    setState(() {
      _revision = widget.session.revision;
      _items = items;
      _months = months.values.toList();
    });
  }

  void _open(int index) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => PhotoViewer(
        session: widget.session,
        items: _items,
        initialIndex: index,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_months.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'Photos will fill in this calendar as you back them up.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final width =
            constraints.maxWidth - widget.padding.horizontal - _gap * 6;
        final cell = width / 7;
        return ListView.builder(
          padding: widget.padding.copyWith(bottom: widget.padding.bottom + 96),
          itemCount: _months.length,
          itemBuilder: (context, i) => _MonthSection(
            month: _months[i],
            cell: cell,
            gap: _gap,
            session: widget.session,
            onOpen: _open,
          ),
        );
      },
    );
  }
}

class _MonthSection extends StatelessWidget {
  final _Month month;
  final double cell;
  final double gap;
  final Session session;
  final void Function(int index) onOpen;

  const _MonthSection({
    required this.month,
    required this.cell,
    required this.gap,
    required this.session,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final first = DateTime(month.year, month.month);
    // Sunday starts the week, as the calendar squares are laid out.
    final leading = first.weekday % 7;
    final length = DateTime(month.year, month.month + 1, 0).day;
    final rows = ((leading + length) / 7).ceil();
    final today = DateTime.now();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(4, gap * 3, 4, gap * 2),
          child: Text(
            '${monthName(month.month)} ${month.year}',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        for (var row = 0; row < rows; row++)
          Padding(
            padding: EdgeInsets.only(bottom: gap),
            child: Row(
              children: [
                for (var column = 0; column < 7; column++) ...[
                  if (column > 0) SizedBox(width: gap),
                  SizedBox(
                    width: cell,
                    height: cell,
                    child: switch (row * 7 + column - leading + 1) {
                      final day when day >= 1 && day <= length => _DayCell(
                        day: day,
                        entry: month.days[day],
                        session: session,
                        isToday:
                            today.year == month.year &&
                            today.month == month.month &&
                            today.day == day,
                        onOpen: onOpen,
                      ),
                      _ => null,
                    },
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _DayCell extends StatelessWidget {
  final int day;
  final _Day? entry;
  final Session session;
  final bool isToday;
  final void Function(int index) onOpen;

  const _DayCell({
    required this.day,
    required this.entry,
    required this.session,
    required this.isToday,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entry = this.entry;
    final radius = BorderRadius.circular(12);
    return Semantics(
      button: entry != null,
      label: entry == null
          ? 'Day $day, no photos'
          : 'Day $day, ${entry.count} ${entry.count == 1 ? 'photo' : 'photos'}',
      child: GestureDetector(
        onTap: entry == null ? null : () => onOpen(entry.index),
        child: Container(
          decoration: BoxDecoration(
            color: entry == null
                ? theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.4,
                  )
                : null,
            borderRadius: radius,
            border: isToday
                ? Border.all(color: theme.colorScheme.primary, width: 2)
                : null,
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (entry != null)
                ClipRRect(
                  borderRadius: radius,
                  child: PhotoThumb(
                    key: ValueKey(entry.cover.key),
                    session: session,
                    item: entry.cover,
                    showBadge: false,
                    radius: 12,
                  ),
                ),
              Center(
                child: Text(
                  '$day',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: entry == null
                        ? theme.colorScheme.onSurfaceVariant
                        : Colors.white,
                    fontWeight: entry == null
                        ? FontWeight.w400
                        : FontWeight.w600,
                    shadows: entry == null
                        ? null
                        : const [Shadow(blurRadius: 6, color: Colors.black87)],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
