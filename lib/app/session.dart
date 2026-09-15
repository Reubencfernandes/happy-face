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
import '../media/gallery.dart';
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

  bool get autoBackup => _db.getSetting('autoBackup') == 'true';
  set autoBackup(bool v) => _db.setSetting('autoBackup', '$v');

  bool get wifiOnly => _db.getSetting('wifiOnly') != 'false';
  set wifiOnly(bool v) => _db.setSetting('wifiOnly', '$v');

  bool get weather => _db.getSetting('weather') == 'true';
  set weather(bool v) => _db.setSetting('weather', '$v');

  bool get aiCaptions => _db.getSetting('aiCaptions') == 'true';
  set aiCaptions(bool v) => _db.setSetting('aiCaptions', '$v');

  String get aiModel => _db.getSetting('aiModel') ?? defaultAiModel;
  set aiModel(String v) =>
      _db.setSetting('aiModel', v.trim().isEmpty ? null : v.trim());

  int get aiDailyLimit =>
      int.tryParse(_db.getSetting('aiDailyLimit') ?? '') ?? 50;
  set aiDailyLimit(int v) => _db.setSetting('aiDailyLimit', '$v');

  bool get aiWholeLibrary => _db.getSetting('aiWholeLibrary') == 'true';
  set aiWholeLibrary(bool v) => _db.setSetting('aiWholeLibrary', '$v');

  static const defaultAiModel = 'Qwen/Qwen3.8-27B';
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
  late final Uploader _uploader;

  /// Bumped whenever photos are added, changed or removed.
  int revision = 0;
  bool syncing = false;
  String? syncError;
  UploadProgress? upload;
  List<UploadResult> lastResults = const [];
  PermissionState? galleryAccess;
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
  }) : catalogue = RemoteCatalogue(bucket, vault) {
    _uploader = Uploader(
      bucket: bucket,
      vault: vault,
      catalogue: catalogue,
      db: db,
      codec: codec,
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
    return Session(
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
  }

  bool get uploading => upload != null && !upload!.done;

  void _changed() {
    if (_disposed) return;
    revision++;
    notifyListeners();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Pulls the catalogue from the bucket and mirrors it locally. The timeline
  /// shows the local mirror immediately, so this runs in the background.
  Future<void> sync({bool full = false}) async {
    if (syncing) return;
    syncing = true;
    syncError = null;
    _notify();
    try {
      final firstLoad = !_loadedOnce;
      final changed = full || firstLoad
          ? await catalogue.load()
          : await catalogue.refresh();
      final stale = firstLoad || full
          ? db.allPhotoIds().difference(catalogue.state.records.keys.toSet())
          : <String>{};
      _loadedOnce = true;
      if (changed.isNotEmpty || stale.isNotEmpty) {
        db.syncFrom(catalogue.state, {...changed, ...stale});
        _changed();
      }
    } on S3Exception catch (e) {
      syncError = e.friendly;
    } on SocketException {
      syncError = 'Offline. Showing photos saved on this phone.';
    } catch (e) {
      syncError = 'Could not sync: $e';
    } finally {
      syncing = false;
      _notify();
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
        _notify();
      }
      return state;
    } catch (_) {
      // No photo library on this platform, or the OS refused: cloud only.
      galleryAccess = PermissionState.denied;
      _notify();
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
    int batchSize = 50,
  }) {
    var next = 0;
    return _runBackup(
      total: assetIds.length,
      compression: compression,
      budget: budget,
      nextBatch: (_) async {
        while (next < assetIds.length) {
          final ids = assetIds.skip(next).take(batchSize).toList();
          next += ids.length;
          final sources = <UploadSource>[];
          for (final id in ids) {
            final source = await gallery.sourceFor(id);
            if (source != null) sources.add(source);
          }
          // Photos deleted from the phone since the last scan are skipped.
          _missing += ids.length - sources.length;
          if (sources.isNotEmpty) return sources;
        }
        return null;
      },
    );
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
  void cancelUpload() {
    _stopRequested = true;
    _uploader.cancel();
  }

  bool _stopRequested = false;
  int _missing = 0;

  Future<List<UploadResult>> _runBackup({
    required int total,
    required Future<List<UploadSource>?> Function(int completed) nextBatch,
    Compression? compression,
    Duration? budget,
  }) async {
    if (uploading || total == 0) return const [];
    _stopRequested = false;
    _missing = 0;
    final started = DateTime.now();
    final results = <UploadResult>[];
    var base = UploadProgress(
      total: total,
      completed: 0,
      uploaded: 0,
      skipped: 0,
      failed: 0,
    );
    upload = base;
    _notify();
    try {
      // The first batch always runs, so every pass makes some progress.
      while (!_stopRequested &&
          (budget == null ||
              results.isEmpty ||
              DateTime.now().difference(started) < budget)) {
        final batch = await nextBatch(results.length);
        if (batch == null) break;
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
            );
            if (p.completed % 5 == 0 || p.done) _changed();
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
      // Mark the run finished even if it stopped early.
      upload = UploadProgress(
        total: base.completed,
        completed: base.completed,
        uploaded: base.uploaded,
        skipped: base.skipped,
        failed: base.failed,
      );
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

  /// Applies an enrichment patch (place, weather, caption) to one photo.
  Future<void> patchPhoto(String id, Map<String, dynamic> fields) async {
    final changed = await catalogue.commit([
      PatchOp(id, fields, DateTime.now().toUtc().millisecondsSinceEpoch),
    ]);
    db.syncFrom(catalogue.state, changed);
    _changed();
  }

  /// Lets widgets trigger a rebuild after changing settings.
  void settingsChanged() => _notify();

  @override
  void dispose() {
    _disposed = true;
    bucket.close();
    db.close();
    super.dispose();
  }
}
