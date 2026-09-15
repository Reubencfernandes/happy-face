import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../crypto/vault.dart';
import '../data/bucket_layout.dart';
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
    return _inFlight[photoId] ??= _loadThumbnail(
      photoId,
    ).whenComplete(() => _inFlight.remove(photoId));
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

  /// Downloads and decrypts the full original.
  Future<Uint8List> original(String photoId) async {
    final key = BucketLayout.original(photoId);
    return vault.open(await bucket.getObject(key), context: key);
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
