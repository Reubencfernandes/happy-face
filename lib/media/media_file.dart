import 'dart:io';

import 'package:path_provider/path_provider.dart';
import '../data/local_db.dart';
import '../sync/photo_store.dart';
import 'gallery.dart';
import 'image_type.dart';

/// Where a playable copy of a video (or any other file) comes from, and when
/// it goes away again.
///
/// A player needs a real file. For something on the phone that's the phone's
/// own copy and nothing is written. For something in the bucket it has to be
/// downloaded and decrypted, and a decrypted file is the one thing the rest
/// of the app never leaves lying about — thumbnails are cached still sealed.
/// So these live in the OS cache directory, are deleted the moment the
/// viewer closes, and anything a crash left behind is swept at sign-in.
class MediaCache {
  final PhotoStore photos;
  final Gallery gallery;

  /// Where decrypted copies go while they are being played. The OS may clear
  /// this folder whenever it likes, which is exactly what we want of it.
  final Future<Directory> Function() directory;

  MediaCache(
    this.photos, {
    this.gallery = const Gallery(),
    Future<Directory> Function()? dir,
  }) : directory = dir ?? _defaultDir;

  static Future<Directory> _defaultDir() async =>
      Directory('${(await getTemporaryDirectory()).path}/playing');

  /// A file the platform player can open.
  ///
  /// [onProgress] reports the download when there is one. The returned handle
  /// must be released when the viewer is done with it.
  Future<PlayableFile> open(
    TimelineItem item, {
    String? name,
    void Function(int received, int? total)? onProgress,
  }) async {
    final assetId = item.assetId;
    if (assetId != null) {
      final file = await gallery.fileFor(assetId);
      // The phone's own copy: nothing is written and nothing is deleted.
      if (file != null) return PlayableFile._(file, owned: false);
    }
    final photoId = item.photoId;
    if (photoId == null) {
      throw const FileSystemException('This file is not on the phone.');
    }
    final dir = await directory();
    await dir.create(recursive: true);
    // The name matters: players pick their decoder from the extension.
    final extension = extensionForMime(item.mime ?? mimeForName(name) ?? '');
    final file = File('${dir.path}/$photoId.$extension');
    try {
      await photos.originalToFile(photoId, file, onProgress: onProgress);
    } catch (_) {
      // Half a decrypted file is still a readable one.
      if (await file.exists()) await file.delete();
      rethrow;
    }
    return PlayableFile._(file, owned: true);
  }

  /// Deletes anything an earlier run left behind. Called when a library is
  /// opened, so a crash mid-play can't leave a readable video on the phone.
  Future<void> sweep() async {
    try {
      final dir = await directory();
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // Best effort: a locked file now is swept on the next run.
    }
  }
}

/// A file ready to play, and whether closing should delete it.
class PlayableFile {
  final File file;
  final bool owned;
  const PlayableFile._(this.file, {required this.owned});

  String get path => file.path;

  Future<void> release() async {
    if (!owned) return;
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // The sweep at sign-in catches whatever this missed.
    }
  }
}
