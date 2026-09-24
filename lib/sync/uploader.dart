import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../crypto/vault.dart';
import '../data/bucket_layout.dart';
import '../data/catalogue.dart';
import '../data/local_db.dart';
import '../data/remote_catalogue.dart';
import '../media/compress.dart';
import '../media/file_compress.dart';
import '../media/image_type.dart';
import '../media/metadata.dart';
import '../s3/s3_client.dart';

/// Something to back up: a gallery asset or a picked file.
class UploadSource {
  final String name;

  /// Gallery id, when the photo came from the phone's library.
  final String? assetId;

  /// How big the file is, when that can be known without opening it.
  ///
  /// This is what stops the app being killed: reading a file pulls the whole
  /// thing into memory, so anything too large has to be turned away *before*
  /// [read] is called, not after.
  final int? size;
  final Future<Uint8List> Function() read;

  /// A fast thumbnail from the OS, if available.
  final Future<Uint8List?> Function()? thumbnail;

  /// Facts known without opening the file (gallery date, GPS, size).
  final PhotoMetadata known;

  const UploadSource({
    required this.name,
    required this.read,
    this.assetId,
    this.size,
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

/// What is happening to one file at this moment.
enum UploadPhase {
  /// Reading it off the phone, or out of the file the user picked.
  reading,

  /// Encrypting, and compressing or making a thumbnail if it's a photo.
  preparing,

  /// Re-encoding a sound file or the pictures in a PDF, which takes long
  /// enough to deserve its own word.
  compressing,

  /// Its bytes are going to the bucket.
  uploading,

  /// Uploaded; waiting for the catalogue entry that makes it official.
  saving,
}

/// One file the backup is working on right now. There are as many of these
/// as the uploader has workers, so the UI can show all of them at once.
class ActiveUpload {
  /// Where this file sits in the batch, so an update replaces the right row.
  final int index;
  final String name;
  final String? assetId;
  final UploadPhase phase;
  final int bytesSent;
  final int bytesTotal;

  const ActiveUpload({
    required this.index,
    required this.name,
    required this.phase,
    this.assetId,
    this.bytesSent = 0,
    this.bytesTotal = 0,
  });

  /// How far this file has got, or null while there is nothing to measure.
  double? get fraction => phase != UploadPhase.uploading || bytesTotal <= 0
      ? null
      : (bytesSent / bytesTotal).clamp(0.0, 1.0);

  String get label => switch (phase) {
    UploadPhase.reading => 'Reading',
    UploadPhase.preparing => 'Encrypting',
    UploadPhase.compressing => 'Compressing',
    UploadPhase.uploading => 'Uploading',
    UploadPhase.saving => 'Saving',
  };
}

/// What the run as a whole is doing. Getting photos ready is slow enough on
/// a real phone to need saying out loud — it used to look like a freeze.
enum BackupStage { preparing, uploading, stopping, finished }

class UploadProgress {
  final int total;

  /// Files with a result in hand.
  final int completed;
  final int uploaded;
  final int skipped;
  final int failed;

  /// Files whose bytes are safely in the bucket but whose catalogue entry
  /// hasn't been written yet. Catalogue entries go up in batches, so without
  /// this the count would sit still for ten files at a time and then jump.
  final int awaitingCatalogue;

  /// The files in flight, in the order they were started.
  final List<ActiveUpload> active;

  /// Encrypted bytes that have reached the bucket, across the whole run.
  final int bytesUploaded;

  /// When the run began, for speed and time-left.
  final DateTime? startedAt;

  final BackupStage stage;

  /// True when the run ended because the user stopped it, rather than
  /// because it ran out of photos.
  final bool stopped;

  const UploadProgress({
    required this.total,
    required this.completed,
    required this.uploaded,
    required this.skipped,
    required this.failed,
    this.awaitingCatalogue = 0,
    this.active = const [],
    this.bytesUploaded = 0,
    this.startedAt,
    this.stage = BackupStage.uploading,
    this.stopped = false,
  });

  bool get done => completed == total;

  /// Files that are as good as done, which is what a person means by "how
  /// many have you got through". Never counts a file twice: a staged file
  /// leaves [awaitingCatalogue] in the same step that it enters [completed].
  int get settled => completed + awaitingCatalogue;

  /// The files genuinely being worked on. A file that has finished uploading
  /// and is only waiting for its catalogue entry is still in [active] so the
  /// sheet can show it as "Saving", but counting it as one of the files going
  /// up reads as nonsense — "16 files at once" from four workers.
  List<ActiveUpload> get working => [
    for (final a in active)
      if (a.phase != UploadPhase.saving) a,
  ];

  /// The name to show when there's only room for one — and only when there
  /// is one, because naming the oldest of four workers means naming the
  /// slowest, which looks stuck.
  String? get current => working.length == 1 ? working.first.name : null;

  /// Bytes done, counting what is part-way out of the phone.
  int get bytesDone =>
      bytesUploaded + active.fold(0, (sum, a) => sum + a.bytesSent);

  int get remaining => total - settled;

  /// How far along, counting the files in flight by their own progress, so
  /// one large video moves the bar instead of pausing it.
  double? get fraction =>
      total == 0 ? null : (progressed / total).clamp(0.0, 1.0);

  /// Encrypted bytes a second, or null before there's enough to judge by.
  double? get bytesPerSecond {
    final started = startedAt;
    if (started == null || bytesDone == 0) return null;
    final seconds = DateTime.now().difference(started).inMilliseconds / 1000.0;
    return seconds < 0.75 ? null : bytesDone / seconds;
  }

  /// Work got through so far, counting a file in flight by how far along it
  /// is. This is what the bar draws and what the estimate is paced by.
  double get progressed =>
      settled + active.fold(0.0, (sum, a) => sum + (a.fraction ?? 0));

  /// A guess at the time left, paced by work actually done.
  ///
  /// Deliberately not modelled in bytes: the sizes of files not yet started
  /// are unknown — nothing in the device index records them — so a byte
  /// estimate would be a guess stacked on a guess, and it collapses on a
  /// re-run where most files are skipped in milliseconds. Pacing by
  /// progressed work is self-correcting and costs nothing.
  Duration? get timeLeft {
    final started = startedAt;
    if (started == null || done || stage == BackupStage.finished) return null;
    final soFar = progressed;
    if (soFar <= 0) return null;
    final elapsed = DateTime.now().difference(started);
    if (elapsed < const Duration(seconds: 3)) return null;
    final left = (total - soFar).clamp(0.0, total.toDouble());
    if (left <= 0) return null;
    return elapsed * (left / soFar);
  }
}

class Uploader {
  final BucketClient bucket;
  final Vault vault;
  final RemoteCatalogue catalogue;
  final LocalDb db;
  final ImageCodec codec;

  /// Shrinks sound and PDFs, the way [codec] shrinks photos.
  final FileCodec files;
  final DateTime Function() clock;
  final int concurrency;

  /// Photos are recorded in the catalogue in batches of this size, which
  /// keeps the journal small without delaying the backup badge too long.
  final int batchSize;

  bool _cancelled = false;

  /// True once [cancel] has been called, until the next [reset].
  bool get cancelled => _cancelled;

  Uploader({
    required this.bucket,
    required this.vault,
    required this.catalogue,
    required this.db,
    this.codec = const NativeImageCodec(),
    this.files = const NativeFileCodec(),
    DateTime Function()? clock,
    this.concurrency = 4,
    this.batchSize = 10,
  }) : clock = clock ?? DateTime.now;

  /// Held while a large file is being read, encrypted and sent, so only one
  /// of them is in memory at a time however many workers there are.
  Future<void> _largeFile = Future.value();

  /// Stops the run. Files already uploading finish; nothing new starts.
  ///
  /// This is deliberately *not* cleared by [run]: a backup is several calls
  /// to [run], one per batch, and a stop pressed between two of them used to
  /// be forgotten by the time the next batch began.
  void cancel() => _cancelled = true;

  /// Clears a previous stop. Called once at the start of a whole backup,
  /// never per batch.
  void reset() => _cancelled = false;

  Future<List<UploadResult>> run(
    List<UploadSource> sources, {
    Compression compression = Compression.original,
    bool force = false,
    void Function(UploadProgress)? onProgress,
    void Function(UploadResult)? onResult,
  }) async {
    final results = List<UploadResult?>.filled(sources.length, null);
    final inFlight = <String, Future<bool>>{};
    final pending = <_Staged>[];
    final deferred = <Future<void>>[];
    final active = <int, _Active>{};
    final startedAt = DateTime.now();
    var flushing = Future<void>.value();
    var next = 0;
    var uploaded = 0, skipped = 0, failed = 0, completed = 0, bytes = 0;
    // Indices whose bytes are in the bucket but whose catalogue entry is
    // still outstanding. A set, not a counter: a file leaves it inside
    // `finish`, so every path out — committed, failed, abandoned — is
    // covered without remembering to decrement in each one.
    final awaiting = <int>{};
    String? fatal;
    DateTime? lastReport;

    // Bytes arrive in 64 KiB chunks from four workers at once, so the raw
    // rate is far faster than anything a screen needs. Anything that changes
    // what the list says — a new file, a phase, a finished one — is forced
    // through; the byte ticks in between are thinned out.
    void report({bool force = false}) {
      if (onProgress == null) return;
      final now = DateTime.now();
      if (!force &&
          lastReport != null &&
          now.difference(lastReport!) < const Duration(milliseconds: 80)) {
        return;
      }
      lastReport = now;
      onProgress(
        UploadProgress(
          total: sources.length,
          completed: completed,
          uploaded: uploaded,
          skipped: skipped,
          failed: failed,
          awaitingCatalogue: awaiting.length,
          stage: _cancelled ? BackupStage.stopping : BackupStage.uploading,
          active: [
            for (final a in active.values.toList()..sort(_Active.byIndex))
              a.snapshot(),
          ],
          bytesUploaded: bytes,
          startedAt: startedAt,
        ),
      );
    }

    /// Lets go of a file that was never finished, without recording a
    /// result for it. Its `_Active` row would otherwise linger in the list
    /// for ever, still counted in the bytes and the bar.
    void abandon(int index) {
      awaiting.remove(index);
      bytes += active.remove(index)?.committed ?? 0;
      report(force: true);
    }

    void finish(int index, UploadResult result) {
      awaiting.remove(index);
      results[index] = result;
      // A file's bytes move from its own row into the run's total as it
      // leaves, so [UploadProgress.bytesDone] never counts them twice.
      bytes += active.remove(index)?.committed ?? 0;
      completed++;
      switch (result.outcome) {
        case UploadOutcome.uploaded:
          uploaded++;
        case UploadOutcome.alreadyBackedUp || UploadOutcome.duplicate:
          skipped++;
        case UploadOutcome.failed:
          failed++;
      }
      report(force: true);
      onResult?.call(result);
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
        // A stop, or keys that have stopped working, leave the rest of the
        // batch alone rather than marking every one of them failed:
        // stopping a backup of two thousand photos used to report one
        // thousand nine hundred failures.
        if (_cancelled || fatal != null) return;
        final index = next++;
        final source = sources[index];
        final live = active[index] = _Active(
          index,
          source.name,
          source.assetId,
          onChange: report,
        );
        report(force: true);
        try {
          // Big ones queue up behind each other. Four videos read at once is
          // four times the memory, and the phone kills the app for less.
          final big = (source.size ?? 0) >= largeFileBytes;
          final turn = big ? _largeFile : Future<void>.value();
          final mine = Completer<void>();
          if (big) _largeFile = mine.future;
          await turn;
          final staged = await (() async {
            try {
              return await _prepare(
                source,
                index,
                compression,
                force,
                inFlight,
                live,
              );
            } finally {
              if (big) mine.complete();
            }
          })();
          if (staged is UploadResult) {
            finish(index, staged);
          } else if (staged is _Duplicate) {
            // Its bytes are already in the bucket under the same id, so it
            // is as good as done; it is just waiting for the first copy's
            // catalogue entry. Leaving it in `active` made the sheet list a
            // file that was doing nothing.
            active.remove(index);
            awaiting.add(index);
            report(force: true);
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
            // Its bytes are in the bucket; only the catalogue entry is
            // outstanding, so it counts as got-through from here. Saying so
            // now also stops it showing a full upload bar and being counted
            // in `awaiting` at the same time.
            pending.add(staged);
            awaiting.add(index);
            live.phaseIs(UploadPhase.saving);
            report(force: true);
            if (pending.length >= batchSize) await flush();
          }
        } on _Cancelled {
          // Not a failure, and not a result: this file was simply never done.
          abandon(index);
          return;
        } on S3Exception catch (e) {
          if (e.isAuth) {
            // The keys have stopped working. Every other file would fail the
            // same way, so stop rather than grinding through thousands.
            fatal = e.friendly;
            abandon(index);
            finish(
              index,
              UploadResult(source, UploadOutcome.failed, error: e.friendly),
            );
            return;
          }
          finish(
            index,
            UploadResult(source, UploadOutcome.failed, error: e.friendly),
          );
        } catch (e) {
          if (source.assetId != null) {
            db.markAssetFailed(source.assetId!, _describe(e));
          }
          finish(
            index,
            UploadResult(source, UploadOutcome.failed, error: _describe(e)),
          );
        }
      }
    }

    report(force: true);
    await Future.wait([
      for (var i = 0; i < min(concurrency, max(1, sources.length)); i++)
        worker(),
    ]);
    // These still run after a stop. `deferred` waits on completers that only
    // `flush` resolves, so skipping them would hang on a duplicate for ever.
    await flush();
    await flushing;
    // Belt and braces: anything still holding an uncompleted completer is
    // released, so a waiting duplicate can never wedge the run.
    for (final s in pending) {
      if (!s.done.isCompleted) s.done.complete(false);
    }
    await Future.wait(deferred);
    await catalogue.compactIfNeeded();
    // A stop leaves holes where files were never attempted.
    return results.whereType<UploadResult>().toList();
  }

  /// Returns an [UploadResult] when there's nothing to upload, or a [_Staged]
  /// photo whose encrypted files are already in the bucket.
  Future<Object> _prepare(
    UploadSource source,
    int index,
    Compression compression,
    bool force,
    Map<String, Future<bool>> inFlight,
    _Active live,
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

    // Before the file is even read: nothing is registered yet, so this one
    // can simply be dropped.
    if (_cancelled) throw const _Cancelled();
    // Asked of the file system, not of the file: reading a 2 GB video to
    // find out it is 2 GB is what killed the app.
    if (source.size case final known? when known > maxUploadBytes) {
      throw FormatException(_tooBig(known));
    }
    live.phaseIs(UploadPhase.reading);
    final bytes = await source.read();
    live.phaseIs(UploadPhase.preparing);
    // A file whose size wasn't known up front is still checked, late.
    if (bytes.length > maxUploadBytes) {
      throw FormatException(_tooBig(bytes.length));
    }
    // Photos, videos and anything else: unknown bytes are stored as they are
    // rather than turned away.
    final mime = sniffMime(bytes, name: source.name);
    final isImage = mime.startsWith('image/');

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
      // Only photos carry EXIF; everything else takes the date and place
      // the gallery or the file itself gave us.
      final meta = isImage
          ? (await readPhotoMetadata(bytes)).orElse(source.known)
          : source.known;
      var stored = bytes;
      var storedMime = mime;
      var level = Compression.original;
      if (isImage &&
          compression != Compression.original &&
          mime != 'image/gif') {
        final smaller = await codec.compress(bytes, compression);
        if (smaller != null && smaller.length < bytes.length) {
          stored = smaller;
          storedMime = 'image/jpeg';
          level = compression;
        }
      } else if (compression != Compression.original &&
          FileCodec.handles(mime)) {
        live.phaseIs(UploadPhase.compressing);
        final smaller = await files.compress(
          bytes,
          mime: mime,
          name: source.name,
          level: compression,
        );
        if (smaller != null && smaller.bytes.length < bytes.length) {
          stored = smaller.bytes;
          storedMime = smaller.mime;
          level = compression;
        }
        live.phaseIs(UploadPhase.preparing);
      }
      // Videos come with a thumbnail from the phone; a file that has none
      // gets an icon in the grid instead.
      final thumb =
          await source.thumbnail?.call() ??
          (isImage ? await codec.thumbnail(bytes) : null);

      final originalKey = BucketLayout.original(id);
      final sealed = await vault.seal(stored, context: originalKey);
      final sealedThumb = thumb == null
          ? null
          : await vault.seal(thumb, context: BucketLayout.thumbnail(id));
      // The last chance to bow out: past this the bytes are going up, and a
      // file that has started uploading is allowed to finish. Thrown, not
      // returned, so the `catch` below still completes this file's completer.
      if (_cancelled) throw const _Cancelled();
      // The bar covers both objects, so it doesn't jump back to zero when a
      // photo's thumbnail follows its original.
      live.uploadingBytes(sealed.length + (sealedThumb?.length ?? 0));
      await bucket.putObject(originalKey, sealed, onSent: live.sent);
      live.uploaded(sealed.length);
      if (sealedThumb != null) {
        await bucket.putObject(
          BucketLayout.thumbnail(id),
          sealedThumb,
          onSent: live.sent,
        );
        live.uploaded(sealedThumb.length);
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
    if (!r.hasLocation) return;
    db.enqueueJob(r.id, JobKind.place);
    db.enqueueJob(r.id, JobKind.weather);
  }

  /// The most one file can be.
  ///
  /// Not a protocol limit — a memory one. Each upload is a single request, so
  /// the whole file is held in memory at once, twice over while it is being
  /// encrypted, and it crosses the platform channel as one allocation on the
  /// Android heap first. A mid-range phone caps that heap around 384 MB, so a
  /// 215 MB video kills the app outright. Until uploads are chunked, this is
  /// the size that survives four workers running at once.
  static const maxUploadBytes = 64 * 1024 * 1024;

  /// Files at or above this go up one at a time, whatever [concurrency] says,
  /// so four large videos can't be in memory together.
  static const largeFileBytes = 12 * 1024 * 1024;

  static String _tooBig(int bytes) =>
      // Rounded up, not to nearest: a 64.4 MB file rounded down read as
      // "this file is 64 MB, so 64 MB is the most", which looks like a bug.
      'This file is ${(bytes / 1024 / 1024).ceil()} MB. Happy Drive uploads '
      'each file in one go, so ${maxUploadBytes ~/ (1024 * 1024)} MB is the '
      'most it can handle on a phone.';

  static String _cleanName(String name, String mime) {
    var n = name.trim().isEmpty
        ? (mime.startsWith('image/') ? 'photo' : 'file')
        : name.trim();
    if (n.length > 200) n = n.substring(n.length - 200);
    // A compressed HEIC is now a JPEG, and a compressed WAV an M4A; keep
    // the name honest.
    final wanted = switch (mime) {
      'image/jpeg' => RegExp(r'\.jpe?g$', caseSensitive: false),
      'audio/mp4' => RegExp(r'\.(m4a|mp4|aac)$', caseSensitive: false),
      _ => null,
    };
    if (wanted != null && !wanted.hasMatch(n)) {
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

/// The mutable half of [ActiveUpload]: what one worker is doing, kept up to
/// date in place and snapshotted whenever the UI is told.
class _Active {
  final int index;
  final String name;
  final String? assetId;
  final void Function({bool force}) onChange;

  UploadPhase phase = UploadPhase.reading;

  /// Bytes of this file already out, and how many there are in total. Both
  /// count the encrypted form, which is what actually travels.
  int _sent = 0;
  int _total = 0;

  /// Bytes of earlier objects for this same file (an original, when its
  /// thumbnail is going up), so the file's own bar only moves forwards.
  int _base = 0;

  _Active(this.index, this.name, this.assetId, {required this.onChange});

  /// This file's bytes that are safely in the bucket.
  int get committed => _base;

  static int byIndex(_Active a, _Active b) => a.index.compareTo(b.index);

  void phaseIs(UploadPhase next) {
    if (phase == next) return;
    phase = next;
    onChange(force: true);
  }

  void uploadingBytes(int total) {
    _total = total;
    _sent = 0;
    _base = 0;
    phase = UploadPhase.uploading;
    onChange(force: true);
  }

  /// A retry replays the body, so [sent] can go backwards within one object;
  /// the file's own total never does.
  void sent(int sent, int total) {
    _sent = _base + sent;
    onChange();
  }

  void uploaded(int bytes) {
    _base += bytes;
    _sent = _base;
    onChange(force: true);
  }

  ActiveUpload snapshot() => ActiveUpload(
    index: index,
    name: name,
    assetId: assetId,
    phase: phase,
    bytesSent: _sent,
    bytesTotal: _total,
  );
}

/// Thrown to unwind a file that was abandoned because the user stopped.
///
/// An exception rather than a `return`: once a [_Staged] is registered in the
/// in-flight map, another worker may be waiting on its completer, and the
/// existing `catch` is what completes it. Returning from inside that block
/// would hang the run on a duplicate that never resolves.
class _Cancelled implements Exception {
  const _Cancelled();
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
