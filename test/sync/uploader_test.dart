import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:happy_drive/crypto/vault.dart';
import 'package:happy_drive/data/bucket_layout.dart';
import 'package:happy_drive/data/local_db.dart';
import 'package:happy_drive/data/remote_catalogue.dart';
import 'package:happy_drive/media/compress.dart';
import 'package:happy_drive/media/file_compress.dart';
import 'package:happy_drive/media/metadata.dart';
import 'package:happy_drive/sync/photo_store.dart';
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

/// Pretends to shrink sound to M4A and PDFs in place, or to fail at it.
class FakeFileCodec implements FileCodec {
  final calls = <String>[];

  /// Makes every "smaller" copy bigger instead.
  bool grow = false;

  @override
  Future<ShrunkFile?> compress(
    Uint8List bytes, {
    required String mime,
    required String name,
    required Compression level,
  }) async {
    calls.add('$name:${level.name}');
    final size = grow ? bytes.length * 2 : bytes.length ~/ 3;
    final out = Uint8List(size)..fillRange(0, size, 5);
    return ShrunkFile(out, mime.startsWith('audio/') ? 'audio/mp4' : mime);
  }
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
  late FakeFileCodec files;

  Uploader uploader({
    int batchSize = 3,
    int singleObjectBytes = Uploader.defaultSingleObjectBytes,
    int partBytes = Uploader.defaultPartBytes,
  }) => Uploader(
    bucket: bucket.client(),
    vault: vault,
    catalogue: catalogue,
    db: db,
    codec: codec,
    files: files,
    batchSize: batchSize,
    singleObjectBytes: singleObjectBytes,
    partBytes: partBytes,
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
    files = FakeFileCodec();
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

  test('sound is re-encoded to M4A and PDFs shrunk, when asked', () async {
    final wav = Uint8List.fromList([
      ...ascii.encode('RIFF'),
      0,
      0,
      0,
      0,
      ...ascii.encode('WAVE'),
      ...List.filled(3000, 1),
    ]);
    final pdf = Uint8List.fromList([
      ...ascii.encode('%PDF-1.7\n'),
      ...List.filled(3000, 2),
    ]);
    final results = await uploader().run([
      source('Interview.wav', wav),
      source('scan.pdf', pdf),
    ], compression: Compression.balanced);
    expect(files.calls, ['Interview.wav:balanced', 'scan.pdf:balanced']);
    final records = catalogue.state.records;
    final audio = records[results[0].photoId!]!;
    expect(audio.name, 'Interview.m4a', reason: 'the name follows the format');
    expect(audio.mime, 'audio/mp4');
    expect(audio.compression, 'balanced');
    expect(audio.size, wav.length ~/ 3);
    final doc = records[results[1].photoId!]!;
    expect(doc.name, 'scan.pdf');
    expect(doc.mime, 'application/pdf');
    expect(doc.compression, 'balanced');
    // Neither is an image, so the photo codec never saw them.
    expect(codec.compressions, 0);
  });

  test('a file compression would make bigger is kept as it was', () async {
    files.grow = true;
    final mp3 = Uint8List.fromList([
      ...ascii.encode('ID3'),
      ...List.filled(2000, 4),
    ]);
    final result = await uploader().run([
      source('song.mp3', mp3),
    ], compression: Compression.high);
    final r = catalogue.state.records[result.single.photoId!]!;
    expect(r.name, 'song.mp3');
    expect(r.mime, 'audio/mpeg');
    expect(r.compression, 'original');
    expect(r.size, mp3.length);
  });

  test('Original never touches sound or PDFs', () async {
    await uploader().run([
      source('memo.m4a', Uint8List.fromList(List.filled(900, 1))),
      source('doc.pdf', Uint8List.fromList(ascii.encode('%PDF-1.4 x'))),
    ]);
    expect(files.calls, isEmpty);
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
      expect(results, isNotEmpty);
      expect(results.every((r) => r.outcome == UploadOutcome.failed), isTrue);
      expect(results.first.error, contains('Access denied'));
      expect(
        bucket.count('PUT'),
        lessThanOrEqualTo(4),
        reason: 'workers stop after the first 403',
      );
      // The photos never attempted are left alone rather than each being
      // reported as its own failure.
      expect(
        results.length,
        lessThan(20),
        reason: 'the run stops instead of failing every photo',
      );
      expect(progress.last.active, isEmpty);
    },
  );

  test('progress names the files in flight and follows their bytes', () async {
    final progress = <UploadProgress>[];
    final results = await uploader(batchSize: 2).run([
      for (var i = 0; i < 6; i++) source('p$i.jpg', photoBytes(i)),
    ], onProgress: progress.add);

    expect(results.every((r) => r.outcome == UploadOutcome.uploaded), isTrue);
    // Every file shows up by name while it is being worked on.
    final named = {
      for (final p in progress)
        for (final a in p.active) a.name,
    };
    expect(named, containsAll([for (var i = 0; i < 6; i++) 'p$i.jpg']));

    // Uploading is reached, and the bar has something to measure.
    final uploading = [
      for (final p in progress)
        for (final a in p.active)
          if (a.phase == UploadPhase.uploading) a,
    ];
    expect(uploading, isNotEmpty);
    expect(uploading.every((a) => a.bytesTotal > 0), isTrue);
    expect(
      uploading.every((a) => a.fraction! >= 0 && a.fraction! <= 1),
      isTrue,
    );

    // Bytes only ever go up, and the finished run counts what was sealed.
    final bytes = progress.map((p) => p.bytesUploaded).toList();
    expect(bytes, orderedEquals(List.of(bytes)..sort()));
    // Bytes belong either to a file still going up or to the run's total,
    // never to both, so the figure on screen can't overshoot the truth.
    final sealed = bucket.objects.entries
        .where((e) => e.key.startsWith('v1/o/') || e.key.startsWith('v1/t/'))
        .fold(0, (sum, e) => sum + e.value.length);
    expect(
      progress.map((p) => p.bytesDone),
      everyElement(lessThanOrEqualTo(sealed)),
    );
    expect(progress.last.bytesUploaded, sealed);
    expect(progress.last.bytesDone, sealed);
    expect(progress.last.active, isEmpty);
    expect(progress.last.done, isTrue);
  });

  test('a failed file leaves nothing behind in the live list', () async {
    bucket.intercept = (r) => r.method == 'PUT' && r.url.path.contains('/v1/o/')
        ? http.Response('<Error><Code>InternalError</Code></Error>', 500)
        : null;
    final progress = <UploadProgress>[];
    final results = await uploader().run([
      source('broken.jpg', photoBytes(1)),
    ], onProgress: progress.add);

    expect(results.single.outcome, UploadOutcome.failed);
    expect(progress.last.active, isEmpty);
    expect(progress.last.failed, 1);
    expect(progress.last.done, isTrue);
  });

  test('a file over the limit is refused without being read', () async {
    // The size the phone reports, not the bytes. Reading a huge video to
    // discover it is huge is what killed the app on a real device.
    var reads = 0;
    final results = await uploader().run([
      UploadSource(
        name: 'holiday.mp4',
        size: Uploader.maxUploadBytes + 1,
        read: () async {
          reads++;
          return Uint8List(0);
        },
      ),
    ]);

    expect(reads, 0, reason: 'the file is never opened');
    expect(results.single.outcome, UploadOutcome.failed);
    expect(results.single.error, contains('most Happy Drive can handle'));
    expect(bucket.objects, isEmpty);
  });

  test(
    'a big file with no file to read in pieces is not pulled into memory',
    () async {
      var reads = 0;
      final results = await uploader().run([
        UploadSource(
          name: 'holiday.mp4',
          size: 2 * 1024 * 1024 * 1024,
          read: () async {
            reads++;
            return Uint8List(0);
          },
        ),
      ]);
      expect(reads, 0);
      expect(results.single.outcome, UploadOutcome.failed);
      expect(results.single.error, contains('2048 MB'));
      expect(bucket.objects, isEmpty);
    },
  );

  group('files bigger than one object', () {
    late Directory temp;
    setUp(() => temp = Directory.systemTemp.createTempSync('parts'));
    tearDown(() => temp.deleteSync(recursive: true));

    /// A 250-byte "video": seven pieces of 40, the last one 10.
    Uint8List video([int seed = 1]) =>
        Uint8List.fromList([for (var i = 0; i < 250; i++) (i * seed) & 255]);

    Uploader small() =>
        uploader(batchSize: 1, singleObjectBytes: 100, partBytes: 40);

    UploadSource onDisk(Uint8List bytes, {String name = 'trip.mp4'}) {
      final file = File('${temp.path}/$name')..writeAsBytesSync(bytes);
      return UploadSource(
        name: name,
        size: bytes.length,
        read: () => throw StateError('read whole'),
        file: () async => file,
      );
    }

    test('go up in pieces read off the disk, and come back whole', () async {
      final results = await small().run([onDisk(video())]);
      expect(results.single.outcome, UploadOutcome.uploaded);
      final id = results.single.photoId!;
      final record = db.photo(id)!;
      expect(record.parts, 7);
      expect(record.partSize, 40);
      expect(record.size, 250);
      expect(bucket.objects.containsKey(BucketLayout.original(id)), isFalse);
      for (var i = 0; i < 7; i++) {
        expect(bucket.objects.containsKey(BucketLayout.part(id, i)), isTrue);
      }
      // The same id the whole file would have had, so it still dedupes.
      expect(id, vault.photoIdFor(video()));

      final store = PhotoStore(bucket.client(), vault)..records = db.photo;
      expect(await store.original(id), video());
      final out = File('${temp.path}/out.mp4');
      final progress = <int>[];
      await store.originalToFile(
        id,
        out,
        onProgress: (received, _) => progress.add(received),
      );
      expect(out.readAsBytesSync(), video());
      expect(progress.last, 250 + 7 * Vault.sealOverhead);
    });

    test('a piece moved to another place won\'t open', () async {
      final results = await small().run([onDisk(video())]);
      final id = results.single.photoId!;
      final swapped = bucket.objects[BucketLayout.part(id, 1)]!;
      bucket.objects[BucketLayout.part(id, 1)] =
          bucket.objects[BucketLayout.part(id, 2)]!;
      bucket.objects[BucketLayout.part(id, 2)] = swapped;
      final store = PhotoStore(bucket.client(), vault)..records = db.photo;
      await expectLater(
        store.original(id),
        throwsA(isA<TamperedDataException>()),
      );
    });

    test('a file already in memory is split too', () async {
      final results = await small().run([
        UploadSource(name: 'mystery.bin', read: () async => video(3)),
      ]);
      expect(results.single.outcome, UploadOutcome.uploaded);
      expect(db.photo(results.single.photoId!)!.parts, 7);
    });

    test('an interrupted upload picks up where it stopped', () async {
      var failNext = true;
      bucket.intercept = (r) {
        if (r.method == 'PUT' && r.url.path.endsWith('.3') && failNext) {
          failNext = false;
          return http.Response(
            '<Error><Code>InternalError</Code></Error>',
            400,
          );
        }
        return null;
      };
      final first = await small().run([onDisk(video())]);
      expect(first.single.outcome, UploadOutcome.failed);

      final before = bucket.log.length;
      final second = await small().run([onDisk(video())]);
      expect(second.single.outcome, UploadOutcome.uploaded);
      final sent = bucket.log
          .skip(before)
          .where((l) => l.startsWith('PUT v1/o/') && l.contains('.'))
          .toList();
      expect(sent, hasLength(4), reason: 'pieces 0-2 were already there');
    });

    test('a second copy is a duplicate, not another upload', () async {
      await small().run([onDisk(video())]);
      final again = await small().run([onDisk(video(), name: 'copy.mp4')]);
      expect(again.single.outcome, UploadOutcome.duplicate);
    });
  });

  test('large files go up one at a time', () async {
    // Four big ones at once is four times the memory, which is what the
    // phone kills the app for.
    var inFlight = 0, peak = 0;
    final sources = [
      for (var i = 0; i < 6; i++)
        UploadSource(
          name: 'big$i.jpg',
          size: Uploader.largeFileBytes + 1,
          read: () async {
            inFlight++;
            peak = peak > inFlight ? peak : inFlight;
            await Future<void>.delayed(const Duration(milliseconds: 5));
            inFlight--;
            return photoBytes(i);
          },
        ),
    ];
    final results = await uploader().run(sources);

    expect(results.every((r) => r.outcome == UploadOutcome.uploaded), isTrue);
    expect(peak, 1, reason: 'never two big files in memory together');
  });

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
