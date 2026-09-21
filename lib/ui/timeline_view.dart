import 'package:flutter/material.dart';

import '../app/session.dart';
import '../data/local_db.dart';
import 'format.dart';
import 'photo_thumb.dart';
import 'photo_viewer.dart';

/// Timeline items the user has selected, shared with the app bar.
class Selection extends ChangeNotifier {
  final Map<String, TimelineItem> items = {};
  bool _choosing = false;

  /// True while tiles show a tick — either because the user picked
  /// "Choose photos" or because they long-pressed one.
  bool get active => _choosing || items.isNotEmpty;
  int get length => items.length;
  bool contains(TimelineItem i) => items.containsKey(i.key);

  /// Turns on selection with nothing selected yet, so the next tap picks
  /// a photo instead of opening it.
  void start() {
    if (_choosing) return;
    _choosing = true;
    notifyListeners();
  }

  void toggle(TimelineItem i) {
    items.containsKey(i.key) ? items.remove(i.key) : items[i.key] = i;
    notifyListeners();
  }

  void addAll(Iterable<TimelineItem> all) {
    for (final i in all) {
      items[i.key] = i;
    }
    notifyListeners();
  }

  void clear() {
    if (items.isEmpty && !_choosing) return;
    items.clear();
    _choosing = false;
    notifyListeners();
  }
}

class TimelineOptions {
  final TimelineSort sort;
  final bool descending;
  final TimelineFilter filter;
  const TimelineOptions({
    this.sort = TimelineSort.taken,
    this.descending = true,
    this.filter = TimelineFilter.all,
  });

  TimelineOptions copyWith({
    TimelineSort? sort,
    bool? descending,
    TimelineFilter? filter,
  }) => TimelineOptions(
    sort: sort ?? this.sort,
    descending: descending ?? this.descending,
    filter: filter ?? this.filter,
  );
}

class TimelineView extends StatefulWidget {
  final Session session;
  final Selection selection;
  final TimelineOptions options;
  final String? country;
  final String? place;
  final Widget? emptyState;
  final EdgeInsets padding;

  const TimelineView({
    super.key,
    required this.session,
    required this.selection,
    this.options = const TimelineOptions(),
    this.country,
    this.place,
    this.emptyState,
    this.padding = EdgeInsets.zero,
  });

  @override
  State<TimelineView> createState() => _TimelineViewState();
}

sealed class _Row {}

class _Header extends _Row {
  final String label;
  final List<TimelineItem> section;
  _Header(this.label, this.section);
}

class _Cells extends _Row {
  final int start;
  final int count;
  _Cells(this.start, this.count);
}

class _TimelineViewState extends State<TimelineView> {
  static const _densities = [2, 4, 6];
  static const _headerHeight = 52.0;

  /// Portrait tiles, like the photos themselves.
  static const _tileAspect = 0.78;
  static const _gap = 3.0;

  final _scroll = ScrollController();
  List<TimelineItem> _items = const [];
  int _revision = -1;
  int _density = 1;

  // Layout cache.
  List<_Row> _rows = const [];
  List<double> _offsets = const [];
  double _layoutWidth = 0;
  int _layoutColumns = 0;
  List<TimelineItem>? _layoutItems;

  // Pinch detection.
  final _pointers = <int, Offset>{};
  double? _pinchStart;

  // Scrubber.
  bool _scrubbing = false;
  String _scrubLabel = '';

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_onSession);
    _reload();
  }

  @override
  void didUpdateWidget(TimelineView old) {
    super.didUpdateWidget(old);
    if (old.session != widget.session) {
      old.session.removeListener(_onSession);
      widget.session.addListener(_onSession);
    }
    if (old.options != widget.options ||
        old.country != widget.country ||
        old.place != widget.place) {
      _reload();
    }
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSession);
    _scroll.dispose();
    super.dispose();
  }

  void _onSession() {
    if (widget.session.revision != _revision) _reload();
  }

  void _reload() {
    final o = widget.options;
    setState(() {
      _revision = widget.session.revision;
      _items = widget.session.db.timeline(
        limit: 1 << 30,
        sort: o.sort,
        descending: o.descending,
        filter: o.filter,
        country: widget.country,
        place: widget.place,
      );
    });
  }

  int get _columns => _densities[_density];

  /// How tall one row of tiles is at this width.
  double _tileHeight(double width) => width / _columns / _tileAspect;

  void _layout(double width) {
    if (width == _layoutWidth &&
        _columns == _layoutColumns &&
        identical(_items, _layoutItems)) {
      return;
    }
    _layoutWidth = width;
    _layoutColumns = _columns;
    _layoutItems = _items;
    final byMonth = _columns > 4;
    final rows = <_Row>[];
    final offsets = <double>[];
    final tile = _tileHeight(width);
    var y = 0.0;
    var i = 0;
    while (i < _items.length) {
      final first = _items[i].localTakenAt;
      bool sameGroup(TimelineItem it) {
        final d = it.localTakenAt;
        return byMonth
            ? d.year == first.year && d.month == first.month
            : d.year == first.year &&
                  d.month == first.month &&
                  d.day == first.day;
      }

      var j = i;
      while (j < _items.length && sameGroup(_items[j])) {
        j++;
      }
      // Upload-date order can interleave days; consecutive runs are grouped.
      final section = _items.sublist(i, j);
      rows.add(_Header(byMonth ? monthLabel(first) : dayLabel(first), section));
      offsets.add(y);
      y += _headerHeight;
      for (var k = i; k < j; k += _columns) {
        rows.add(_Cells(k, (j - k).clamp(0, _columns)));
        offsets.add(y);
        y += tile;
      }
      i = j;
    }
    _rows = rows;
    _offsets = offsets;
  }

  void _changeDensity(int delta) {
    final next = (_density + delta).clamp(0, _densities.length - 1);
    if (next == _density) return;
    // Keep roughly the same photo at the top.
    final anchor = _itemIndexAt(_scroll.hasClients ? _scroll.offset : 0);
    setState(() => _density = next);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final row = _rows.indexWhere(
        (r) => r is _Cells && anchor >= r.start && anchor < r.start + r.count,
      );
      if (row >= 0) {
        _scroll.jumpTo(
          _offsets[row].clamp(0, _scroll.position.maxScrollExtent),
        );
      }
    });
  }

  int _rowAt(double offset) {
    var lo = 0, hi = _offsets.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) ~/ 2;
      if (_offsets[mid] <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  int _itemIndexAt(double offset) {
    if (_rows.isEmpty) return 0;
    for (var r = _rowAt(offset); r < _rows.length; r++) {
      final row = _rows[r];
      if (row is _Cells) return row.start;
    }
    return 0;
  }

  String _labelAt(double offset) {
    if (_items.isEmpty) return '';
    final d =
        _items[_itemIndexAt(offset).clamp(0, _items.length - 1)].localTakenAt;
    return '${shortMonth(d.month)} ${d.year}';
  }

  void _onPointerDown(PointerDownEvent e) {
    _pointers[e.pointer] = e.position;
    if (_pointers.length == 2) _pinchStart = _pinchDistance();
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.position;
    final start = _pinchStart;
    if (_pointers.length != 2 || start == null) return;
    final ratio = _pinchDistance() / start;
    if (ratio > 1.35) {
      _changeDensity(-1);
      _pinchStart = _pinchDistance();
    } else if (ratio < 0.7) {
      _changeDensity(1);
      _pinchStart = _pinchDistance();
    }
  }

  void _onPointerUp(PointerEvent e) {
    _pointers.remove(e.pointer);
    if (_pointers.length < 2) _pinchStart = null;
  }

  double _pinchDistance() {
    final p = _pointers.values.toList();
    return (p[0] - p[1]).distance;
  }

  void _open(int index) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PhotoViewer(
          session: widget.session,
          items: _items,
          initialIndex: index,
        ),
      ),
    );
  }

  void _scrubTo(double dy, double trackHeight) {
    if (!_scroll.hasClients) return;
    final max = _scroll.position.maxScrollExtent;
    final target = (dy / trackHeight).clamp(0.0, 1.0) * max;
    _scroll.jumpTo(target);
    setState(() => _scrubLabel = _labelAt(target));
  }

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty) {
      return widget.emptyState ??
          const Center(child: Text('No photos here yet'));
    }
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: widget.selection,
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth - widget.padding.horizontal;
          _layout(width);
          final tileWidth = width / _columns;
          final tile = _tileHeight(width);
          final selecting = widget.selection.active;
          return Listener(
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
            onPointerCancel: _onPointerUp,
            child: Stack(
              children: [
                ListView.builder(
                  controller: _scroll,
                  padding: widget.padding.copyWith(
                    bottom: widget.padding.bottom + 96,
                  ),
                  itemCount: _rows.length,
                  itemExtentBuilder: (i, _) =>
                      _rows[i] is _Header ? _headerHeight : tile,
                  itemBuilder: (context, i) => switch (_rows[i]) {
                    _Header(:final label, :final section) => _SectionHeader(
                      label: label,
                      selecting: selecting,
                      allSelected: section.every(widget.selection.contains),
                      onSelectAll: () =>
                          section.every(widget.selection.contains)
                          ? section.forEach(widget.selection.toggle)
                          : widget.selection.addAll(section),
                    ),
                    _Cells(:final start, :final count) => Row(
                      children: [
                        for (var c = 0; c < _columns; c++)
                          SizedBox(
                            width: tileWidth,
                            height: tile,
                            child: c >= count
                                ? null
                                : Padding(
                                    padding: const EdgeInsets.all(_gap),
                                    child: _tile(start + c, selecting),
                                  ),
                          ),
                      ],
                    ),
                  },
                ),
                if (_rows.length > 40)
                  _Scrubber(
                    controller: _scroll,
                    active: _scrubbing,
                    label: _scrubLabel,
                    color: theme.colorScheme.primary,
                    onStart: (dy, h) {
                      setState(() => _scrubbing = true);
                      _scrubTo(dy, h);
                    },
                    onUpdate: _scrubTo,
                    onEnd: () => setState(() => _scrubbing = false),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _tile(int index, bool selecting) {
    final item = _items[index];
    final selected = widget.selection.contains(item);
    return GestureDetector(
      onTap: () => selecting ? widget.selection.toggle(item) : _open(index),
      onLongPress: () => widget.selection.toggle(item),
      child: Semantics(
        button: true,
        selected: selected,
        label: 'Photo from ${dayLabel(item.localTakenAt)}',
        child: PhotoThumb(
          key: ValueKey(item.key),
          session: widget.session,
          item: item,
          selected: selected,
          selecting: selecting,
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  final bool selecting;
  final bool allSelected;
  final VoidCallback onSelectAll;
  const _SectionHeader({
    required this.label,
    required this.selecting,
    required this.allSelected,
    required this.onSelectAll,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 4, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (selecting)
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: allSelected ? 'Deselect day' : 'Select day',
              icon: Icon(
                allSelected ? Icons.check_circle : Icons.radio_button_unchecked,
                size: 20,
              ),
              onPressed: onSelectAll,
            ),
        ],
      ),
    );
  }
}

class _Scrubber extends StatefulWidget {
  final ScrollController controller;
  final bool active;
  final String label;
  final Color color;
  final void Function(double dy, double height) onStart;
  final void Function(double dy, double height) onUpdate;
  final VoidCallback onEnd;
  const _Scrubber({
    required this.controller,
    required this.active,
    required this.label,
    required this.color,
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
  });

  @override
  State<_Scrubber> createState() => _ScrubberState();
}

class _ScrubberState extends State<_Scrubber> {
  static const _handle = 44.0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_tick);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_tick);
    super.dispose();
  }

  void _tick() => setState(() {});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 0,
      bottom: 0,
      right: 0,
      width: widget.active ? 180 : 40,
      child: LayoutBuilder(
        builder: (context, c) {
          final track = c.maxHeight - _handle;
          final position =
              widget.controller.hasClients &&
                  widget.controller.position.maxScrollExtent > 0
              ? widget.controller.offset /
                    widget.controller.position.maxScrollExtent
              : 0.0;
          final top = position.clamp(0.0, 1.0) * track;
          // Drags are measured against the fixed track, not the moving handle.
          double dy(Offset local) => (local.dy - _handle / 2).clamp(0.0, track);
          return GestureDetector(
            behavior: HitTestBehavior.translucent,
            onVerticalDragStart: (d) =>
                widget.onStart(dy(d.localPosition), track),
            onVerticalDragUpdate: (d) =>
                widget.onUpdate(dy(d.localPosition), track),
            onVerticalDragEnd: (_) => widget.onEnd(),
            onVerticalDragCancel: widget.onEnd,
            child: Stack(
              children: [
                if (widget.active && widget.label.isNotEmpty)
                  Positioned(
                    right: 46,
                    top: top + 4,
                    child: Material(
                      color: widget.color,
                      borderRadius: BorderRadius.circular(18),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 8,
                        ),
                        child: Text(
                          widget.label,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  right: 4,
                  top: top,
                  child: Semantics(
                    label: 'Scroll by date',
                    child: Container(
                      width: 32,
                      height: _handle,
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: const [
                          BoxShadow(blurRadius: 4, color: Colors.black26),
                        ],
                      ),
                      child: const Icon(Icons.unfold_more, size: 20),
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
}
