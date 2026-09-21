import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../app/session.dart';
import '../data/local_db.dart';

/// Small in-memory cache for thumbnails of photos that are only on the phone.
class _LocalThumbs {
  static final _cache = <String, Uint8List>{};
  static final _pending = <String, Future<Uint8List?>>{};

  static Uint8List? peek(String id) => _cache[id];

  static Future<Uint8List?> load(Session session, String id) {
    final hit = _cache[id];
    if (hit != null) return Future.value(hit);
    return _pending[id] ??= session.gallery
        .thumbnail(id)
        .then((bytes) {
          if (bytes != null) {
            _cache[id] = bytes;
            while (_cache.length > 600) {
              _cache.remove(_cache.keys.first);
            }
          }
          return bytes;
        })
        .whenComplete(() {
          // A block body: returning the removed future would make this
          // future wait on itself.
          _pending.remove(id);
        });
  }
}

/// A square thumbnail for a timeline item, from the bucket or the phone.
class PhotoThumb extends StatefulWidget {
  final Session session;
  final TimelineItem item;
  final bool showBadge;
  final bool selected;
  final bool selecting;
  final double radius;

  const PhotoThumb({
    super.key,
    required this.session,
    required this.item,
    this.showBadge = true,
    this.selected = false,
    this.selecting = false,
    this.radius = 14,
  });

  @override
  State<PhotoThumb> createState() => _PhotoThumbState();
}

class _PhotoThumbState extends State<PhotoThumb> {
  Uint8List? _bytes;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(PhotoThumb old) {
    super.didUpdateWidget(old);
    if (old.item.key != widget.item.key) {
      _bytes = null;
      _failed = false;
      _load();
    }
  }

  void _load() {
    final item = widget.item;
    final session = widget.session;
    // Prefer the phone's own thumbnail: free and instant.
    if (item.assetId != null) {
      _bytes = _LocalThumbs.peek(item.assetId!);
      if (_bytes == null) {
        _await(
          _LocalThumbs.load(session, item.assetId!),
          fallbackToCloud: true,
        );
      }
    } else if (item.photoId != null) {
      _bytes = session.photos.cachedThumbnail(item.photoId!);
      if (_bytes == null) _await(session.photos.thumbnail(item.photoId!));
    }
  }

  void _await(Future<Uint8List?> future, {bool fallbackToCloud = false}) {
    final key = widget.item.key;
    future.then(
      (bytes) {
        if (!mounted || widget.item.key != key) return;
        if (bytes == null && fallbackToCloud && widget.item.photoId != null) {
          _await(widget.session.photos.thumbnail(widget.item.photoId!));
          return;
        }
        setState(() {
          _bytes = bytes;
          _failed = bytes == null;
        });
      },
      onError: (_) {
        if (mounted && widget.item.key == key) setState(() => _failed = true);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final image = _bytes != null
        ? Image.memory(
            _bytes!,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            cacheWidth: 360,
            errorBuilder: (_, _, _) => _placeholder(scheme, broken: true),
          )
        : _placeholder(scheme, broken: _failed);

    return Stack(
      fit: StackFit.expand,
      children: [
        AnimatedScale(
          scale: widget.selected ? 0.86 : 1,
          duration: const Duration(milliseconds: 120),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(widget.radius),
            child: image,
          ),
        ),
        if (widget.item.kind != MediaKind.image) _kindBadge(),
        if (widget.showBadge && !widget.selecting) _badge(scheme),
        if (widget.selecting)
          Positioned(
            top: 6,
            left: 6,
            child: Icon(
              widget.selected
                  ? Icons.check_circle
                  : Icons.radio_button_unchecked,
              color: widget.selected ? scheme.primary : Colors.white,
              shadows: const [Shadow(blurRadius: 4, color: Colors.black54)],
            ),
          ),
      ],
    );
  }

  Widget _placeholder(ColorScheme scheme, {bool broken = false}) => ColoredBox(
    color: scheme.surfaceContainerHighest,
    child: switch ((broken, widget.item.kind)) {
      // A file that has no preview still says what it is.
      (_, MediaKind.file) => Icon(
        Icons.description_outlined,
        color: scheme.onSurfaceVariant,
      ),
      (_, MediaKind.video) => Icon(
        Icons.movie_outlined,
        color: scheme.onSurfaceVariant,
      ),
      (true, _) => Icon(
        Icons.image_not_supported_outlined,
        color: scheme.onSurfaceVariant,
      ),
      _ => null,
    },
  );

  /// A corner mark so videos and files are obvious in a grid of photos.
  Widget _kindBadge() => Positioned(
    left: 4,
    bottom: 4,
    child: Semantics(
      label: widget.item.kind == MediaKind.video ? 'Video' : 'File',
      child: Icon(
        widget.item.kind == MediaKind.video
            ? Icons.play_circle_fill
            : Icons.attach_file,
        size: 18,
        color: Colors.white,
        shadows: const [Shadow(blurRadius: 4, color: Colors.black87)],
      ),
    ),
  );

  Widget _badge(ColorScheme scheme) {
    final (icon, label) = switch (widget.item.state) {
      BackupState.localOnly => (Icons.cloud_upload_outlined, 'Not backed up'),
      BackupState.cloudOnly => (Icons.cloud_outlined, 'In cloud only'),
      BackupState.backedUp => (Icons.cloud_done_outlined, 'Backed up'),
    };
    return Positioned(
      right: 4,
      bottom: 4,
      child: Semantics(
        label: label,
        child: Icon(
          icon,
          size: 16,
          color: Colors.white,
          shadows: const [Shadow(blurRadius: 4, color: Colors.black87)],
        ),
      ),
    );
  }
}
