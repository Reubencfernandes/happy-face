import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../crypto/vault.dart';
import '../data/bucket_layout.dart';
import '../data/catalogue.dart';
import '../s3/s3_client.dart';

/// Fetches and decrypts photos for display.
///
/// Thumbnails are cached on disk still encrypted, so the app's files never
/// hold readable photos; decrypted bytes live only in a small memory cache.
class PhotoStore {
  final BucketClient bucket;
  final Vault vault;
  final Directory? cacheDir;
  final int memoryEntries;

  final _memory = <String, Uint8List>{}; // insertion-ordered: an LRU

  /// Looks up a photo's catalogue entry, which says whether its original
  /// was stored whole or in pieces. Set by the session.
  PhotoRecord? Function(String photoId)? records;
  final _inFlight = <String, Future<Uint8List?>>{};

  PhotoStore(
    this.bucket,
    this.vault, {
    this.cacheDir,
    this.memoryEntries = 400,
  });

  /// Decrypted thumbnail, or null if the photo has none.
  Future<Uint8List?> thumbnail(String photoId) {
    final cached = _memory.remove(photoId);
    if (cached != null) {
      _memory[photoId] = cached; // mark as recently used
      return Future.value(cached);
    }
    return _inFlight[photoId] ??= _loadThumbnail(photoId).whenComplete(() {
      // A block body: returning the removed future would make this
      // future wait on itself.
      _inFlight.remove(photoId);
    });
  }

  Uint8List? cachedThumbnail(String photoId) => _memory[photoId];

  Future<Uint8List?> _loadThumbnail(String id) async {
    final key = BucketLayout.thumbnail(id);
    final file = cacheDir == null ? null : File('${cacheDir!.path}/t_$id');
    Uint8List? sealed;
    if (file != null && await file.exists()) {
      sealed = await file.readAsBytes();
    } else {
      try {
        sealed = await bucket.getObject(key);
      } on S3Exception catch (e) {
        if (e.isNotFound) return null;
        rethrow;
      }
      if (file != null) {
        await file.parent.create(recursive: true);
        await file.writeAsBytes(sealed, flush: false);
      }
    }
    final Uint8List clear;
    try {
      clear = await vault.open(sealed, context: key);
    } on TamperedDataException {
      // A corrupt cache file: drop it so the next attempt re-downloads.
      if (file != null && await file.exists()) await file.delete();
      rethrow;
    }
    _memory[id] = clear;
    while (_memory.length > memoryEntries) {
      _memory.remove(_memory.keys.first);
    }
    return clear;
  }

  /// Downloads and decrypts the full original, into memory.
  ///
  /// [onProgress] follows the download itself, which for a video is most of
  /// the wait — the decryption after it is quick. For anything that could be
  /// big, [originalToFile] is the one to use.
  Future<Uint8List> original(
    String photoId, {
    void Function(int received, int? total)? onProgress,
  }) async {
    final record = records?.call(photoId);
    if (record?.parts case final count?) {
      final out = BytesBuilder(copy: false);
      await _eachPart(photoId, count, record!.size, out.add, onProgress);
      return out.takeBytes();
    }
    final key = BucketLayout.original(photoId);
    return vault.open(
      await bucket.getObject(key, onReceived: onProgress),
      context: key,
    );
  }

  /// Downloads and decrypts the original into [file], a piece at a time
  /// for one stored in pieces, so a video of any length fits in memory.
  Future<void> originalToFile(
    String photoId,
    File file, {
    void Function(int received, int? total)? onProgress,
  }) async {
    final record = records?.call(photoId);
    final count = record?.parts;
    if (count == null) {
      await file.writeAsBytes(
        await original(photoId, onProgress: onProgress),
        flush: true,
      );
      return;
    }
    final sink = await file.open(mode: FileMode.write);
    try {
      await _eachPart(
        photoId,
        count,
        record!.size,
        (clear) => sink.writeFromSync(clear),
        onProgress,
      );
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  /// Fetches and opens each piece in order, handing the plain bytes on.
  /// Progress counts the whole file, not the piece.
  Future<void> _eachPart(
    String photoId,
    int count,
    int size,
    void Function(Uint8List clear) take,
    void Function(int received, int? total)? onProgress,
  ) async {
    final total = size + count * Vault.sealOverhead;
    var done = 0;
    for (var i = 0; i < count; i++) {
      final sealed = await bucket.getObject(
        BucketLayout.part(photoId, i),
        onReceived: onProgress == null
            ? null
            : (received, _) => onProgress(done + received, total),
      );
      done += sealed.length;
      take(
        await vault.open(
          sealed,
          context: BucketLayout.partContext(photoId, i, count),
        ),
      );
    }
  }

  /// Removes a photo's cached data from this device.
  Future<void> evict(String photoId) async {
    _memory.remove(photoId);
    final file = cacheDir == null ? null : File('${cacheDir!.path}/t_$photoId');
    if (file != null && await file.exists()) await file.delete();
  }

  Future<void> clearCache() async {
    _memory.clear();
    if (cacheDir != null && await cacheDir!.exists()) {
      await cacheDir!.delete(recursive: true);
    }
  }
}
