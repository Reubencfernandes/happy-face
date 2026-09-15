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
      final firstLoad =
          catalogue.snapshotSeq == 0 && catalogue.state.records.isEmpty;
      final changed = full || firstLoad
          ? await catalogue.load()
          : await catalogue.refresh();
      final stale = firstLoad || full
          ? db.allPhotoIds().difference(catalogue.state.records.keys.toSet())
          : <String>{};
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

  Future<List<UploadResult>> backUp(
    List<UploadSource> sources, {
    Compression? compression,
  }) async {
    if (uploading || sources.isEmpty) return const [];
    upload = UploadProgress(
      total: sources.length,
      completed: 0,
      uploaded: 0,
      skipped: 0,
      failed: 0,
    );
    _notify();
    try {
      final results = await _uploader.run(
        sources,
        compression: compression ?? settings.compression,
        onProgress: (p) {
          upload = p;
          if (p.completed % 5 == 0 || p.done) _changed();
        },
      );
      lastResults = results;
      return results;
    } finally {
      upload = upload == null
          ? null
          : UploadProgress(
              total: upload!.total,
              completed: upload!.total,
              uploaded: upload!.uploaded,
              skipped: upload!.skipped,
              failed: upload!.failed,
            );
      _changed();
    }
  }

  /// Backs up gallery photos by id, e.g. a multi-selection in the timeline.
  Future<List<UploadResult>> backUpAssets(
    Iterable<String> assetIds, {
    Compression? compression,
  }) async {
    final sources = <UploadSource>[];
    for (final id in assetIds) {
      final s = await gallery.sourceFor(id);
      if (s != null) sources.add(s);
    }
    return backUp(sources, compression: compression);
  }

  /// Everything on the phone that isn't backed up yet.
  Future<List<UploadResult>> backUpPending({Compression? compression}) =>
      backUpAssets(db.pendingAssets(limit: 100000), compression: compression);

  void cancelUpload() => _uploader.cancel();

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
