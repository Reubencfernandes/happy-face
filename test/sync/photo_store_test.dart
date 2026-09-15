import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:happy_drive/crypto/vault.dart';
import 'package:happy_drive/data/bucket_layout.dart';
import 'package:happy_drive/sync/photo_store.dart';

import '../support/fake_bucket.dart';

void main() {
  late FakeBucket bucket;
  late Vault vault;
  late Directory dir;
  final pixels = List.generate(64, (i) => i);

  setUp(() async {
    bucket = FakeBucket();
    vault = await Vault.fromMasterKey(List.filled(32, 2));
    dir = await Directory.systemTemp.createTemp('photo_store_test');
    for (final id in ['aa11', 'bb22']) {
      final key = BucketLayout.thumbnail(id);
      bucket.objects[key] = await vault.seal(pixels, context: key);
      final original = BucketLayout.original(id);
      bucket.objects[original] = await vault.seal([1, 2, 3], context: original);
    }
  });
  tearDown(() => dir.delete(recursive: true));

  test(
    'loads, caches and dedupes thumbnails (regression: loads never finished)',
    () async {
      final store = PhotoStore(bucket.client(), vault, cacheDir: dir);
      final results = await Future.wait([
        store.thumbnail('aa11'),
        store.thumbnail('aa11'),
        store.thumbnail('bb22'),
      ]).timeout(const Duration(seconds: 5));
      expect(results[0], pixels);
      expect(results[2], pixels);
      expect(
        bucket.count('GET'),
        2,
        reason: 'concurrent requests share one download',
      );

      // Later loads come from memory, then from the encrypted disk cache.
      expect(await store.thumbnail('aa11'), pixels);
      expect(store.cachedThumbnail('aa11'), pixels);
      final fresh = PhotoStore(bucket.client(), vault, cacheDir: dir);
      expect(
        await fresh.thumbnail('aa11').timeout(const Duration(seconds: 5)),
        pixels,
      );
      expect(bucket.count('GET'), 2);
    },
  );

  test('the disk cache holds only encrypted bytes', () async {
    final store = PhotoStore(bucket.client(), vault, cacheDir: dir);
    await store.thumbnail('aa11');
    final cached = File('${dir.path}/t_aa11').readAsBytesSync();
    expect(cached, isNot(containsAllInOrder(pixels.sublist(0, 16))));
    expect(cached, bucket.objects[BucketLayout.thumbnail('aa11')]);
  });

  test('a corrupt cache file is dropped and re-downloaded next time', () async {
    File('${dir.path}/t_aa11')
      ..createSync(recursive: true)
      ..writeAsBytesSync([1, 2, 3, 4]);
    final store = PhotoStore(bucket.client(), vault, cacheDir: dir);
    await expectLater(
      store.thumbnail('aa11'),
      throwsA(isA<TamperedDataException>()),
    );
    expect(File('${dir.path}/t_aa11').existsSync(), isFalse);
    expect(await store.thumbnail('aa11'), pixels);
  });

  test('missing thumbnails are null; originals decrypt', () async {
    final store = PhotoStore(bucket.client(), vault);
    expect(await store.thumbnail('cc33'), isNull);
    expect(await store.original('aa11'), [1, 2, 3]);
    await store.evict('aa11');
    expect(store.cachedThumbnail('aa11'), isNull);
  });
}
