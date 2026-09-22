import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../app/session.dart';
import '../data/local_db.dart';
import '../media/media_file.dart';
import '../s3/s3_client.dart';
import 'format.dart';

/// A video (or a sound file) played where it sits, instead of a card telling
/// you to save it to the phone first.
///
/// A copy in the bucket has to come down and be decrypted before anything can
/// play it, so the wait is shown as a real bar with megabytes on it. The
/// decrypted file is deleted as soon as this widget goes away.
class VideoView extends StatefulWidget {
  final Session session;
  final TimelineItem item;

  /// The phone's thumbnail, shown until the first frame arrives.
  final Uint8List? poster;
  final String? name;

  /// Whether the viewer's chrome is showing, so the controls agree with it.
  final bool chromeVisible;

  /// False once this page is no longer the one being looked at. A swipe
  /// doesn't take the sound with it.
  final bool active;

  const VideoView({
    super.key,
    required this.session,
    required this.item,
    required this.chromeVisible,
    this.active = true,
    this.poster,
    this.name,
  });

  @override
  State<VideoView> createState() => _VideoViewState();
}

class _VideoViewState extends State<VideoView> {
  VideoPlayerController? _controller;
  PlayableFile? _file;
  bool _loading = false;
  String? _error;
  int _received = 0;
  int? _expected;

  @override
  void didUpdateWidget(VideoView old) {
    super.didUpdateWidget(old);
    if (old.active && !widget.active) _controller?.pause();
  }

  @override
  void dispose() {
    final controller = _controller;
    final file = _file;
    _controller = null;
    _file = null;
    if (controller != null || file != null) {
      // Order matters: the player lets go of the file before it's deleted.
      unawaited(() async {
        await controller?.dispose();
        await file?.release();
      }());
    }
    super.dispose();
  }

  Future<void> _start() async {
    if (_loading || _controller != null) return;
    setState(() {
      _loading = true;
      _error = null;
      _received = 0;
      _expected = null;
    });
    try {
      final file = await widget.session.media.open(
        widget.item,
        name: widget.name,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _received = received;
            _expected = total;
          });
        },
      );
      final controller = VideoPlayerController.file(File(file.path));
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        await file.release();
        return;
      }
      await controller.setLooping(false);
      await controller.play();
      setState(() {
        _file = file;
        _controller = controller;
        _loading = false;
      });
    } on S3Exception catch (e) {
      _failed(e.friendly);
    } on SocketException {
      _failed('No internet connection.');
    } on FileSystemException catch (e) {
      _failed(e.message);
    } catch (_) {
      _failed(
        'This one won\'t play on this phone. Save it to your phone to open '
        'it in another app.',
      );
    }
  }

  void _failed(String message) {
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (controller != null)
          Center(
            child: AspectRatio(
              aspectRatio: controller.value.aspectRatio == 0
                  ? 16 / 9
                  : controller.value.aspectRatio,
              child: VideoPlayer(controller),
            ),
          )
        else ...[
          if (widget.poster case final poster?)
            Image.memory(
              poster,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          Center(child: _cover(context)),
        ],
        if (controller != null && widget.chromeVisible)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _Controls(controller: controller),
          ),
      ],
    );
  }

  /// What sits over the poster: a play button, the download, or what failed.
  Widget _cover(BuildContext context) {
    if (_error case final error?) {
      return _Panel(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.white, size: 34),
            const SizedBox(height: 10),
            Text(
              error,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 10),
            TextButton(onPressed: _start, child: const Text('Try again')),
          ],
        ),
      );
    }
    if (_loading) {
      final total = _expected;
      return _Panel(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 38,
              height: 38,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                value: total == null || total <= 0 ? null : _received / total,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              _received == 0
                  ? 'Getting it ready…'
                  : 'Downloading ${bytesOf(_received, total ?? 0)}',
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
            const SizedBox(height: 2),
            const Text(
              'Decrypted on this phone, never on the way',
              style: TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ],
        ),
      );
    }
    return Semantics(
      button: true,
      label: 'Play',
      child: InkResponse(
        onTap: _start,
        radius: 48,
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: const BoxDecoration(
            color: Colors.black54,
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.play_arrow_rounded,
            size: 46,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

/// The dark rounded slab the messages sit on, over the poster.
class _Panel extends StatelessWidget {
  final Widget child;
  const _Panel({required this.child});

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.all(32),
    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
    decoration: BoxDecoration(
      color: Colors.black54,
      borderRadius: BorderRadius.circular(20),
    ),
    child: child,
  );
}

/// Play, scrub, mute — the least a player can have, over the video itself.
class _Controls extends StatelessWidget {
  final VideoPlayerController controller;
  const _Controls({required this.controller});

  static String _clock(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString();
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0
        ? '${d.inHours}:${minutes.padLeft(2, '0')}:$seconds'
        : '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: controller,
    builder: (context, value, _) {
      final ended =
          value.duration > Duration.zero && value.position >= value.duration;
      return Container(
        padding: const EdgeInsets.fromLTRB(8, 6, 12, 10),
        color: Colors.black45,
        child: Row(
          children: [
            IconButton(
              tooltip: ended
                  ? 'Play again'
                  : value.isPlaying
                  ? 'Pause'
                  : 'Play',
              color: Colors.white,
              icon: Icon(
                ended
                    ? Icons.replay_rounded
                    : value.isPlaying
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
              ),
              onPressed: () async {
                if (ended) {
                  await controller.seekTo(Duration.zero);
                  await controller.play();
                } else if (value.isPlaying) {
                  await controller.pause();
                } else {
                  await controller.play();
                }
              },
            ),
            Text(
              _clock(value.position),
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
            Expanded(
              child: VideoProgressIndicator(
                controller,
                allowScrubbing: true,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 16,
                ),
                colors: VideoProgressColors(
                  playedColor: Theme.of(context).colorScheme.primary,
                  bufferedColor: Colors.white24,
                  backgroundColor: Colors.white12,
                ),
              ),
            ),
            Text(
              _clock(value.duration),
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            IconButton(
              tooltip: value.volume == 0 ? 'Sound on' : 'Mute',
              color: Colors.white,
              icon: Icon(
                value.volume == 0
                    ? Icons.volume_off_rounded
                    : Icons.volume_up_rounded,
              ),
              onPressed: () => controller.setVolume(value.volume == 0 ? 1 : 0),
            ),
          ],
        ),
      );
    },
  );
}
