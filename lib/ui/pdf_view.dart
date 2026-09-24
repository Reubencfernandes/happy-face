import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/device.dart';
import '../app/session.dart';
import '../data/local_db.dart';
import '../media/media_file.dart';
import '../s3/s3_client.dart';
import 'format.dart';

/// A PDF read in the app, page by page, instead of a card saying "PDF".
///
/// Like a video, a copy from the bucket is downloaded and decrypted to a
/// temporary file first, which is deleted when this page goes away. Pages
/// are drawn by the phone's own PDF renderer as they scroll into view, and
/// only the few nearby are kept in memory.
class PdfView extends StatefulWidget {
  final Session session;
  final TimelineItem item;
  final String? name;

  /// Only the page being looked at loads: swiping past a PDF shouldn't
  /// download it.
  final bool active;

  const PdfView({
    super.key,
    required this.session,
    required this.item,
    required this.active,
    this.name,
  });

  @override
  State<PdfView> createState() => _PdfViewState();
}

class _PdfViewState extends State<PdfView> {
  PlayableFile? _file;
  PdfPages? _pdf;
  int? _count;
  bool _loading = false;
  String? _error;
  int _received = 0;
  int? _expected;

  /// Drawn pages, most recently used last.
  final _pages = <int, Uint8List>{};
  final _drawing = <int, Future<void>>{};
  static const _keep = 12;

  @override
  void initState() {
    super.initState();
    if (widget.active) _open();
  }

  @override
  void didUpdateWidget(PdfView old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) _open();
  }

  @override
  void dispose() {
    final pdf = _pdf, file = _file;
    unawaited(() async {
      // The renderer lets go of the file before it is deleted.
      await pdf?.close();
      await file?.release();
    }());
    super.dispose();
  }

  Future<void> _open() async {
    if (_loading || _pdf != null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final file = await widget.session.media.open(
        widget.item,
        name: widget.name ?? 'document.pdf',
        onProgress: (received, total) {
          if (mounted) {
            setState(() {
              _received = received;
              _expected = total;
            });
          }
        },
      );
      if (!mounted) {
        await file.release();
        return;
      }
      _file = file;
      final pdf = PdfPages(file.path);
      final count = await pdf.count();
      if (!mounted) return;
      setState(() {
        _pdf = pdf;
        _count = count;
        _loading = false;
      });
    } on S3Exception catch (e) {
      _failed(e.friendly);
    } on SocketException {
      _failed('No internet connection.');
    } on PlatformException {
      _failed(
        'This PDF can\'t be shown here. It may be password-protected. Save '
        'it to your phone to open it in another app.',
      );
    } catch (e) {
      _failed('Could not open this PDF.');
    }
  }

  void _failed(String message) {
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = message;
    });
  }

  void _draw(int index, int width) {
    final pdf = _pdf;
    if (pdf == null || _pages.containsKey(index)) return;
    _drawing[index] ??= () async {
      try {
        final jpeg = await pdf.render(index, width: width);
        if (jpeg == null || !mounted) return;
        setState(() {
          _pages[index] = jpeg;
          while (_pages.length > _keep) {
            _pages.remove(_pages.keys.first);
          }
        });
      } catch (_) {
        // Left as a blank page; scrolling back tries again.
      } finally {
        _drawing.remove(index);
      }
    }();
  }

  @override
  Widget build(BuildContext context) {
    final count = _count;
    if (count == null) return Center(child: _status());
    final size = MediaQuery.sizeOf(context);
    final ratio = MediaQuery.devicePixelRatioOf(context);
    // Sharp on the screen without asking the renderer for a poster.
    final width = min(2000, (size.width * ratio).round());
    return InteractiveViewer(
      minScale: 1,
      maxScale: 4,
      child: ListView.builder(
        padding: EdgeInsets.fromLTRB(
          8,
          MediaQuery.paddingOf(context).top + kToolbarHeight + 8,
          8,
          120,
        ),
        itemCount: count,
        itemBuilder: (context, i) {
          final page = _pages.remove(i);
          if (page != null) {
            _pages[i] = page; // recently used
          } else {
            _draw(i, width);
          }
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: page == null
                ? AspectRatio(
                    aspectRatio: 1 / sqrt2,
                    child: Container(
                      color: Colors.white10,
                      alignment: Alignment.center,
                      child: Text(
                        'Page ${i + 1}',
                        style: const TextStyle(color: Colors.white38),
                      ),
                    ),
                  )
                : Image.memory(page, gaplessPlayback: true),
          );
        },
      ),
    );
  }

  Widget _status() {
    if (_error case final error?) {
      return Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.white, size: 34),
            const SizedBox(height: 10),
            Text(
              error,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
            TextButton(onPressed: _open, child: const Text('Try again')),
          ],
        ),
      );
    }
    final total = _expected;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CircularProgressIndicator(
          value: total == null || total <= 0 || _received == 0
              ? null
              : _received / total,
        ),
        const SizedBox(height: 12),
        Text(
          _received == 0
              ? 'Opening the PDF…'
              : 'Downloading ${bytesOf(_received, total ?? 0)}',
          style: const TextStyle(color: Colors.white70),
        ),
      ],
    );
  }
}
