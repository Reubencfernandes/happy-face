import 'dart:async';

import 'package:flutter/material.dart';

import '../app/session.dart';
import '../data/catalogue.dart';
import '../data/local_db.dart';
import 'photo_thumb.dart';
import 'photo_viewer.dart';

class SearchView extends StatefulWidget {
  final Session session;
  const SearchView({super.key, required this.session});

  @override
  State<SearchView> createState() => _SearchViewState();
}

class _SearchViewState extends State<SearchView> {
  final _query = TextEditingController();
  Timer? _debounce;
  List<PhotoRecord> _results = const [];

  static const _suggestions = [
    'beach',
    'sunset',
    'food',
    'dog',
    'rain',
    'snow',
    'birthday',
    '2025',
  ];

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), () {
      if (!mounted) return;
      setState(() => _results = widget.session.db.search(text));
    });
  }

  void _useSuggestion(String s) {
    _query.text = s;
    _onChanged(s);
  }

  List<TimelineItem> get _items => [
    for (final r in _results)
      TimelineItem(
        photoId: r.id,
        assetId: null,
        takenAt: r.takenAt,
        tzOffsetMinutes: r.tzOffsetMinutes,
        state: BackupState.cloudOnly,
      ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = widget.session.settings;
    final captionsPending = widget.session.db.jobCount(JobKind.caption);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: TextField(
            controller: _query,
            onChanged: _onChanged,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Search places, things, dates…',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _query.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear',
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        _query.clear();
                        _onChanged('');
                      },
                    ),
            ),
          ),
        ),
        Expanded(
          child: _query.text.trim().isEmpty
              ? ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final s in _suggestions)
                          ActionChip(
                            label: Text(s),
                            onPressed: () => _useSuggestion(s),
                          ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    if (!settings.aiCaptions)
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.auto_awesome_outlined),
                          title: const Text('Search by what\'s in your photos'),
                          subtitle: const Text(
                            'Turn on AI descriptions in Settings to search for things like "dog on a beach".',
                          ),
                        ),
                      )
                    else if (captionsPending > 0)
                      Text(
                        'Describing $captionsPending photos. Results get better as that finishes.',
                        style: theme.textTheme.bodySmall,
                      ),
                  ],
                )
              : _results.isEmpty
              ? Center(
                  child: Text(
                    'No photos match "${_query.text.trim()}"',
                    style: theme.textTheme.bodyLarge,
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(2),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 140,
                    mainAxisSpacing: 2,
                    crossAxisSpacing: 2,
                  ),
                  itemCount: _results.length,
                  itemBuilder: (context, i) {
                    final items = _items;
                    return GestureDetector(
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => PhotoViewer(
                            session: widget.session,
                            items: items,
                            initialIndex: i,
                          ),
                        ),
                      ),
                      child: PhotoThumb(
                        key: ValueKey(items[i].key),
                        session: widget.session,
                        item: items[i],
                        showBadge: false,
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
