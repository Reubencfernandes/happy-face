import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';

import '../app/session.dart';
import '../data/catalogue.dart';
import '../data/local_db.dart';
import '../media/image_type.dart';
import '../s3/s3_client.dart';
import 'format.dart';

class PhotoViewer extends StatefulWidget {
  final Session session;
  final List<TimelineItem> items;
  final int initialIndex;

  const PhotoViewer({
    super.key,
    required this.session,
    required this.items,
    required this.initialIndex,
  });

  @override
  State<PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<PhotoViewer> {
  late final PageController _pages = PageController(
    initialPage: widget.initialIndex,
  );
  late List<TimelineItem> _items = List.of(widget.items);
  late int _index = widget.initialIndex;
  bool _chrome = true;
  bool _busy = false;

  Session get _session => widget.session;
  TimelineItem get _item => _items[_index];
  PhotoRecord? get _record =>
      _item.photoId == null ? null : _session.db.photo(_item.photoId!);

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _toast(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  Future<void> _run(String doneMessage, Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      if (mounted) _toast(doneMessage);
    } on S3Exception catch (e) {
      if (mounted) _toast(e.friendly);
    } on SocketException {
      if (mounted) _toast('No internet connection.');
    } catch (e) {
      if (mounted) _toast('That didn\'t work: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveToPhone() => _run('Saved to your photos', () async {
    final record = _record!;
    final bytes = await _session.photos.original(record.id);
    await _session.gallery.saveToPhone(bytes, record.name);
    await _session.scanGallery();
  });

  Future<void> _backUp() => _run('Backed up', () async {
    final results = await _session.backUpAssets([_item.assetId!]);
    final error = results.where((r) => r.error != null).firstOrNull?.error;
    if (error != null) throw Exception(error);
  });

  Future<void> _delete() async {
    final record = _record;
    if (record == null) return;
    final onPhone = _item.assetId != null;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete from Happy Drive?'),
        content: Text(
          onPhone
              ? 'The backup is removed from your storage. The copy on this phone stays.'
              : 'This photo is only in your storage. Deleting it removes it for good.',
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
    if (confirmed != true) return;
    await _run('Deleted from storage', () async {
      await _session.deletePhotos({record.id});
      if (!mounted) return;
      if (onPhone) {
        setState(
          () => _items[_index] = TimelineItem(
            photoId: null,
            assetId: _item.assetId,
            takenAt: _item.takenAt,
            tzOffsetMinutes: _item.tzOffsetMinutes,
            state: BackupState.localOnly,
          ),
        );
      } else {
        setState(() => _items = List.of(_items)..removeAt(_index));
        if (_items.isEmpty) {
          Navigator.pop(context);
        } else {
          _index = _index.clamp(0, _items.length - 1);
        }
      }
    });
  }

  void _details() => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => _DetailsSheet(item: _item, record: _record),
  );

  @override
  Widget build(BuildContext context) {
    final item = _items.isEmpty ? null : _item;
    return Theme(
      data: ThemeData.dark(useMaterial3: true).copyWith(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFF2A33A),
          brightness: Brightness.dark,
        ),
      ),
      child: Scaffold(
        backgroundColor: Colors.black,
        extendBodyBehindAppBar: true,
        appBar: _chrome && item != null
            ? AppBar(
                backgroundColor: Colors.black45,
                title: Text(
                  dayLabel(item.localTakenAt),
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                actions: [
                  if (_busy)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  IconButton(
                    tooltip: 'Details',
                    icon: const Icon(Icons.info_outline),
                    onPressed: _details,
                  ),
                ],
              )
            : null,
        body: item == null
            ? const SizedBox.shrink()
            : PageView.builder(
                controller: _pages,
                itemCount: _items.length,
                onPageChanged: (i) => setState(() => _index = i),
                itemBuilder: (context, i) => GestureDetector(
                  onTap: () => setState(() => _chrome = !_chrome),
                  child: _FullImage(
                    key: ValueKey(_items[i].key),
                    session: _session,
                    item: _items[i],
                  ),
                ),
              ),
        bottomNavigationBar: _chrome && item != null
            ? SafeArea(
                child: Container(
                  color: Colors.black45,
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      if (item.state == BackupState.localOnly)
                        _Action(
                          icon: Icons.cloud_upload_outlined,
                          label: 'Back up',
                          onTap: _busy ? null : _backUp,
                        ),
                      if (item.state == BackupState.cloudOnly)
                        _Action(
                          icon: Icons.download_outlined,
                          label: 'Save to phone',
                          onTap: _busy ? null : _saveToPhone,
                        ),
                      if (item.state == BackupState.backedUp)
                        const _Action(
                          icon: Icons.cloud_done_outlined,
                          label: 'Backed up',
                          onTap: null,
                        ),
                      _Action(
                        icon: Icons.info_outline,
                        label: 'Details',
                        onTap: _details,
                      ),
                      if (item.photoId != null)
                        _Action(
                          icon: Icons.delete_outline,
                          label: 'Delete',
                          onTap: _busy ? null : _delete,
                        ),
                    ],
                  ),
                ),
              )
            : null,
      ),
    );
  }
}

class _Action extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  const _Action({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(12),
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: onTap == null ? Colors.white54 : Colors.white),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: onTap == null ? Colors.white54 : Colors.white,
            ),
          ),
        ],
      ),
    ),
  );
}

class _FullImage extends StatefulWidget {
  final Session session;
  final TimelineItem item;
  const _FullImage({super.key, required this.session, required this.item});

  @override
  State<_FullImage> createState() => _FullImageState();
}

class _FullImageState extends State<_FullImage> {
  Uint8List? _preview;
  Uint8List? _full;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final item = widget.item;
    final session = widget.session;
    // Show the thumbnail straight away, then swap in the original.
    try {
      final thumb = item.assetId != null
          ? await session.gallery.thumbnail(item.assetId!, size: 800)
          : await session.photos.thumbnail(item.photoId!);
      if (mounted && _full == null) setState(() => _preview = thumb);
    } catch (_) {}

    try {
      Uint8List? bytes;
      if (item.assetId != null) {
        bytes = await session.gallery.original(item.assetId!);
      }
      if (bytes == null && item.photoId != null) {
        bytes = await session.photos.original(item.photoId!);
      }
      if (bytes == null) throw Exception('Photo not available');
      final displayable = await _displayable(bytes);
      if (mounted) setState(() => _full = displayable);
    } on S3Exception catch (e) {
      if (mounted) setState(() => _error = e.friendly);
    } on SocketException {
      if (mounted) setState(() => _error = 'Offline. Showing a preview.');
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not open this photo.');
    }
  }

  /// Android's image decoder can't always show HEIC; convert those to JPEG.
  static Future<Uint8List> _displayable(Uint8List bytes) async {
    final mime = sniffImageMime(bytes);
    final needsConversion =
        Platform.isAndroid &&
        (mime == 'image/heic' || mime == 'image/heif' || mime == 'image/avif');
    if (!needsConversion) return bytes;
    try {
      return await FlutterImageCompress.compressWithList(
        bytes,
        minWidth: 2560,
        minHeight: 2560,
        quality: 92,
      );
    } catch (_) {
      return bytes;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _full ?? _preview;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (bytes != null)
          InteractiveViewer(
            minScale: 1,
            maxScale: 6,
            child: Image.memory(
              bytes,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => const Center(
                child: Text(
                  'This photo can\'t be shown here.',
                  style: TextStyle(color: Colors.white70),
                ),
              ),
            ),
          )
        else if (_error == null)
          const Center(child: CircularProgressIndicator()),
        if (_full == null && _preview != null && _error == null)
          const Positioned(
            top: 100,
            right: 16,
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        if (_error != null)
          Positioned(
            left: 16,
            right: 16,
            bottom: 110,
            child: Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
          ),
      ],
    );
  }
}

class _DetailsSheet extends StatelessWidget {
  final TimelineItem item;
  final PhotoRecord? record;
  const _DetailsSheet({required this.item, required this.record});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = record;
    Widget row(IconData icon, String title, String? subtitle) => ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle),
    );
    final weather = r?.weather;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (r?.caption != null) ...[
              Text(r!.caption!, style: theme.textTheme.titleMedium),
              if (r.tags.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [for (final t in r.tags) Chip(label: Text(t))],
                ),
              ],
              const SizedBox(height: 8),
            ],
            row(
              Icons.calendar_today_outlined,
              fullDateTime(item.localTakenAt, item.tzOffsetMinutes),
              null,
            ),
            if (r?.place != null)
              row(
                Icons.place_outlined,
                [r!.place, r.country].whereType<String>().join(', '),
                r.hasLocation
                    ? '${r.lat!.toStringAsFixed(4)}, ${r.lng!.toStringAsFixed(4)}'
                    : null,
              )
            else if (r?.hasLocation ?? false)
              row(
                Icons.place_outlined,
                '${r!.lat!.toStringAsFixed(4)}, ${r.lng!.toStringAsFixed(4)}',
                'Finding place name…',
              ),
            if (weather != null)
              row(
                Icons.wb_cloudy_outlined,
                '${weather['summary'] ?? 'Weather'}',
                weather['tempC'] == null
                    ? null
                    : '${(weather['tempC'] as num).round()}°C',
              ),
            if (r != null)
              row(
                Icons.image_outlined,
                r.name,
                [
                  fileSize(r.size),
                  if (r.width != null && r.height != null)
                    '${r.width} × ${r.height}',
                  if (r.compression != 'original')
                    '${r.compression[0].toUpperCase()}${r.compression.substring(1)} compression',
                ].join(' · '),
              ),
            row(
              switch (item.state) {
                BackupState.backedUp => Icons.cloud_done_outlined,
                BackupState.localOnly => Icons.cloud_upload_outlined,
                BackupState.cloudOnly => Icons.cloud_outlined,
              },
              switch (item.state) {
                BackupState.backedUp => 'Backed up and on this phone',
                BackupState.localOnly => 'Only on this phone',
                BackupState.cloudOnly => 'Only in your storage',
              },
              item.photoId == null ? null : 'Encrypted before upload',
            ),
          ],
        ),
      ),
    );
  }
}
