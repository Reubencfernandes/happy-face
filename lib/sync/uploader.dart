import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../crypto/vault.dart';
import '../data/bucket_layout.dart';
import '../data/catalogue.dart';
import '../data/local_db.dart';
import '../data/remote_catalogue.dart';
import '../media/compress.dart';
import '../media/image_type.dart';
import '../media/metadata.dart';
import '../s3/s3_client.dart';

/// Something to back up: a gallery asset or a picked file.
class UploadSource {
  final String name;

  /// Gallery id, when the photo came from the phone's library.
  final String? assetId;
  final Future<Uint8List> Function() read;

  /// A fast thumbnail from the OS, if available.
  final Future<Uint8List?> Function()? thumbnail;

  /// Facts known without opening the file (gallery date, GPS, size).
  final PhotoMetadata known;

  const UploadSource({
    required this.name,
    required this.read,
    this.assetId,
    this.thumbnail,
    this.known = PhotoMetadata.empty,
  });
}

enum UploadOutcome {
  uploaded,

  /// This gallery photo was backed up before and hasn't changed.
  alreadyBackedUp,

  /// Identical bytes are already in the library (maybe from another phone).
  duplicate,
  failed,
}

class UploadResult {
  final UploadSource source;
  final UploadOutcome outcome;
  final String? photoId;
  final String? error;
  const UploadResult(this.source, this.outcome, {this.photoId, this.error});
}

class UploadProgress {
  final int total;
  final int completed;
  final int uploaded;
  final int skipped;
  final int failed;
  final String? current;
  const UploadProgress({
    required this.total,
    required this.completed,
    required this.uploaded,
    required this.skipped,
    required this.failed,
    this.current,
  });
  bool get done => completed == total;
}

class Uploader {
  final BucketClient bucket;
  final Vault vault;
  final RemoteCatalogue catalogue;
  final LocalDb db;
  final ImageCodec codec;
  final DateTime Function() clock;
  final int concurrency;

  /// Photos are recorded in the catalogue in batches of this size, which
  /// keeps the journal small without delaying the backup badge too long.
  final int batchSize;

  bool _cancelled = false;

  Uploader({
    required this.bucket,
    required this.vault,
    required this.catalogue,
    required this.db,
    this.codec = const NativeImageCodec(),
    DateTime Function()? clock,
    this.concurrency = 4,
    this.batchSize = 10,
  }) : clock = clock ?? DateTime.now;

  void cancel() => _cancelled = true;

  Future<List<UploadResult>> run(
    List<UploadSource> sources, {
    Compression compression = Compression.original,
    bool force = false,
    void Function(UploadProgress)? onProgress,
  }) async {
    _cancelled = false;
    final results = List<UploadResult?>.filled(sources.length, null);
    final inFlight = <String, Future<bool>>{};
    final pending = <_Staged>[];
    final deferred = <Future<void>>[];
    var flushing = Future<void>.value();
    var next = 0;
    var uploaded = 0, skipped = 0, failed = 0, completed = 0;
    String? fatal;

    void report(String? current) => onProgress?.call(
      UploadProgress(
        total: sources.length,
        completed: completed,
        uploaded: uploaded,
        skipped: skipped,
        failed: failed,
        current: current,
      ),
    );

    void finish(int index, UploadResult result) {
      results[index] = result;
      completed++;
      switch (result.outcome) {
        case UploadOutcome.uploaded:
          uploaded++;
        case UploadOutcome.alreadyBackedUp || UploadOutcome.duplicate:
          skipped++;
        case UploadOutcome.failed:
          failed++;
      }
      report(null);
    }

    Future<void> flush() {
      if (pending.isEmpty) return flushing;
      final batch = List.of(pending);
      pending.clear();
      return flushing = flushing.then((_) async {
        try {
          final changed = await catalogue.commit([
            for (final s in batch)
              PutOp(s.record, clock().millisecondsSinceEpoch),
          ]);
          db.syncFrom(catalogue.state, changed);
          for (final s in batch) {
            final assetId = s.source.assetId;
            if (assetId != null) db.markAssetUploaded(assetId, s.record.id);
            _enqueueEnrichment(s.record);
            s.done.complete(true);
            finish(
              s.index,
              UploadResult(
                s.source,
                UploadOutcome.uploaded,
                photoId: s.record.id,
              ),
            );
          }
        } catch (e) {
          for (final s in batch) {
            s.done.complete(false);
            finish(
              s.index,
              UploadResult(s.source, UploadOutcome.failed, error: _describe(e)),
            );
          }
        }
      });
    }

    Future<void> worker() async {
      while (true) {
        if (next >= sources.length) return;
        final index = next++;
        final source = sources[index];
        if (_cancelled || fatal != null) {
          finish(
            index,
            UploadResult(
              source,
              UploadOutcome.failed,
              error: fatal ?? 'Cancelled',
            ),
          );
          continue;
        }
        report(source.name);
        try {
          final staged = await _prepare(
            source,
            index,
            compression,
            force,
            inFlight,
          );
          if (staged is UploadResult) {
            finish(index, staged);
          } else if (staged is _Duplicate) {
            // Resolve once the first copy is catalogued, without blocking
            // this worker (that copy may be waiting for this batch to fill).
            deferred.add(
              staged.first.then((ok) {
                if (ok && source.assetId != null) {
                  db.markAssetUploaded(source.assetId!, staged.id);
                }
                finish(
                  index,
                  ok
                      ? UploadResult(
                          source,
                          UploadOutcome.duplicate,
                          photoId: staged.id,
                        )
                      : UploadResult(
                          source,
                          UploadOutcome.failed,
                          error:
                              'An identical photo in this batch failed to upload.',
                        ),
                );
              }),
            );
          } else if (staged is _Staged) {
            pending.add(staged);
            if (pending.length >= batchSize) await flush();
          }
        } on S3Exception catch (e) {
          if (e.isAuth) fatal = e.friendly;
          finish(
            index,
            UploadResult(source, UploadOutcome.failed, error: e.friendly),
          );
        } catch (e) {
          if (source.assetId != null)
            db.markAssetFailed(source.assetId!, _describe(e));
          finish(
            index,
            UploadResult(source, UploadOutcome.failed, error: _describe(e)),
          );
        }
      }
    }

    report(null);
    await Future.wait([
      for (var i = 0; i < min(concurrency, max(1, sources.length)); i++)
        worker(),
    ]);
    await flush();
    await flushing;
    await Future.wait(deferred);
    await catalogue.compactIfNeeded();
    return results.cast<UploadResult>();
  }

  /// Returns an [UploadResult] when there's nothing to upload, or a [_Staged]
  /// photo whose encrypted files are already in the bucket.
  Future<Object> _prepare(
    UploadSource source,
    int index,
    Compression compression,
    bool force,
    Map<String, Future<bool>> inFlight,
  ) async {
    final assetId = source.assetId;
    if (assetId != null && !force) {
      final existing = db.uploadedPhotoFor(assetId);
      if (existing != null && catalogue.state.records.containsKey(existing)) {
        return UploadResult(
          source,
          UploadOutcome.alreadyBackedUp,
          photoId: existing,
        );
      }
    }

    final bytes = await source.read();
    final mime = sniffImageMime(bytes);
    if (mime == null) {
      throw const FormatException(
        'Not a supported photo (JPEG, PNG, HEIC, WebP, GIF).',
      );
    }

    // The id comes from the untouched original, so the same photo dedupes
    // whatever compression was chosen.
    final id = vault.photoIdFor(bytes);
    Future<UploadResult> duplicate() async {
      if (assetId != null) db.markAssetUploaded(assetId, id);
      return UploadResult(source, UploadOutcome.duplicate, photoId: id);
    }

    if (catalogue.state.records.containsKey(id)) return duplicate();
    final other = inFlight[id];
    if (other != null) return _Duplicate(id, other);

    final staged = _Staged(source, index);
    inFlight[id] = staged.done.future;

    try {
      final meta = (await readPhotoMetadata(bytes)).orElse(source.known);
      var stored = bytes;
      var storedMime = mime;
      var level = Compression.original;
      if (compression != Compression.original && mime != 'image/gif') {
        final smaller = await codec.compress(bytes, compression);
        if (smaller != null && smaller.length < bytes.length) {
          stored = smaller;
          storedMime = 'image/jpeg';
          level = compression;
        }
      }
      final thumb =
          await source.thumbnail?.call() ?? await codec.thumbnail(bytes);

      final originalKey = BucketLayout.original(id);
      await bucket.putObject(
        originalKey,
        await vault.seal(stored, context: originalKey),
      );
      if (thumb != null) {
        final thumbKey = BucketLayout.thumbnail(id);
        await bucket.putObject(
          thumbKey,
          await vault.seal(thumb, context: thumbKey),
        );
      }

      staged.record = PhotoRecord(
        id: id,
        name: _cleanName(source.name, storedMime),
        mime: storedMime,
        size: stored.length,
        width: meta.width,
        height: meta.height,
        takenAt: (meta.takenAt ?? clock()).toUtc(),
        tzOffsetMinutes: meta.tzOffsetMinutes,
        uploadedAt: clock().toUtc(),
        compression: level.name,
        lat: meta.lat,
        lng: meta.lng,
      );
      return staged;
    } catch (_) {
      staged.done.complete(false);
      rethrow;
    }
  }

  void _enqueueEnrichment(PhotoRecord r) {
    if (r.hasLocation) {
      db.enqueueJob(r.id, JobKind.place);
      db.enqueueJob(r.id, JobKind.weather);
    }
    db.enqueueJob(r.id, JobKind.caption);
  }

  static String _cleanName(String name, String mime) {
    var n = name.trim().isEmpty ? 'photo' : name.trim();
    if (n.length > 200) n = n.substring(n.length - 200);
    // A compressed HEIC is now a JPEG; keep the name honest.
    if (mime == 'image/jpeg' &&
        !RegExp(r'\.jpe?g$', caseSensitive: false).hasMatch(n)) {
      n = '${n.replaceFirst(RegExp(r'\.[A-Za-z0-9]{1,5}$'), '')}.${extensionForMime(mime)}';
    }
    return n;
  }

  static String _describe(Object e) => switch (e) {
    S3Exception() => e.friendly,
    FormatException(:final message) => message,
    TimeoutException() => 'The connection timed out.',
    _ => 'Upload failed: $e',
  };
}

class _Duplicate {
  final String id;
  final Future<bool> first;
  const _Duplicate(this.id, this.first);
}

class _Staged {
  final UploadSource source;
  final int index;
  final Completer<bool> done = Completer();
  late final PhotoRecord record;
  _Staged(this.source, this.index);
}
