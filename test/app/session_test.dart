import 'dart:io' show SocketException;
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

  test('deleting a file stored in pieces clears every piece', () async {
    final client = bucket.client();
    final session = Session(
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
      gallery: FakeGallery(0),
      codec: FakeCodec(),
      singleObjectBytes: 100,
      partBytes: 40,
    );
    final results = await session.backUp([
      UploadSource(
        name: 'long.mp4',
        read: () async => Uint8List.fromList(List.generate(250, (i) => i)),
      ),
    ]);
    final id = results.single.photoId!;
    expect(
      bucket.objects.keys.where((k) => k.startsWith('v1/o/')),
      hasLength(7),
    );
    expect(await session.photos.original(id), List.generate(250, (i) => i));

    await session.deletePhotos({id});
    expect(bucket.objects.keys.where((k) => k.startsWith('v1/o/')), isEmpty);
  });

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

    expect(session.upload!.stopped, isFalse, reason: 'it ran to the end');
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
      expect(results, hasLength(16), reason: 'exactly one batch');
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
      if ((session.upload?.settled ?? 0) >= 10) session.cancelUpload();
    });
    final results = await session.backUpPending();

    expect(session.uploading, isFalse);
    expect(session.stopping, isFalse, reason: 'the stop has landed');
    expect(
      session.upload!.stopped,
      isTrue,
      reason: 'the run knows it was stopped, so it can say so',
    );
    expect(session.db.backupStats().pending, greaterThan(100));
    // A stop is not a failure. Every photo it never got to is simply left
    // for next time rather than being reported as an error.
    expect(
      results.where((r) => r.outcome == UploadOutcome.failed),
      isEmpty,
      reason: 'stopping must not manufacture failures',
    );
    expect(session.upload!.failed, 0);
    // And it stops promptly rather than grinding out another whole batch.
    expect(gallery.resolved, lessThanOrEqualTo(48));
  });

  test('a stop during the prepare gap is not forgotten', () async {
    final gallery = FakeGallery(200);
    final session = sessionWith(gallery);
    addTearDown(session.dispose);
    await session.scanGallery();
    // Stop the moment the very first batch is being got ready, which is the
    // window a stop used to fall into and be wiped by the next batch.
    session.addListener(() {
      if (session.upload?.stage == BackupStage.preparing) {
        session.cancelUpload();
      }
    });
    final results = await session.backUpPending();

    expect(session.uploading, isFalse);
    expect(results.where((r) => r.outcome == UploadOutcome.failed), isEmpty);
    expect(
      session.db.backupStats().pending,
      greaterThan(150),
      reason: 'barely anything should have gone up',
    );
  });

  test('the library is not re-queried on every progress tick', () async {
    final gallery = FakeGallery(60);
    final session = sessionWith(gallery);
    addTearDown(session.dispose);
    await session.scanGallery();

    var ticks = 0;
    var revisions = 0;
    var lastRevision = session.revision;
    session.addListener(() {
      ticks++;
      if (session.revision != lastRevision) {
        lastRevision = session.revision;
        revisions++;
      }
    });
    await session.backUpPending();

    expect(ticks, greaterThan(10), reason: 'the bar still updates often');
    // Each revision bump re-runs an unbounded query in three live views.
    expect(
      revisions,
      lessThan(10),
      reason: 'the expensive reload is throttled, not per tick',
    );
  });

  test(
    'a bucket deleted on the website is called out, not shrugged off',
    () async {
      final session = sessionWith(FakeGallery(2));
      addTearDown(session.dispose);
      await session.scanGallery();
      await session.backUpPending();
      expect(session.db.timeline(), isNotEmpty);

      // Someone deletes the bucket on huggingface.co. Everything 404s,
      // including the bucket itself.
      bucket.intercept = (r) =>
          http.Response('<Error><Code>NoSuchBucket</Code></Error>', 404);
      await session.sync(full: true);

      expect(session.bucketMissing, isTrue);
      expect(session.syncError, contains('no longer in your Hugging Face'));
      expect(session.syncError, contains('happy-drive'));
    },
  );

  test('a missing object is not mistaken for a deleted bucket', () async {
    final session = sessionWith(FakeGallery(2));
    addTearDown(session.dispose);
    await session.scanGallery();
    await session.backUpPending();

    // One object is gone, but the bucket answers. A HEAD on the bucket
    // itself has an empty key.
    bucket.intercept = (r) => r.method == 'GET'
        ? http.Response('<Error><Code>NoSuchKey</Code></Error>', 404)
        : null;
    await session.sync(full: true);

    expect(session.bucketMissing, isFalse, reason: 'the bucket is still there');
  });

  test('a dropped connection is never reported as a deleted bucket', () async {
    final session = sessionWith(FakeGallery(2));
    addTearDown(session.dispose);
    await session.scanGallery();
    await session.backUpPending();

    var seen = 0;
    bucket.intercept = (r) {
      seen++;
      // The catalogue 404s, and then the bucket check can't get through.
      return seen == 1
          ? http.Response('<Error><Code>NoSuchKey</Code></Error>', 404)
          : throw const SocketException('offline');
    };
    await session.sync(full: true);

    expect(
      session.bucketMissing,
      isFalse,
      reason: 'better silent than announcing a deletion because Wi-Fi dropped',
    );
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
