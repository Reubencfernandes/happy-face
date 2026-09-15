import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import '../app/session.dart';
import '../data/local_db.dart';
import '../media/compress.dart';
import '../sync/uploader.dart';
import 'places_view.dart';
import 'search_view.dart';
import 'settings_screen.dart';
import 'timeline_view.dart';

class HomeScreen extends StatefulWidget {
  final Session session;
  final VoidCallback onSignOut;
  const HomeScreen({super.key, required this.session, required this.onSignOut});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final _selection = Selection();
  var _tab = 0;
  var _options = const TimelineOptions();

  Session get _session => widget.session;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _selection.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    await Future.wait([_session.sync(), _session.scanGallery()]);
    if (_session.settings.autoBackup &&
        !_session.uploading &&
        _session.db.backupStats().pending > 0) {
      await _runBackup(() => _session.backUpPending(), quiet: true);
    }
  }

  void _toast(String text, {SnackBarAction? action}) =>
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(text), action: action));

  Future<void> _runBackup(
    Future<List<UploadResult>> Function() run, {
    bool quiet = false,
  }) async {
    final results = await run();
    if (!mounted || results.isEmpty) return;
    final uploaded = results
        .where((r) => r.outcome == UploadOutcome.uploaded)
        .length;
    final skipped = results
        .where(
          (r) =>
              r.outcome == UploadOutcome.duplicate ||
              r.outcome == UploadOutcome.alreadyBackedUp,
        )
        .length;
    final failed = results
        .where((r) => r.outcome == UploadOutcome.failed)
        .toList();
    if (quiet && failed.isEmpty && uploaded == 0) return;
    final parts = [
      if (uploaded > 0) '$uploaded backed up',
      if (skipped > 0) '$skipped already safe',
      if (failed.isNotEmpty) '${failed.length} failed',
    ];
    _toast(
      parts.join(' · '),
      action: failed.isEmpty
          ? null
          : SnackBarAction(
              label: 'Details',
              onPressed: () => _showFailures(failed),
            ),
    );
  }

  void _showFailures(List<UploadResult> failed) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        for (final f in failed)
          ListTile(
            leading: const Icon(Icons.error_outline),
            title: Text(
              f.source.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(f.error ?? 'Unknown error'),
          ),
      ],
    ),
  );

  Future<Compression?> _pickCompression() => showModalBottomSheet<Compression>(
    context: context,
    showDragHandle: true,
    builder: (context) =>
        _CompressionSheet(initial: _session.settings.compression),
  );

  Future<void> _openBackupSheet() async {
    final access = _session.galleryAccess;
    final pending = _session.db.backupStats().pending;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (access?.hasAccess ?? false)
              ListTile(
                leading: const Icon(Icons.cloud_upload_outlined),
                title: Text(
                  pending == 0
                      ? 'Everything is backed up'
                      : 'Back up $pending photos',
                ),
                subtitle: const Text(
                  'All photos on this phone that aren\'t backed up yet',
                ),
                enabled: pending > 0,
                onTap: () => Navigator.pop(context, 'all'),
              )
            else
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Allow access to your photos'),
                subtitle: const Text(
                  'To show and back up the photos on this phone',
                ),
                onTap: () => Navigator.pop(context, 'access'),
              ),
            if (access?.hasAccess ?? false)
              ListTile(
                leading: const Icon(Icons.checklist),
                title: const Text('Choose photos'),
                subtitle: const Text(
                  'Shows photos not backed up; long-press to select',
                ),
                onTap: () => Navigator.pop(context, 'choose'),
              ),
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: const Text('Import from files'),
              subtitle: const Text(
                'Photos saved in Files, Downloads or a drive',
              ),
              onTap: () => Navigator.pop(context, 'files'),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'access':
        await _askAccess();
      case 'all':
        final c = await _pickCompression();
        if (c != null) {
          await _runBackup(() => _session.backUpPending(compression: c));
        }
      case 'choose':
        setState(() {
          _tab = 0;
          _options = _options.copyWith(filter: TimelineFilter.localOnly);
        });
        _toast('Long-press photos to select them, then tap Back up');
      case 'files':
        await _importFiles();
    }
  }

  Future<void> _askAccess() async {
    final state = await _session.scanGallery(ask: true);
    if (!mounted) return;
    if (!state.hasAccess) {
      _toast(
        'Photo access is off',
        action: SnackBarAction(
          label: 'Settings',
          onPressed: _session.gallery.openSettings,
        ),
      );
    }
  }

  Future<void> _importFiles() async {
    final files = await FilePicker.pickFiles(type: FileType.image);
    if (files.isEmpty || !mounted) return;
    final compression = await _pickCompression();
    if (compression == null) return;
    await _runBackup(
      () => _session.backUp([
        for (final f in files) UploadSource(name: f.name, read: f.readAsBytes),
      ], compression: compression),
    );
  }

  Future<void> _backUpSelection() async {
    final assets = [
      for (final i in _selection.items.values)
        if (i.state == BackupState.localOnly && i.assetId != null) i.assetId!,
    ];
    final compression = await _pickCompression();
    if (compression == null) return;
    _selection.clear();
    await _runBackup(
      () => _session.backUpAssets(assets, compression: compression),
    );
  }

  Future<void> _deleteSelection() async {
    final ids = {
      for (final i in _selection.items.values)
        if (i.photoId != null) i.photoId!,
    };
    final cloudOnly = _selection.items.values
        .where((i) => i.state == BackupState.cloudOnly)
        .length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${ids.length} from Happy Drive?'),
        content: Text(
          cloudOnly == 0
              ? 'The backups are removed from your storage. Copies on this phone stay.'
              : '$cloudOnly of these are only in your storage and will be gone for good.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    _selection.clear();
    try {
      await _session.deletePhotos(ids);
      if (mounted) _toast('Deleted ${ids.length} from storage');
    } catch (e) {
      if (mounted) _toast('Delete failed: $e');
    }
  }

  Future<void> _saveSelection() async {
    final ids = [
      for (final i in _selection.items.values)
        if (i.state == BackupState.cloudOnly && i.photoId != null) i.photoId!,
    ];
    _selection.clear();
    var saved = 0;
    for (final id in ids) {
      final record = _session.db.photo(id);
      if (record == null) continue;
      try {
        await _session.gallery.saveToPhone(
          await _session.photos.original(id),
          record.name,
        );
        saved++;
      } catch (_) {}
    }
    await _session.scanGallery();
    if (mounted) _toast('Saved $saved of ${ids.length} to your photos');
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_session, _selection]),
      builder: (context, _) {
        final selecting = _selection.active;
        return PopScope(
          canPop: !selecting,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _selection.clear();
          },
          child: Scaffold(
            appBar: selecting ? _selectionBar() : _normalBar(),
            body: IndexedStack(
              index: _tab,
              children: [
                TimelineView(
                  session: _session,
                  selection: _selection,
                  options: _options,
                  emptyState: _EmptyTimeline(
                    session: _session,
                    filtered: _options.filter != TimelineFilter.all,
                    onAllowAccess: _askAccess,
                    onImport: _importFiles,
                  ),
                ),
                PlacesView(session: _session, selection: _selection),
                SearchView(session: _session),
              ],
            ),
            floatingActionButton: _tab == 0 && !selecting
                ? FloatingActionButton.extended(
                    onPressed: _session.uploading
                        ? _session.cancelUpload
                        : _openBackupSheet,
                    icon: Icon(
                      _session.uploading
                          ? Icons.stop_circle_outlined
                          : Icons.add_photo_alternate_outlined,
                    ),
                    label: Text(_session.uploading ? 'Stop' : 'Back up'),
                  )
                : null,
            bottomNavigationBar: NavigationBar(
              selectedIndex: _tab,
              onDestinationSelected: (i) {
                _selection.clear();
                setState(() => _tab = i);
              },
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.photo_outlined),
                  selectedIcon: Icon(Icons.photo),
                  label: 'Photos',
                ),
                NavigationDestination(
                  icon: Icon(Icons.place_outlined),
                  selectedIcon: Icon(Icons.place),
                  label: 'Places',
                ),
                NavigationDestination(
                  icon: Icon(Icons.search),
                  label: 'Search',
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  PreferredSizeWidget _normalBar() {
    final upload = _session.upload;
    return AppBar(
      title: const Text('Happy Drive'),
      actions: [
        if (_tab == 0) _filterMenu(),
        IconButton(
          tooltip: 'Settings',
          icon: const Icon(Icons.settings_outlined),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => SettingsScreen(
                session: _session,
                onSignOut: widget.onSignOut,
              ),
            ),
          ),
        ),
      ],
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(34),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: [
              _StatusChip(session: _session),
              const Spacer(),
              if (_options.filter != TimelineFilter.all && _tab == 0)
                InputChip(
                  label: Text(switch (_options.filter) {
                    TimelineFilter.localOnly => 'Not backed up',
                    TimelineFilter.cloudOnly => 'Cloud only',
                    TimelineFilter.backedUp => 'Backed up',
                    TimelineFilter.all => '',
                  }),
                  onDeleted: () => setState(
                    () => _options = _options.copyWith(
                      filter: TimelineFilter.all,
                    ),
                  ),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ),
      ),
      flexibleSpace: upload != null && !upload.done
          ? Align(
              alignment: Alignment.bottomCenter,
              child: LinearProgressIndicator(
                value: upload.total == 0
                    ? null
                    : upload.completed / upload.total,
              ),
            )
          : null,
    );
  }

  Widget _filterMenu() => PopupMenuButton<Object>(
    tooltip: 'Sort and filter',
    icon: const Icon(Icons.tune),
    onSelected: (v) => setState(() {
      _options = switch (v) {
        TimelineSort s => _options.copyWith(sort: s),
        TimelineFilter f => _options.copyWith(filter: f),
        'order' => _options.copyWith(descending: !_options.descending),
        _ => _options,
      };
    }),
    itemBuilder: (context) => [
      const PopupMenuItem(enabled: false, child: Text('Sort by')),
      CheckedPopupMenuItem(
        value: TimelineSort.taken,
        checked: _options.sort == TimelineSort.taken,
        child: const Text('Date taken'),
      ),
      CheckedPopupMenuItem(
        value: TimelineSort.uploaded,
        checked: _options.sort == TimelineSort.uploaded,
        child: const Text('Date uploaded'),
      ),
      CheckedPopupMenuItem(
        value: 'order',
        checked: !_options.descending,
        child: const Text('Oldest first'),
      ),
      const PopupMenuDivider(),
      const PopupMenuItem(enabled: false, child: Text('Show')),
      for (final (f, label) in const [
        (TimelineFilter.all, 'All photos'),
        (TimelineFilter.localOnly, 'Not backed up'),
        (TimelineFilter.backedUp, 'Backed up'),
        (TimelineFilter.cloudOnly, 'Cloud only'),
      ])
        CheckedPopupMenuItem(
          value: f,
          checked: _options.filter == f,
          child: Text(label),
        ),
    ],
  );

  PreferredSizeWidget _selectionBar() {
    final items = _selection.items.values;
    final canBackUp = items.any((i) => i.state == BackupState.localOnly);
    final canDelete = items.any((i) => i.photoId != null);
    final canSave = items.any((i) => i.state == BackupState.cloudOnly);
    return AppBar(
      leading: IconButton(
        tooltip: 'Clear selection',
        icon: const Icon(Icons.close),
        onPressed: _selection.clear,
      ),
      title: Text('${_selection.length} selected'),
      actions: [
        if (canBackUp)
          IconButton(
            tooltip: 'Back up',
            icon: const Icon(Icons.cloud_upload_outlined),
            onPressed: _backUpSelection,
          ),
        if (canSave)
          IconButton(
            tooltip: 'Save to phone',
            icon: const Icon(Icons.download_outlined),
            onPressed: _saveSelection,
          ),
        if (canDelete)
          IconButton(
            tooltip: 'Delete from storage',
            icon: const Icon(Icons.delete_outline),
            onPressed: _deleteSelection,
          ),
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  final Session session;
  const _StatusChip({required this.session});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final upload = session.upload;
    final stats = session.db.backupStats();
    final (IconData icon, String text) = switch (()) {
      _ when upload != null && !upload.done => (
        Icons.cloud_sync_outlined,
        'Backing up ${upload.completed + 1} of ${upload.total}',
      ),
      _ when session.syncing => (Icons.sync, 'Syncing…'),
      _ when session.syncError != null => (
        Icons.cloud_off_outlined,
        session.syncError!,
      ),
      _ when (session.galleryAccess?.hasAccess ?? false) && stats.pending > 0 =>
        (Icons.cloud_upload_outlined, '${stats.pending} not backed up'),
      _ when session.galleryAccess?.hasAccess ?? false => (
        Icons.cloud_done_outlined,
        'All backed up · ${stats.inCloud} in storage',
      ),
      _ => (Icons.cloud_outlined, '${stats.inCloud} photos in storage'),
    };
    return Flexible(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: theme.colorScheme.primary),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyTimeline extends StatelessWidget {
  final Session session;
  final bool filtered;
  final VoidCallback onAllowAccess;
  final VoidCallback onImport;
  const _EmptyTimeline({
    required this.session,
    required this.filtered,
    required this.onAllowAccess,
    required this.onImport,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasAccess = session.galleryAccess?.hasAccess ?? false;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              filtered
                  ? Icons.filter_alt_off_outlined
                  : Icons.wb_sunny_outlined,
              size: 64,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 20),
            Text(
              filtered
                  ? 'Nothing matches this filter'
                  : 'Your memories start here',
              style: theme.textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              filtered
                  ? 'Try showing all photos.'
                  : hasAccess
                  ? 'No photos on this phone or in your storage yet.'
                  : 'Allow Happy Drive to see your photos to back them up, or import some from files.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (!filtered) ...[
              const SizedBox(height: 24),
              if (!hasAccess)
                FilledButton.icon(
                  onPressed: onAllowAccess,
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('Allow photo access'),
                ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: onImport,
                child: const Text('Import from files'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CompressionSheet extends StatefulWidget {
  final Compression initial;
  const _CompressionSheet({required this.initial});

  @override
  State<_CompressionSheet> createState() => _CompressionSheetState();
}

class _CompressionSheetState extends State<_CompressionSheet> {
  late var _value = widget.initial;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Text(
              'Upload quality',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          RadioGroup<Compression>(
            groupValue: _value,
            onChanged: (v) => setState(() => _value = v ?? _value),
            child: Column(
              children: [
                for (final c in Compression.values)
                  RadioListTile<Compression>(
                    value: c,
                    title: Text(c.label),
                    subtitle: Text(c.description),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () => Navigator.pop(context, _value),
            child: const Text('Start backup'),
          ),
        ],
      ),
    ),
  );
}
