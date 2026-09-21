import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:happy_drive/crypto/vault.dart';
import 'package:happy_drive/data/bucket_layout.dart';
import 'package:happy_drive/data/local_db.dart';
import 'package:happy_drive/data/remote_catalogue.dart';
import 'package:happy_drive/media/compress.dart';
import 'package:happy_drive/media/metadata.dart';
import 'package:happy_drive/sync/uploader.dart';
import 'package:http/http.dart' as http;

import '../support/exif_jpeg.dart';
import '../support/fake_bucket.dart';

/// Pretends to re-encode: returns a JPEG half the size.
class FakeCodec implements ImageCodec {
  int compressions = 0;
  @override
  Future<Uint8List?> compress(Uint8List bytes, Compression level) async {
    compressions++;
    return Uint8List.fromList([
      0xFF,
      0xD8,
      0xFF,
      ...List.filled(bytes.length ~/ 2, 1),
    ]);
  }

  @override
  Future<Uint8List?> thumbnail(Uint8List bytes, {int size = 400}) async =>
      Uint8List.fromList([0xFF, 0xD8, 0xFF, 7, 7, 7]);
}

Uint8List photoBytes(int seed, {String date = '2025:06:01 10:00:00'}) =>
    jpegWithExif(
      dateTimeOriginal: date,
      offsetTimeOriginal: '+05:30',
      latitude: [
        [15, 1],
        [29, 1],
        [24, 1],
      ],
      longitude: [
        [73, 1],
        [49, 1],
        [12, 1],
      ],
      filler: List.filled(2000, seed),
    );

void main() {
  late FakeBucket bucket;
  late Vault vault;
  late LocalDb db;
  late RemoteCatalogue catalogue;
  late FakeCodec codec;

  Uploader uploader({int batchSize = 3}) => Uploader(
    bucket: bucket.client(),
    vault: vault,
    catalogue: catalogue,
    db: db,
    codec: codec,
    batchSize: batchSize,
    clock: () => DateTime.utc(2026, 9, 15, 12),
  );

  UploadSource source(String name, Uint8List bytes, {String? assetId}) =>
      UploadSource(name: name, assetId: assetId, read: () async => bytes);

  setUp(() async {
    bucket = FakeBucket();
    vault = await Vault.fromMasterKey(List.filled(32, 9));
    db = LocalDb.inMemory();
    catalogue = RemoteCatalogue(bucket.client(), vault);
    codec = FakeCodec();
  });
  tearDown(() => db.close());

  test(
    'uploads encrypted originals and thumbnails, then catalogues them',
    () async {
      final results = await uploader().run([
        for (var i = 0; i < 7; i++) source('IMG_$i.jpg', photoBytes(i)),
      ]);
      expect(results.map((r) => r.outcome).toSet(), {UploadOutcome.uploaded});
      final ids = results.map((r) => r.photoId!).toSet();
      expect(ids, hasLength(7));
      for (final id in ids) {
        expect(bucket.objects.containsKey(BucketLayout.original(id)), isTrue);
        expect(bucket.objects.containsKey(BucketLayout.thumbnail(id)), isTrue);
      }
      // 7 photos in batches of 3 -> 3 journal entries.
      expect(
        bucket.objects.keys.where((k) => k.startsWith('v1/j/')),
        hasLength(3),
      );

      final rec = db.photo(results.first.photoId!)!;
      expect(rec.name, 'IMG_0.jpg');
      expect(rec.takenAt, DateTime.utc(2025, 6, 1, 4, 30));
      expect(rec.tzOffsetMinutes, 330);
      expect(rec.lat, closeTo(15.49, 0.001));
      expect(rec.compression, 'original');
      expect(db.dueJobs(JobKind.place, DateTime.utc(2030)), hasLength(7));

      // The stored original decrypts back to exactly the input.
      final key = BucketLayout.original(rec.id);
      expect(
        await vault.open(bucket.objects[key]!, context: key),
        photoBytes(0),
      );
    },
  );

  test('bucket contents reveal no names, dates or pixels', () async {
    final bytes = photoBytes(1);
    await uploader().run([source('holiday-with-mom.jpg', bytes)]);
    final marker = latin1.decode(bytes.sublist(0, 40));
    for (final e in bucket.objects.entries) {
      final text = latin1.decode(e.value);
      expect(text, isNot(contains('holiday')));
      expect(text, isNot(contains('2025:06:01')));
      expect(text, isNot(contains(marker)));
      expect(e.key, isNot(contains('holiday')));
    }
  });

  test('the same photo twice is stored once, even in the same run', () async {
    final bytes = photoBytes(5);
    final results = await uploader().run([
      source('a.jpg', bytes, assetId: 'asset-a'),
      source('copy-of-a.jpg', bytes, assetId: 'asset-b'),
      source('b.jpg', photoBytes(6)),
    ]);
    expect(
      results.where((r) => r.outcome == UploadOutcome.uploaded),
      hasLength(2),
    );
    expect(
      results.where((r) => r.outcome == UploadOutcome.duplicate),
      hasLength(1),
    );
    expect(results[0].photoId, results[1].photoId);
    expect(
      bucket.objects.keys.where((k) => k.startsWith('v1/o/')),
      hasLength(2),
    );

    // Another phone with the same photo uploads nothing.
    bucket.log.clear();
    final again = await uploader().run([source('same.jpg', bytes)]);
    expect(again.single.outcome, UploadOutcome.duplicate);
    expect(bucket.count('PUT'), 0);
  });

  test(
    'gallery photos already backed up are skipped without reading them',
    () async {
      db.upsertDeviceAssets([
        DeviceAsset(
          assetId: 'g1',
          takenAt: DateTime.utc(2025),
          modifiedAt: DateTime.utc(2025),
        ),
      ]);
      await uploader().run([source('g1.jpg', photoBytes(1), assetId: 'g1')]);
      expect(db.uploadedPhotoFor('g1'), isNotNull);

      var reads = 0;
      final second = await uploader().run([
        UploadSource(
          name: 'g1.jpg',
          assetId: 'g1',
          read: () async {
            reads++;
            return photoBytes(1);
          },
        ),
      ]);
      expect(second.single.outcome, UploadOutcome.alreadyBackedUp);
      expect(reads, 0);
      expect(db.backupStats().pending, 0);
    },
  );

  test('compression is used only when it actually saves space', () async {
    final results = await uploader().run([
      source('big.jpg', photoBytes(3)),
      source(
        'anim.gif',
        Uint8List.fromList(ascii.encode('GIF89a${'x' * 100}')),
      ),
    ], compression: Compression.high);
    final jpeg = db.photo(results[0].photoId!)!;
    expect(jpeg.compression, 'high');
    expect(jpeg.size, lessThan(photoBytes(3).length));
    final gif = db.photo(results[1].photoId!)!;
    expect(gif.compression, 'original', reason: 'GIFs would lose animation');
    expect(codec.compressions, 1);
  });

  test('photo ids ignore compression level, so dedupe still works', () async {
    final bytes = photoBytes(4);
    final a = await uploader().run([source('x.jpg', bytes)]);
    final b = await uploader().run([
      source('x.jpg', bytes),
    ], compression: Compression.balanced);
    expect(b.single.outcome, UploadOutcome.duplicate);
    expect(b.single.photoId, a.single.photoId);
  });

  test('transient errors are retried; a bad file fails alone', () async {
    var failures = 0;
    bucket.intercept = (r) {
      if (r.method == 'PUT' && r.url.path.contains('/v1/o/') && failures < 2) {
        failures++;
        return http.Response('', 503);
      }
      return null;
    };
    final results = await uploader().run([
      source('ok.jpg', photoBytes(1)),
      // A photo that lives in iCloud and can't be read right now.
      UploadSource(
        name: 'away.jpg',
        read: () async => throw const FormatException('Not on the phone.'),
      ),
      source('ok2.jpg', photoBytes(2)),
    ]);
    expect(results.map((r) => r.outcome), [
      UploadOutcome.uploaded,
      UploadOutcome.failed,
      UploadOutcome.uploaded,
    ]);
    expect(results[1].error, contains('Not on the phone'));
    expect(failures, 2);
  });

  test('videos and other files are stored as they are', () async {
    final video = Uint8List.fromList([
      0,
      0,
      0,
      24,
      ...ascii.encode('ftypisom'),
      ...List.filled(400, 3),
    ]);
    final results = await uploader().run([
      source('holiday.mov', video),
      source('notes.txt', Uint8List.fromList(utf8.encode('hello there'))),
    ], compression: Compression.balanced);
    expect(results.map((r) => r.outcome), [
      UploadOutcome.uploaded,
      UploadOutcome.uploaded,
    ]);
    final records = catalogue.state.records;
    final stored = {
      for (final r in results) records[r.photoId!]!.name: records[r.photoId!]!,
    };
    expect(stored['holiday.mov']!.mime, 'video/mp4');
    expect(stored['notes.txt']!.mime, 'text/plain');
    // Nothing was re-encoded, and neither file invented a thumbnail.
    expect(codec.compressions, 0);
    for (final r in results) {
      expect(
        bucket.objects.containsKey(BucketLayout.thumbnail(r.photoId!)),
        isFalse,
      );
      expect(records[r.photoId!]!.compression, 'original');
    }
  });

  test('an interrupted run resumes without duplicates', () async {
    final sources = [
      for (var i = 0; i < 6; i++)
        source('p$i.jpg', photoBytes(i), assetId: 'a$i'),
    ];
    db.upsertDeviceAssets([
      for (var i = 0; i < 6; i++)
        DeviceAsset(
          assetId: 'a$i',
          takenAt: DateTime.utc(2025),
          modifiedAt: DateTime.utc(2025),
        ),
    ]);
    // The network dies after the first 2 photos' objects are written.
    var puts = 0;
    bucket.intercept = (r) {
      if (r.method == 'PUT' && r.url.path.contains('/v1/') && ++puts > 4) {
        return http.Response('<Error><Code>AccessDenied</Code></Error>', 403);
      }
      return null;
    };
    final first = await uploader(batchSize: 2).run(sources);
    expect(
      first.where((r) => r.outcome == UploadOutcome.uploaded).length,
      lessThan(6),
    );

    bucket.intercept = null;
    final second = await uploader(batchSize: 2).run(sources);
    final outcomes = second.map((r) => r.outcome).toList();
    expect(
      outcomes,
      everyElement(
        anyOf(UploadOutcome.uploaded, UploadOutcome.alreadyBackedUp),
      ),
    );
    expect(db.backupStats().pending, 0);
    expect(catalogue.state.records, hasLength(6));
    expect(
      bucket.objects.keys.where((k) => k.startsWith('v1/o/')),
      hasLength(6),
    );
  });

  test(
    'an auth failure stops the run instead of failing every photo slowly',
    () async {
      bucket.intercept = (r) => r.method == 'PUT'
          ? http.Response('<Error><Code>AccessDenied</Code></Error>', 403)
          : null;
      final progress = <UploadProgress>[];
      final results = await uploader().run([
        for (var i = 0; i < 20; i++) source('p$i.jpg', photoBytes(i)),
      ], onProgress: progress.add);
      expect(results.every((r) => r.outcome == UploadOutcome.failed), isTrue);
      expect(results.last.error, contains('Access denied'));
      expect(
        bucket.count('PUT'),
        lessThanOrEqualTo(4),
        reason: 'workers stop after the first 403',
      );
      expect(progress.last.done, isTrue);
    },
  );

  test('gallery metadata is used when the file has none', () async {
    final results = await uploader().run([
      UploadSource(
        name: 'screenshot.png',
        read: () async => base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aKXcAAAAASUVORK5CYII=',
        ),
        known: PhotoMetadata(
          takenAt: DateTime.utc(2022, 3, 4),
          lat: 38.72,
          lng: -9.14,
        ),
      ),
    ]);
    final rec = db.photo(results.single.photoId!)!;
    expect(rec.takenAt, DateTime.utc(2022, 3, 4));
    expect(rec.lng, -9.14);
    expect(rec.mime, 'image/png');
  });
}
