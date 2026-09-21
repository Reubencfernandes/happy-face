import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:happy_drive/app/credentials.dart';
import 'package:happy_drive/app/session.dart';
import 'package:happy_drive/crypto/vault.dart';
import 'package:happy_drive/data/bucket_layout.dart';
import 'package:happy_drive/data/catalogue.dart';
import 'package:happy_drive/data/local_db.dart';
import 'package:happy_drive/data/remote_catalogue.dart';
import 'package:happy_drive/media/gallery.dart';
import 'package:happy_drive/sync/photo_store.dart';
import 'package:happy_drive/sync/uploader.dart';
import 'package:http/http.dart' as http;
import 'package:photo_manager/photo_manager.dart';

import '../support/fake_bucket.dart';
import '../sync/uploader_test.dart' show FakeCodec, photoBytes;

/// A phone gallery with [count] photos; ids listed in [gone] were deleted.
class FakeGallery extends Gallery {
  final int count;
  final Set<String> gone;
  int resolved = 0;
  FakeGallery(this.count, {this.gone = const {}});

  String id(int i) => 'asset$i';

  @override
  Future<PermissionState> currentAccess() async => PermissionState.authorized;

  @override
  Future<List<DeviceAsset>> scan() async => [
    for (var i = 0; i < count; i++)
      DeviceAsset(
        assetId: id(i),
        takenAt: DateTime.utc(2025, 1, 1).add(Duration(hours: i)),
        modifiedAt: DateTime.utc(2025),
      ),
  ];

  @override
  Future<UploadSource?> sourceFor(String assetId) async {
    resolved++;
    if (gone.contains(assetId)) return null;
    final seed = int.parse(assetId.substring(5));
    return UploadSource(
      name: '$assetId.jpg',
      assetId: assetId,
      read: () async => Uint8List.fromList([
        ...photoBytes(seed % 256),
        seed >> 8,
        seed & 255,
      ]),
    );
  }
}

void main() {
  late FakeBucket bucket;
  late Vault vault;

  setUp(() async {
    bucket = FakeBucket();
    vault = await Vault.fromMasterKey(List.filled(32, 4));
  });

  Session sessionWith(Gallery gallery) {
    final client = bucket.client();
    return Session(
      account: const StoredAccount(
        namespace: 'reuben',
        bucket: 'happy-drive',
        accessKeyId: 'HFAKTEST',
        secretAccessKey: 's',
      ),
      bucket: client,
      vault: vault,
      db: LocalDb.inMemory(),
      photos: PhotoStore(client, vault),
      credentials: const CredentialStore(),
      gallery: gallery,
      codec: FakeCodec(),
    );
  }

  test('backs up a large gallery in batches with overall progress', () async {
    final gallery = FakeGallery(120, gone: {'asset7'});
    final session = sessionWith(gallery);
    addTearDown(session.dispose);
    await session.scanGallery();
    expect(session.db.backupStats().pending, 120);

    final seen = <UploadProgress>[];
    session.addListener(() {
      final p = session.upload;
      if (p != null) seen.add(p);
    });
    final results = await session.backUpPending();

    expect(
      results.where((r) => r.outcome == UploadOutcome.uploaded),
      hasLength(119),
    );
    expect(
      seen.map((p) => p.total).where((t) => t != 120 && t != seen.last.total),
      isEmpty,
    );
    expect(seen.last.done, isTrue);
    expect(
      seen.last.completed,
      120,
      reason: 'the missing photo counts as skipped',
    );
    expect(session.db.backupStats().pending, 1);
    expect(session.catalogue.state.records, hasLength(119));
    // Progress only ever moves forward.
    for (var i = 1; i < seen.length; i++) {
      expect(seen[i].completed, greaterThanOrEqualTo(seen[i - 1].completed));
    }
  });

  test(
    'a time budget stops between batches but always makes progress',
    () async {
      final gallery = FakeGallery(150);
      final session = sessionWith(gallery);
      addTearDown(session.dispose);
      await session.scanGallery();

      final results = await session.backUpPending(budget: Duration.zero);
      expect(results, hasLength(50), reason: 'exactly one batch');
      expect(session.uploading, isFalse);

      // The next pass picks up where this one stopped.
      await session.backUpPending();
      expect(session.db.backupStats().pending, 0);
    },
  );

  test('stop finishes the current photos and starts nothing new', () async {
    final gallery = FakeGallery(200);
    final session = sessionWith(gallery);
    addTearDown(session.dispose);
    await session.scanGallery();
    session.addListener(() {
      if ((session.upload?.completed ?? 0) >= 10) session.cancelUpload();
    });
    await session.backUpPending();
    expect(gallery.resolved, lessThanOrEqualTo(100));
    expect(session.uploading, isFalse);
    expect(session.db.backupStats().pending, greaterThan(100));
  });

  test('deleting frees bucket space and syncs to other devices', () async {
    final session = sessionWith(FakeGallery(3));
    addTearDown(session.dispose);
    await session.scanGallery();
    final results = await session.backUpPending();
    final id = results.first.photoId!;
    expect(bucket.objects.containsKey(BucketLayout.original(id)), isTrue);

    await session.deletePhotos({id});
    expect(bucket.objects.containsKey(BucketLayout.original(id)), isFalse);
    expect(bucket.objects.containsKey(BucketLayout.thumbnail(id)), isFalse);
    expect(session.db.photo(id), isNull);
    // The phone copy stays and is shown as not backed up.
    expect(session.db.timeline(filter: TimelineFilter.localOnly), hasLength(1));

    final otherPhone = RemoteCatalogue(bucket.client(), vault);
    await otherPhone.load();
    expect(otherPhone.state.records.keys, isNot(contains(id)));
    expect(otherPhone.state.records, hasLength(2));
  });

  test('sync mirrors other devices and drops photos they deleted', () async {
    final session = sessionWith(FakeGallery(0));
    addTearDown(session.dispose);
    final other = RemoteCatalogue(bucket.client(), vault);
    PhotoRecord rec(String id) => PhotoRecord(
      id: id,
      name: '$id.jpg',
      mime: 'image/jpeg',
      size: 1,
      takenAt: DateTime.utc(2025),
      uploadedAt: DateTime.utc(2025),
    );
    await other.commit([PutOp(rec('p1'), 1), PutOp(rec('p2'), 2)]);
    await session.sync();
    expect(session.db.allPhotoIds(), {'p1', 'p2'});

    await other.commit([
      DeleteOp('p1', 3),
      PatchOp('p2', {'place': 'Lisbon'}, 4),
    ]);
    final before = session.revision;
    await session.sync();
    expect(session.db.allPhotoIds(), {'p2'});
    expect(session.db.photo('p2')!.place, 'Lisbon');
    expect(session.revision, greaterThan(before));
    expect(session.syncError, isNull);
  });

  test('sync reports a friendly error instead of throwing', () async {
    final session = sessionWith(FakeGallery(0));
    addTearDown(session.dispose);
    bucket.intercept = (_) =>
        http.Response('<Error><Code>AccessDenied</Code></Error>', 403);
    await session.sync();
    expect(session.syncError, contains('Access denied'));
    expect(session.syncing, isFalse);
  });
}
