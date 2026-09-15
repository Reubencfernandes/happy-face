import 'package:flutter/material.dart';

import '../app/session.dart';
import '../data/local_db.dart';
import 'photo_thumb.dart';
import 'timeline_view.dart';

class PlacesView extends StatefulWidget {
  final Session session;
  final Selection selection;
  const PlacesView({super.key, required this.session, required this.selection});

  @override
  State<PlacesView> createState() => _PlacesViewState();
}

class _PlacesViewState extends State<PlacesView> {
  List<PlaceGroup> _places = const [];
  int _revision = -1;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    widget.session.removeListener(_reload);
    super.dispose();
  }

  void _reload() {
    if (widget.session.revision == _revision) return;
    setState(() {
      _revision = widget.session.revision;
      _places = widget.session.db.places();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_places.isEmpty) {
      final pending = widget.session.db.jobCount(JobKind.place);
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.travel_explore,
                size: 64,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text('No places yet', style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                pending > 0
                    ? 'Finding places for $pending photos…'
                    : 'Photos taken with location turned on appear here, grouped by city.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final byCountry = <String, List<PlaceGroup>>{};
    for (final p in _places) {
      (byCountry[p.country] ??= []).add(p);
    }
    return CustomScrollView(
      slivers: [
        for (final entry in byCountry.entries) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 10),
              child: Text(
                entry.key.isEmpty ? 'Elsewhere' : entry.key,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 180,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 0.82,
              ),
              delegate: SliverChildBuilderDelegate(
                childCount: entry.value.length,
                (context, i) => _PlaceCard(
                  session: widget.session,
                  selection: widget.selection,
                  place: entry.value[i],
                ),
              ),
            ),
          ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 32)),
      ],
    );
  }
}

class _PlaceCard extends StatelessWidget {
  final Session session;
  final Selection selection;
  final PlaceGroup place;
  const _PlaceCard({
    required this.session,
    required this.selection,
    required this.place,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cover = session.db.photo(place.coverPhotoId);
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            appBar: AppBar(title: Text(place.place)),
            body: TimelineView(
              session: session,
              selection: Selection(),
              country: place.country.isEmpty ? null : place.country,
              place: place.place,
            ),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: cover == null
                  ? ColoredBox(color: theme.colorScheme.surfaceContainerHighest)
                  : PhotoThumb(
                      session: session,
                      showBadge: false,
                      item: TimelineItem(
                        photoId: cover.id,
                        assetId: null,
                        takenAt: cover.takenAt,
                        tzOffsetMinutes: cover.tzOffsetMinutes,
                        state: BackupState.cloudOnly,
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            place.place,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall,
          ),
          Text(
            '${place.count} ${place.count == 1 ? 'photo' : 'photos'}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
