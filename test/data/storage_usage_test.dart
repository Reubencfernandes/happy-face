import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:happy_drive/app/credentials.dart';
import 'package:happy_drive/data/storage_usage.dart';

import '../support/fake_bucket.dart';

const account = StoredAccount(
  namespace: 'reuben',
  bucket: 'happy-drive',
  accessKeyId: 'HFAKTEST',
  secretAccessKey: 'x',
);

void main() {
  test('adds up a bucket by what each object is for', () async {
    final bucket = FakeBucket();
    bucket.objects
      ..['v1/o/aa/aa1'] = Uint8List(4000)
      ..['v1/o/bb/bb1'] = Uint8List(6000)
      ..['v1/t/aa/aa1'] = Uint8List(500)
      ..['v1/keys'] = Uint8List(200)
      ..['v1/j/0001'] = Uint8List(100)
      ..['README.md'] = Uint8List(50);

    final client = bucket.client();
    final usage = await measureStorage(account: account, connected: client);
    client.close();

    expect(usage.buckets, hasLength(1));
    // The gateway doesn't list buckets, so it says so rather than implying
    // this is everything the account has.
    expect(usage.onlyConnected, isTrue);
    expect(usage.total, 10850);

    final only = usage.buckets.single;
    expect(only.connected, isTrue);
    expect(only.objects, 6);
    expect(only.partial, isFalse);
    expect(only.bytes[UsageKind.photos], 10000);
    expect(only.bytes[UsageKind.thumbnails], 500);
    expect(only.bytes[UsageKind.catalogue], 300);
    expect(only.bytes[UsageKind.other], 50);
    // Biggest first, so the bar and the legend agree.
    expect(only.breakdown.first.key, UsageKind.photos);
  });

  test('a huge bucket is measured up to the cap and says it stopped', () async {
    final bucket = FakeBucket(pageSize: 10);
    for (var i = 0; i < 40; i++) {
      bucket.objects['v1/o/aa/p$i'] = Uint8List(10);
    }
    final client = bucket.client();
    final usage = await measureStorage(
      account: account,
      connected: client,
      maxObjectsPerBucket: 20,
    );
    client.close();

    final only = usage.buckets.single;
    expect(only.partial, isTrue);
    expect(only.objects, 20);
    expect(only.total, 200);
  });

  test('an empty bucket measures zero rather than failing', () async {
    final bucket = FakeBucket();
    final client = bucket.client();
    final usage = await measureStorage(account: account, connected: client);
    client.close();

    expect(usage.total, 0);
    expect(usage.buckets.single.objects, 0);
    expect(usage.buckets.single.breakdown, isEmpty);
  });
}
