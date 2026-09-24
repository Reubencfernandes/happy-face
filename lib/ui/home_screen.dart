import 'dart:io';
import 'dart:ui';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';

import '../app/session.dart';
import '../data/local_db.dart';
import '../media/compress.dart';
import '../enrich/enricher.dart';
import '../sync/background.dart';
import '../sync/uploader.dart';
import 'backup_status.dart';
import 'calendar_view.dart';
import 'compression_sheet.dart';
import 'delete_sheet.dart';
import 'files_view.dart';
import 'places_view.dart';
import 'search_view.dart';
import 'settings_screen.dart';
import 'theme.dart';
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
  late final _enricher = Enricher(widget.session);
  var _tab = 0;
  var _options = const TimelineOptions();
  var _shelf = FileShelf.pdfs;

  /// Where the Files tab sits in the bar.
  static const _filesTab = 3;

  Session get _session => widget.session;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    BackgroundBackup.configure(
      enabled: _session.settings.autoBackup,
      wifiOnly: _session.settings.wifiOnly,
    ).catchError((_) {});
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _selection.dispose();
    _enricher.dispose();
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
    _enrich();
  }

  /// Place names, weather and descriptions, in the background.
  void _enrich() => _enricher.run().catchError((_) {});

  void _toast(String text, {SnackBarAction? action}) =>
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(text), action: action));

  Future<void> _runBackup(
    Future<List<UploadResult>> Function() run, {
    bool quiet = false,
  }) async {
    final results = await run();
    _enrich();
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
    final stopped = _session.upload?.stopped ?? false;
    final parts = [
      if (stopped) 'Stopped',
      if (uploaded > 0) '$uploaded backed up',
      if (skipped > 0) '$skipped already safe',
      if (failed.isNotEmpty) '${failed.length} failed',
    ];
    _toast(
      parts.isEmpty ? 'Nothing to back up' : parts.join(' · '),
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

  Future<Compression?> _pickCompression({
    int count = 0,
    CompressionSubject subject = CompressionSubject.photos,
  }) => chooseCompression(context, _session, count: count, subject: subject);

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
                      : 'Back up $pending photos and videos',
                ),
                subtitle: const Text(
                  'Everything in this phone\'s library that isn\'t backed up yet',
                ),
                enabled: pending > 0,
                onTap: () => Navigator.pop(context, 'all'),
              )
            else
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Allow access to your photos'),
                subtitle: const Text(
                  'To show and back up the photos and videos on this phone',
                ),
                onTap: () => Navigator.pop(context, 'access'),
              ),
            if (access?.hasAccess ?? false)
              ListTile(
                leading: const Icon(Icons.checklist),
                title: const Text('Choose photos and videos'),
                subtitle: const Text(
                  'Shows what isn\'t backed up; long-press to select',
                ),
                onTap: () => Navigator.pop(context, 'choose'),
              ),
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: const Text('Import from files'),
              subtitle: const Text(
                'Any file in Files, Downloads or a drive — photos, videos, '
                'PDFs, anything',
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
        final c = await _pickCompression(count: pending);
        if (c != null) {
          await _runBackup(() => _session.backUpPending(compression: c));
        }
      case 'choose':
        setState(() {
          _tab = 0;
          _options = _options.copyWith(filter: TimelineFilter.localOnly);
        });
        _selection.start();
        _toast('Tap photos to select them, then tap the arrow to back up');
      case 'files':
        await _importFiles();
    }
  }

  /// The bucket has been deleted on huggingface.co. There is nothing to sync
  /// with any more, so the only way forward is to point the app somewhere
  /// else — which means signing in again.
  Future<void> _reconnect() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Connect to another bucket?'),
        content: Text(
          'The bucket "${_session.account.bucket}" is gone from your Hugging '
          'Face account, so there is nothing here to back up to. Signing in '
          'again lets you pick or make another one.\n\n'
          'Photos on this phone are untouched. Anything that was only in '
          'that bucket is gone with it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Not now'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sign in again'),
          ),
        ],
      ),
    );
    if (ok == true) widget.onSignOut();
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

  /// Sound formats the phones can play back, and so can compress.
  static const _audioExtensions = [
    'mp3',
    'm4a',
    'aac',
    'wav',
    'flac',
    'ogg',
    'opus',
    'amr',
    'aif',
    'aiff',
    'caf',
  ];

  Future<void> _importFiles({FileShelf? shelf}) async {
    // From the Files tab, only that tab's kind; otherwise anything the user
    // points at: photos, videos, PDFs, zips.
    final files = await switch (shelf) {
      null => FilePicker.pickFiles(type: FileType.any),
      FileShelf.pdfs => FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['pdf'],
      ),
      // Not FileType.audio: on iPhone that opens the music library, which
      // can't see voice memos or anything saved in Files.
      FileShelf.audio => FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: _audioExtensions,
      ),
    };
    if (files.isEmpty || !mounted) return;
    final compression = await _pickCompression(
      count: files.length,
      subject: switch (shelf) {
        FileShelf.pdfs => CompressionSubject.pdfs,
        FileShelf.audio => CompressionSubject.audio,
        null => CompressionSubject.photos,
      },
    );
    if (compression == null) return;
    // Sizes come from the picker when it knows them, so a big file is read
    // off the disk in pieces rather than pulled into memory whole.
    final sources = [
      for (final f in files)
        UploadSource(
          name: f.name,
          size: await f.length(),
          read: f.readAsBytes,
          file: () async => f.path == null ? null : File(f.path!),
        ),
    ];
    await _runBackup(() => _session.backUp(sources, compression: compression));
  }

  Future<void> _backUpSelection() async {
    final assets = [
      for (final i in _selection.items.values)
        if (i.state == BackupState.localOnly && i.assetId != null) i.assetId!,
    ];
    final compression = await _pickCompression(count: assets.length);
    if (compression == null) return;
    _selection.clear();
    await _runBackup(
      () => _session.backUpAssets(assets, compression: compression),
    );
  }

  Future<void> _deleteSelection() async {
    final items = _selection.items.values.toList();
    final from = await askWhereToDelete(context, items);
    if (from == null || !mounted) return;
    _selection.clear();
    try {
      final outcome = await deleteItems(_session, items, from);
      if (mounted) _toast(outcome.message);
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
        await _session.saveToPhone(record);
        saved++;
      } catch (_) {}
    }
    await _session.scanGallery();
    if (mounted) _toast('Saved $saved of ${ids.length} to your photos');
  }

  /// Tab 0 is the gallery; the rest keep their own names.
  String get _title => switch (_tab) {
    1 => 'Calendar',
    2 => 'Places',
    _filesTab => 'Files',
    4 => 'Search',
    _ => 'Gallery',
  };

  @override
  Widget build(BuildContext context) {
    // Coarse, not the session itself: a running backup ticks a dozen times a
    // second, and the bar and the backup button are the only things that
    // care. Rebuilding four tabs' worth of widgets at that rate is what made
    // the app feel stuck and swallow taps.
    return ListenableBuilder(
      listenable: Listenable.merge([_session.coarse, _selection]),
      builder: (context, _) {
        final selecting = _selection.active;
        // The gallery is always dark, whatever the phone is set to: photos
        // belong on ink. Screens pushed from here keep the app's theme.
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle.light.copyWith(
            statusBarColor: Colors.transparent,
            systemNavigationBarColor: ink,
          ),
          child: PopScope(
            canPop: !selecting,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) _selection.clear();
            },
            child: Scaffold(
              // The bar floats over the photos, and snack bars stack above it.
              extendBody: true,
              bottomNavigationBar: selecting
                  ? null
                  : _FloatingNav(
                      index: _tab,
                      onSelected: (i) {
                        _selection.clear();
                        setState(() => _tab = i);
                      },
                    ),
              body: Stack(
                children: [
                  Column(
                    children: [
                      _Header(
                        title: selecting
                            ? _selection.length == 0
                                  ? 'Choose photos'
                                  : '${_selection.length} selected'
                            : _title,
                        session: _session,
                        actions: selecting
                            ? _selectionActions()
                            : _normalActions(),
                        subtitle: selecting
                            ? null
                            : Row(
                                children: [
                                  _StatusChip(session: _session),
                                  const Spacer(),
                                  if (_options.filter != TimelineFilter.all &&
                                      _tab == 0)
                                    InputChip(
                                      label: Text(switch (_options.filter) {
                                        TimelineFilter.localOnly =>
                                          'Not backed up',
                                        TimelineFilter.cloudOnly =>
                                          'Cloud only',
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
                      if (_session.bucketMissing)
                        _MissingBucket(
                          session: _session,
                          onReconnect: _reconnect,
                        ),
                      Expanded(
                        child: IndexedStack(
                          index: _tab,
                          children: [
                            TimelineView(
                              session: _session,
                              selection: _selection,
                              options: _options,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 13,
                              ),
                              emptyState: _EmptyTimeline(
                                session: _session,
                                filtered: _options.filter != TimelineFilter.all,
                                onAllowAccess: _askAccess,
                                onImport: _importFiles,
                              ),
                            ),
                            CalendarView(
                              session: _session,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                            ),
                            PlacesView(
                              session: _session,
                              selection: _selection,
                            ),
                            FilesView(
                              session: _session,
                              shelf: _shelf,
                              onShelf: (s) => setState(() => _shelf = s),
                              onAdd: () => _importFiles(shelf: _shelf),
                            ),
                            SearchView(session: _session),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  List<Widget> _normalActions() => [
    if (_tab == 0) _filterMenu(),
    // The backup button: one arrow, pointing up at the cloud. It watches the
    // session directly, since it is one of the few things that should follow
    // a backup tick by tick.
    ListenableBuilder(
      listenable: _session,
      builder: (context, _) {
        final uploading = _session.uploading;
        final stopping = _session.stopping;
        return _UploadButton(
          icon: uploading ? Icons.stop_rounded : Icons.arrow_upward_rounded,
          label: stopping
              ? 'Stopping'
              : uploading
              ? 'Stop'
              : 'Upload',
          filled: !uploading,
          busy: stopping,
          // Once tapped, it says so rather than inviting a second tap.
          onPressed: stopping
              ? null
              : uploading
              ? _session.cancelUpload
              // On the Files tab the button means "add one of these".
              : _tab == _filesTab
              ? () => _importFiles(shelf: _shelf)
              : _openBackupSheet,
        );
      },
    ),
    _CircleButton(
      icon: Icons.settings_outlined,
      tooltip: 'Settings',
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              SettingsScreen(session: _session, onSignOut: widget.onSignOut),
        ),
      ),
    ),
  ];

  Widget _filterMenu() => PopupMenuButton<Object>(
    tooltip: 'Choose, sort and filter',
    position: PopupMenuPosition.under,
    onSelected: (v) {
      if (v == 'choose') {
        // Straight into selection, with no long-press to discover.
        _selection.start();
        _toast('Tap photos to select them, then tap the arrow to back up');
        return;
      }
      setState(() {
        _options = switch (v) {
          TimelineSort s => _options.copyWith(sort: s),
          TimelineFilter f => _options.copyWith(filter: f),
          'order' => _options.copyWith(descending: !_options.descending),
          _ => _options,
        };
      });
    },
    itemBuilder: (context) => [
      const PopupMenuItem(
        value: 'choose',
        child: ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.check_circle_outline),
          title: Text('Select photos'),
        ),
      ),
      const PopupMenuDivider(),
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
    // Lines of decreasing width: the one mark that reads as "sort and
    // filter" on sight. An app grid says "switch apps" and sliders say
    // "settings", which is what this button is sitting next to.
    child: const _CircleButton(icon: Icons.filter_list_rounded, tooltip: null),
  );

  List<Widget> _selectionActions() {
    final items = _selection.items.values;
    final canBackUp = items.any((i) => i.state == BackupState.localOnly);
    final canSave = items.any((i) => i.state == BackupState.cloudOnly);
    return [
      if (canBackUp)
        _CircleButton(
          icon: Icons.arrow_upward_rounded,
          tooltip: 'Back up',
          filled: true,
          onPressed: _backUpSelection,
        ),
      if (canSave)
        _CircleButton(
          icon: Icons.download_outlined,
          tooltip: 'Save to phone',
          onPressed: _saveSelection,
        ),
      _CircleButton(
        icon: Icons.delete_outline,
        tooltip: 'Delete',
        onPressed: _deleteSelection,
      ),
      _CircleButton(
        icon: Icons.close_rounded,
        tooltip: 'Done selecting',
        onPressed: _selection.clear,
      ),
    ];
  }
}

/// Shown when the bucket has been deleted on huggingface.co while the app
/// wasn't looking. Without it the gallery carries on showing every photo
/// from its local mirror, and the only clue is a vague "not found".
class _MissingBucket extends StatelessWidget {
  final Session session;
  final VoidCallback onReconnect;
  const _MissingBucket({required this.session, required this.onReconnect});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final error = theme.colorScheme.error;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Material(
        color: error.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onReconnect,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.cloud_off_outlined, color: error, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Your bucket is gone',
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '"${session.account.bucket}" is no longer in your '
                        'Hugging Face account. Photos on this phone are safe.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: inkMuted,
                          height: 1.35,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Connect to another bucket',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: accent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The page title, big and left-aligned, with round buttons beside it.
class _Header extends StatelessWidget {
  final String title;
  final List<Widget> actions;
  final Widget? subtitle;
  final Session session;

  const _Header({
    required this.title,
    required this.actions,
    required this.subtitle,
    required this.session,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 6, 14, 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.5,
                    ),
                  ),
                ),
                for (final action in actions) ...[
                  const SizedBox(width: 8),
                  action,
                ],
              ],
            ),
            if (subtitle != null)
              Padding(
                padding: const EdgeInsets.only(top: 6, right: 6),
                child: subtitle,
              ),
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ListenableBuilder(
                listenable: session,
                builder: (context, _) => BackupStatusBar(session: session),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The backup action: an arrow and the word for it, so the one button that
/// does something irreversible isn't a bare glyph to be guessed at.
class _UploadButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool filled;
  final bool busy;

  const _UploadButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.filled = false,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // White on both states, as asked. The amber is deepened a shade when
    // filled so the white actually reads against it.
    const ink = Colors.white;
    final pill = Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: filled
            ? glowEmber
            : scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(21),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: ink),
            )
          else
            Icon(icon, size: 19, color: ink),
          const SizedBox(width: 7),
          Text(
            label,
            style: const TextStyle(
              color: ink,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
    return Semantics(
      button: true,
      label: label,
      child: onPressed == null
          ? Opacity(opacity: 0.6, child: pill)
          : InkWell(
              onTap: onPressed,
              borderRadius: BorderRadius.circular(21),
              child: pill,
            ),
    );
  }
}

/// A round icon button: the shape the gallery chrome is made of.
class _CircleButton extends StatelessWidget {
  final IconData icon;
  final String? tooltip;
  final VoidCallback? onPressed;
  final bool filled;

  const _CircleButton({
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.filled = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final button = Container(
      width: 42,
      height: 42,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: filled
            ? scheme.primaryContainer
            : scheme.surfaceContainerHighest.withValues(alpha: 0.6),
      ),
      child: Icon(
        icon,
        size: 21,
        color: filled ? scheme.onPrimaryContainer : scheme.onSurface,
      ),
    );
    // With no onPressed this is the face of something else, like a menu.
    final child = onPressed == null
        ? button
        : InkResponse(onTap: onPressed, radius: 26, child: button);
    return Semantics(
      button: true,
      label: tooltip,
      child: tooltip == null ? child : Tooltip(message: tooltip, child: child),
    );
  }
}

/// The bar that floats over the photos instead of sitting under them.
class _FloatingNav extends StatelessWidget {
  final int index;
  final ValueChanged<int> onSelected;

  const _FloatingNav({required this.index, required this.onSelected});

  static const _items = [
    (Icons.home_outlined, Icons.home_rounded, 'Gallery'),
    (Icons.calendar_today_outlined, Icons.calendar_month_rounded, 'Calendar'),
    (Icons.place_outlined, Icons.place, 'Places'),
    (Icons.folder_outlined, Icons.folder_rounded, 'Files'),
    (Icons.auto_awesome_outlined, Icons.auto_awesome, 'Search'),
  ];

  // Every slot is the same size, so the lit one knows where to slide to.
  static const _slotWidth = 56.0;
  static const _slotHeight = 42.0;
  static const _slotGap = 6.0;
  static const _slide = Duration(milliseconds: 320);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const step = _slotWidth + _slotGap;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        // A Row, not a Center: as the Scaffold's bottom bar this must be as
        // tall as the pill, not as tall as the screen.
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(32),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    // Glass, not a slab: the photos show through it.
                    color: scheme.surfaceContainerHighest.withValues(
                      alpha: 0.52,
                    ),
                    borderRadius: BorderRadius.circular(34),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.09),
                    ),
                  ),
                  child: SizedBox(
                    width: _items.length * step - _slotGap,
                    height: _slotHeight,
                    child: Stack(
                      children: [
                        // One lit slot that travels, rather than one fading
                        // out while another fades in.
                        AnimatedPositionedDirectional(
                          duration: _slide,
                          curve: Curves.easeOutCubic,
                          start: index * step,
                          top: 0,
                          width: _slotWidth,
                          height: _slotHeight,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: scheme.primaryContainer,
                              borderRadius: BorderRadius.circular(21),
                            ),
                          ),
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final (i, (outline, filled, label))
                                in _items.indexed) ...[
                              if (i > 0) const SizedBox(width: _slotGap),
                              Semantics(
                                button: true,
                                selected: i == index,
                                label: label,
                                child: Tooltip(
                                  message: label,
                                  child: InkResponse(
                                    onTap: () => onSelected(i),
                                    radius: 28,
                                    child: SizedBox(
                                      width: _slotWidth,
                                      height: _slotHeight,
                                      // The ink follows the pill rather than
                                      // switching the moment it is tapped.
                                      child: TweenAnimationBuilder<Color?>(
                                        duration: _slide,
                                        curve: Curves.easeOutCubic,
                                        tween: ColorTween(
                                          end: i == index
                                              ? scheme.onPrimaryContainer
                                              : scheme.onSurfaceVariant,
                                        ),
                                        builder: (context, color, _) => Icon(
                                          i == index ? filled : outline,
                                          size: 23,
                                          color: color,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
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
    // While a backup runs the bar below says all this and more, so the chip
    // steps back to the last thing that finished.
    if (upload != null && !upload.done) return const SizedBox.shrink();
    final stats = session.db.backupStats();
    final (IconData icon, String text) = switch (()) {
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
