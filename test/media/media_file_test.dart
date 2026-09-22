import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:happy_drive/crypto/vault.dart';
import 'package:happy_drive/data/bucket_layout.dart';
import 'package:happy_drive/data/local_db.dart';
import 'package:happy_drive/media/gallery.dart';
import 'package:happy_drive/media/media_file.dart';
import 'package:happy_drive/sync/photo_store.dart';

import '../support/fake_bucket.dart';

/// A phone that has, or hasn't, its own copy of an asset.
class FakeGallery extends Gallery {
  final File? file;
  const FakeGallery([this.file]);
  @override
  Future<File?> fileFor(String assetId) async => file;
}

TimelineItem item({String? photoId, String? assetId, String? mime}) =>
    TimelineItem(
      photoId: photoId,
      assetId: assetId,
      takenAt: DateTime.utc(2026, 5, 1),
      tzOffsetMinutes: 0,
      state: photoId == null
          ? BackupState.localOnly
          : assetId == null
          ? BackupState.cloudOnly
          : BackupState.backedUp,
      mime: mime,
    );

void main() {
  late Directory temp;
  late FakeBucket bucket;
  late Vault vault;
  late PhotoStore photos;

  const id = 'ab0123456789';
  final clip = Uint8List.fromList(List.filled(5000, 42));

  MediaCache cacheWith([Gallery gallery = const FakeGallery()]) => MediaCache(
    photos,
    gallery: gallery,
    dir: () async => Directory('${temp.path}/playing'),
  );

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('happy_media');
    bucket = FakeBucket();
    vault = await Vault.fromMasterKey(List.filled(32, 3));
    photos = PhotoStore(bucket.client(), vault);
    final key = BucketLayout.original(id);
    bucket.objects[key] = await vault.seal(clip, context: key);
  });
  tearDown(() => temp.delete(recursive: true));

  test('a cloud video is decrypted to a file the player can open', () async {
    final progress = <int>[];
    final cache = cacheWith();
    final playable = await cache.open(
      item(photoId: id, mime: 'video/mp4'),
      onProgress: (received, _) => progress.add(received),
    );

    // The extension matters: players choose a decoder by it.
    expect(playable.path, endsWith('.mp4'));
    expect(await playable.file.readAsBytes(), clip);
    expect(progress, isNotEmpty);
    expect(progress.last, greaterThan(0));

    // And it is gone the moment the viewer lets go of it.
    await playable.release();
    expect(await playable.file.exists(), isFalse);
  });

  test('the phone\'s own copy is used and never deleted', () async {
    final onPhone = File('${temp.path}/holiday.mp4')..writeAsBytesSync(clip);
    final cache = cacheWith(FakeGallery(onPhone));

    final playable = await cache.open(
      item(photoId: id, assetId: 'asset1', mime: 'video/mp4'),
    );
    expect(playable.path, onPhone.path);
    expect(bucket.count('GET'), 0, reason: 'nothing is downloaded');

    await playable.release();
    expect(onPhone.existsSync(), isTrue);
  });

  test('a phone copy that has gone falls back to the bucket', () async {
    final cache = cacheWith();
    final playable = await cache.open(
      item(photoId: id, assetId: 'asset1', mime: 'video/quicktime'),
    );
    expect(playable.path, endsWith('.mov'));
    expect(await playable.file.readAsBytes(), clip);
  });

  test('nothing to play without a backup', () async {
    await expectLater(
      cacheWith().open(item(assetId: 'asset1', mime: 'video/mp4')),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('a sweep clears what a crash left behind', () async {
    final cache = cacheWith();
    final playable = await cache.open(item(photoId: id, mime: 'video/mp4'));
    expect(await playable.file.exists(), isTrue);

    await cache.sweep();
    expect(await playable.file.exists(), isFalse);
    expect(await Directory('${temp.path}/playing').exists(), isFalse);
  });
}
