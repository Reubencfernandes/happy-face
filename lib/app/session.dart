import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as hash;
import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';

import '../crypto/vault.dart';
import '../data/bucket_layout.dart';
import '../data/catalogue.dart';
import '../data/local_db.dart';
import '../data/remote_catalogue.dart';
import '../media/compress.dart';
import '../media/file_compress.dart';
import '../media/gallery.dart';
import '../media/media_file.dart';
import '../s3/s3_client.dart';
import '../sync/photo_store.dart';
import '../sync/uploader.dart';
import 'credentials.dart';

/// User preferences, stored in the local database.
class Settings {
  final LocalDb _db;
  Settings(this._db);

  Compression get compression =>
      Compression.parse(_db.getSetting('compression'));
  set compression(Compression c) => _db.setSetting('compression', c.name);

  /// Ask which quality to use each time photos are backed up by hand.
  /// Off means [compression] is used without asking.
  bool get askQuality => _db.getSetting('askQuality') != 'false';
  set askQuality(bool v) => _db.setSetting('askQuality', '$v');

  bool get autoBackup => _db.getSetting('autoBackup') == 'true';
  set autoBackup(bool v) => _db.setSetting('autoBackup', '$v');

  bool get wifiOnly => _db.getSetting('wifiOnly') != 'false';
  set wifiOnly(bool v) => _db.setSetting('wifiOnly', '$v');

  bool get weather => _db.getSetting('weather') == 'true';
  set weather(bool v) => _db.setSetting('weather', '$v');
}

/// A notifier for coarse changes only, so a screen can rebuild when the
/// library or the sync state moves without also rebuilding a dozen times a
/// second while a backup ticks along.
class _Signal extends ChangeNotifier {
  void bump() => notifyListeners();
}

/// Everything needed while a library is unlocked, plus the state the UI
/// watches (sync status, upload progress, a data revision counter).
class Session extends ChangeNotifier {
  final StoredAccount account;
  final BucketClient bucket;
  final Vault vault;
  final LocalDb db;
  final RemoteCatalogue catalogue;
  final PhotoStore photos;
  final Gallery gallery;
  final CredentialStore credentials;
  late final Settings settings = Settings(db);
  late final MediaCache media = MediaCache(photos, gallery: gallery);
  late final Uploader _uploader;

  /// Bumped whenever photos are added, changed or removed.
  int revision = 0;

  /// Fires on everything except upload progress. Screens that don't show
  /// progress listen to this instead of the session itself, so a running
  /// backup doesn't rebuild them on every tick.
  final _coarse = _Signal();
  Listenable get coarse => _coarse;
  bool syncing = false;
  String? syncError;
  UploadProgress? upload;
  List<UploadResult> lastResults = const [];

  /// Files that have just finished, newest first, while a backup is running.
  /// Capped, because a backup can be thousands of photos long.
  final List<UploadResult> recentResults = [];
  static const _recentKept = 60;
  PermissionState? galleryAccess;

  /// Set when the bucket has been deleted out from under the app.
  bool bucketMissing = false;
  bool _disposed = false;
  bool _loadedOnce = false;

  Session({
    required this.account,
    required this.bucket,
    required this.vault,
    required this.db,
    required this.photos,
    required this.credentials,
    this.gallery = const Gallery(),
    ImageCodec codec = const NativeImageCodec(),
    FileCodec files = const NativeFileCodec(),
  }) : catalogue = RemoteCatalogue(bucket, vault) {
    _uploader = Uploader(
      bucket: bucket,
      vault: vault,
      catalogue: catalogue,
      db: db,
      codec: codec,
      files: files,
    );
  }

  static Future<Session> open({
    required StoredAccount account,
    required Vault vault,
    required Directory dataDir,
    CredentialStore credentials = const CredentialStore(),
    BucketClientFactory clientFactory = defaultBucketClient,
    Gallery gallery = const Gallery(),
  }) async {
    final tag = hash.sha256
        .convert(account.id.codeUnits)
        .toString()
        .substring(0, 16);
    await dataDir.create(recursive: true);
    final bucket = clientFactory(account);
    final session = Session(
      account: account,
      bucket: bucket,
      vault: vault,
      db: LocalDb.open('${dataDir.path}/library_$tag.db'),
      photos: PhotoStore(
        bucket,
        vault,
        cacheDir: Directory('${dataDir.path}/thumbs_$tag'),
      ),
      credentials: credentials,
      gallery: gallery,
    );
    // A video being watched is decrypted to a file; if the app died with one
    // open, this is where it gets cleaned up.
    await session.media.sweep();
    return session;
  }

  bool get uploading => upload != null && !upload!.done;

  void _changed() {
    if (_disposed) return;
    revision++;
    _coarse.bump();
    notifyListeners();
  }

  /// A progress tick: cheap, frequent, and of no interest to most of the UI.
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Something other than progress moved — sync, permissions, settings.
  void _notifyAll() {
    if (_disposed) return;
    _coarse.bump();
    notifyListeners();
  }

  /// Pulls the catalogue from the bucket and mirrors it locally. The timeline
  /// shows the local mirror immediately, so this runs in the background.
  Future<void> sync({bool full = false}) async {
    if (syncing) return;
    syncing = true;
    syncError = null;
    _notifyAll();
    try {
      final firstLoad = !_loadedOnce;
      final changed = full || firstLoad
          ? await catalogue.load()
          : await catalogue.refresh();
      final stale = firstLoad || full
          ? db.allPhotoIds().difference(catalogue.state.records.keys.toSet())
          : <String>{};
      _loadedOnce = true;
      bucketMissing = false;
      if (changed.isNotEmpty || stale.isNotEmpty) {
        db.syncFrom(catalogue.state, {...changed, ...stale});
        _changed();
      }
    } on S3Exception catch (e) {
      // A 404 from the catalogue could be one missing object — or the whole
      // bucket having been deleted on huggingface.co, which the app would
      // otherwise report as a vague "not found" while still listing every
      // photo from its local mirror as though nothing had happened.
      if (e.isNotFound && !await _bucketStillThere()) {
        bucketMissing = true;
        syncError =
            'The bucket "${account.bucket}" is no longer in your Hugging '
            'Face account. Your photos on this phone are safe, but the '
            'backups are gone.';
      } else {
        syncError = e.friendly;
      }
    } on SocketException {
      syncError = 'Offline. Showing photos saved on this phone.';
    } catch (e) {
      syncError = 'Could not sync: $e';
    } finally {
      syncing = false;
      _notifyAll();
    }
  }

  /// True when the bucket itself answers, so a 404 was about one object.
  /// A network failure here counts as "still there": better to say nothing
  /// than to announce a deleted bucket because the Wi-Fi dropped.
  Future<bool> _bucketStillThere() async {
    try {
      return await bucket.bucketExists();
    } catch (_) {
      return true;
    }
  }

  /// Asks for (or re-checks) photo library access and records what's on the
  /// phone. Returns the permission state.
  Future<PermissionState> scanGallery({bool ask = false}) async {
    try {
      final state = ask
          ? await gallery.requestAccess()
          : await gallery.currentAccess();
      galleryAccess = state;
      if (state.hasAccess) {
        final assets = await gallery.scan();
        db.upsertDeviceAssets(assets);
        db.removeDeviceAssetsExcept({for (final a in assets) a.assetId});
        _changed();
      } else {
        _notifyAll();
      }
      return state;
    } catch (_) {
      // No photo library on this platform, or the OS refused: cloud only.
      galleryAccess = PermissionState.denied;
      _notifyAll();
      return PermissionState.denied;
    }
  }

  /// Uploads files the user picked (for example from Files or Downloads).
  Future<List<UploadResult>> backUp(
    List<UploadSource> sources, {
    Compression? compression,
  }) => _runBackup(
    total: sources.length,
    compression: compression,
    nextBatch: (done) async => done == 0 ? sources : null,
  );

  /// Backs up gallery photos by id, e.g. a multi-selection in the timeline.
  ///
  /// Photos are prepared in batches of [batchSize], so uploading starts
  /// straight away even when thousands are waiting. With a [budget], stops
  /// starting new batches once that much time has passed.
  Future<List<UploadResult>> backUpAssets(
    List<String> assetIds, {
    Compression? compression,
    Duration? budget,
    int batchSize = 16,
  }) {
    var next = 0;
    return _runBackup(
      total: assetIds.length,
      compression: compression,
      budget: budget,
      nextBatch: (_) async {
        while (next < assetIds.length && !_stopRequested) {
          final ids = assetIds.skip(next).take(batchSize).toList();
          next += ids.length;
          final sources = await _resolve(ids);
          // Photos deleted from the phone since the last scan are skipped.
          _missing += ids.length - sources.length;
          if (sources.isNotEmpty) return sources;
        }
        return null;
      },
    );
  }

  /// Turns asset ids into things that can be uploaded.
  ///
  /// Each one costs three round trips to the photo library, so they go out
  /// several at a time: done one after another, a batch of fifty was a
  /// hundred and fifty waits before a single byte left the phone, with
  /// nothing on screen moving and no way to stop.
  Future<List<UploadSource>> _resolve(List<String> ids) async {
    const atOnce = 8;
    final out = <UploadSource>[];
    for (var i = 0; i < ids.length; i += atOnce) {
      if (_stopRequested) break;
      final slice = ids.skip(i).take(atOnce);
      final resolved = await Future.wait(slice.map(gallery.sourceFor));
      out.addAll(resolved.whereType<UploadSource>());
    }
    return out;
  }

  /// Everything on the phone that isn't backed up yet, newest first.
  Future<List<UploadResult>> backUpPending({
    Compression? compression,
    Duration? budget,
  }) => backUpAssets(
    db.pendingAssets(limit: 1 << 30),
    compression: compression,
    budget: budget,
  );

  /// Stops after the photos currently uploading.
  ///
  /// Notifying matters: without it, tapping Stop changed nothing on screen
  /// until the run actually wound down, which is indistinguishable from the
  /// tap not registering.
  void cancelUpload() {
    if (!uploading || stopping) return;
    stopping = true;
    _stopRequested = true;
    _uploader.cancel();
    _notifyAll();
  }

  bool _stopRequested = false;
  int _missing = 0;

  /// True between tapping Stop and the run winding down.
  bool stopping = false;

  Timer? _heartbeat;

  /// Says "a backup is running here" in the shared database, so the
  /// background task doesn't start a second one this app can't stop.
  /// Written on a timer so a crash can't leave a permanent claim.
  static const heartbeatKey = 'backupHeartbeat';
  static const heartbeatStale = Duration(minutes: 2);

  void _beat() {
    db.setSetting(heartbeatKey, '${DateTime.now().millisecondsSinceEpoch}');
  }

  /// True if another isolate says it is mid-backup right now.
  static bool backupRunningElsewhere(LocalDb db) {
    final beat = int.tryParse(db.getSetting(heartbeatKey) ?? '');
    if (beat == null) return false;
    final age = DateTime.now().millisecondsSinceEpoch - beat;
    return age >= 0 && age < heartbeatStale.inMilliseconds;
  }

  /// The same tallies, restated with a new [stage]. Used to say "getting
  /// ready" or "stopping" without disturbing the counts.
  static UploadProgress _merge(
    UploadProgress base,
    int total,
    DateTime started, {
    required BackupStage stage,
  }) => UploadProgress(
    total: total,
    completed: base.completed,
    uploaded: base.uploaded,
    skipped: base.skipped,
    failed: base.failed,
    bytesUploaded: base.bytesUploaded,
    startedAt: started,
    stage: stage,
  );

  Future<List<UploadResult>> _runBackup({
    required int total,
    required Future<List<UploadSource>?> Function(int completed) nextBatch,
    Compression? compression,
    Duration? budget,
  }) async {
    if (uploading || total == 0) return const [];
    _stopRequested = false;
    stopping = false;
    _missing = 0;
    // Once per backup, not once per batch: a stop pressed between two
    // batches used to be wiped by the next call to `run`.
    _uploader.reset();
    _reloadedAt = 0;
    _lastReload = null;
    _beat();
    _heartbeat = Timer.periodic(const Duration(seconds: 30), (_) => _beat());
    final started = DateTime.now();
    final results = <UploadResult>[];
    recentResults.clear();
    var base = UploadProgress(
      total: total,
      completed: 0,
      uploaded: 0,
      skipped: 0,
      failed: 0,
      startedAt: started,
    );
    upload = base;
    _notify();
    try {
      // The first batch always runs, so every pass makes some progress.
      while (!_stopRequested &&
          (budget == null ||
              results.isEmpty ||
              DateTime.now().difference(started) < budget)) {
        // Getting a batch ready means talking to the photo library, which is
        // slow enough to need saying out loud.
        upload = base = _merge(
          base,
          total,
          started,
          stage: BackupStage.preparing,
        );
        _notify();
        final batch = await nextBatch(results.length);
        // Stop may have been tapped while that was happening.
        if (batch == null || _stopRequested) break;
        final offset = base;
        final missing = _missing;
        final batchResults = await _uploader.run(
          batch,
          compression: compression ?? settings.compression,
          onProgress: (p) {
            upload = base = UploadProgress(
              total: total,
              completed: offset.completed + missing + p.completed,
              uploaded: offset.uploaded + p.uploaded,
              skipped: offset.skipped + missing + p.skipped,
              failed: offset.failed + p.failed,
              // `run` settles everything it staged before returning, so this
              // is always 0 at a batch boundary and needs no offset.
              awaitingCatalogue: p.awaitingCatalogue,
              active: p.active,
              bytesUploaded: offset.bytesUploaded + p.bytesUploaded,
              startedAt: started,
              stage: stopping ? BackupStage.stopping : p.stage,
            );
            // Every tick reaches the status bar, which is cheap. Bumping the
            // revision is not: it re-runs the whole library query in three
            // live views, so it happens only when the set of photos has
            // actually grown, and at most every 1.5s.
            _notify();
            _maybeReload(base.settled);
          },
          onResult: (r) {
            recentResults.insert(0, r);
            if (recentResults.length > _recentKept) recentResults.removeLast();
          },
        );
        _missing = 0;
        results.addAll(batchResults);
        // If the keys stopped working, don't grind through every photo.
        final authFailed =
            batchResults.isNotEmpty &&
            batchResults.every((r) => r.outcome == UploadOutcome.failed) &&
            batchResults.any(
              (r) => (r.error ?? '').startsWith('Access denied'),
            );
        if (authFailed) break;
      }
      lastResults = results;
      return results;
    } finally {
      _heartbeat?.cancel();
      _heartbeat = null;
      db.setSetting(heartbeatKey, '0');
      // Photos that vanished from the phone during the last batch are still
      // part of the run; without this the count ends one or two short.
      final trailing = _missing;
      _missing = 0;
      stopping = false;
      // Mark the run finished even if it stopped early.
      upload = UploadProgress(
        total: base.completed + trailing,
        completed: base.completed + trailing,
        uploaded: base.uploaded,
        skipped: base.skipped + trailing,
        failed: base.failed,
        bytesUploaded: base.bytesUploaded,
        startedAt: started,
        stage: BackupStage.finished,
        stopped: _stopRequested,
      );
      _lastReload = null;
      _changed();
    }
  }

  /// Deletes photos from the bucket. Copies on the phone are untouched.
  Future<void> deletePhotos(Set<String> ids) async {
    if (ids.isEmpty) return;
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final changed = await catalogue.commit([
      for (final id in ids) DeleteOp(id, now),
    ]);
    db.syncFrom(catalogue.state, {...changed, ...ids});
    _changed();
    for (final id in ids) {
      await photos.evict(id);
      try {
        await bucket.deleteObject(BucketLayout.original(id));
        await bucket.deleteObject(BucketLayout.thumbnail(id));
      } catch (_) {
        // The catalogue no longer lists it; leftovers can be swept later.
      }
    }
  }

  /// Records enrichment (place, weather) for many photos in one
  /// catalogue entry. Photos deleted in the meantime are ignored.
  Future<void> patchPhotos(Map<String, Map<String, dynamic>> patches) async {
    if (patches.isEmpty) return;
    final at = DateTime.now().toUtc().millisecondsSinceEpoch;
    final changed = await catalogue.commit([
      for (final e in patches.entries) PatchOp(e.key, e.value, at),
    ]);
    db.syncFrom(catalogue.state, changed);
    if (changed.isNotEmpty) _changed();
  }

  /// Re-runs the library query, but only when there is something new to see
  /// and no more than every [_reloadEvery].
  ///
  /// A revision bump makes the timeline, the calendar and the places view
  /// each re-run an unbounded query inside `setState`. Doing that on every
  /// progress tick pinned the UI thread hard enough to drop taps.
  int _reloadedAt = 0;
  DateTime? _lastReload;
  static const _reloadEvery = Duration(milliseconds: 1500);

  void _maybeReload(int settled) {
    if (settled <= _reloadedAt) return;
    final now = DateTime.now();
    if (_lastReload != null && now.difference(_lastReload!) < _reloadEvery) {
      return;
    }
    _lastReload = now;
    _reloadedAt = settled;
    _changed();
  }

  /// Lets widgets trigger a rebuild after changing settings.
  void settingsChanged() => _notifyAll();

  @override
  void dispose() {
    _disposed = true;
    _heartbeat?.cancel();
    _coarse.dispose();
    bucket.close();
    db.close();
    super.dispose();
  }
}
