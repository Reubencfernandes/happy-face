import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:happy_drive/data/bucket_eraser.dart';
import 'package:happy_drive/s3/s3_client.dart';
import 'package:http/http.dart' as http;

import '../support/fake_bucket.dart';

void main() {
  test('empties the bucket, then deletes it, saying how far it got', () async {
    final bucket = FakeBucket(pageSize: 2);
    for (var i = 0; i < 5; i++) {
      bucket.objects['v1/o/$i'] = Uint8List(3);
    }
    final progress = <(int, int)>[];
    await eraseBucket(
      bucket.client(),
      onProgress: (done, total) => progress.add((done, total)),
    );
    expect(bucket.objects, isEmpty);
    expect(bucket.deleted, isTrue);
    expect(progress.first, (0, 5));
    expect(progress.last, (5, 5));
  });

  test('an empty bucket is simply deleted', () async {
    final bucket = FakeBucket();
    await eraseBucket(bucket.client());
    expect(bucket.deleted, isTrue);
    expect(bucket.count('DELETE'), 1);
  });

  test(
    'a file that lands while emptying is cleared on a second pass',
    () async {
      final bucket = FakeBucket();
      bucket.objects['v1/o/a'] = Uint8List(1);
      var late = true;
      bucket.intercept = (r) {
        // Another device writes just before the bucket is deleted.
        if (r.method == 'DELETE' &&
            r.url.path.endsWith('happy-drive') &&
            late) {
          late = false;
          bucket.objects['v1/o/b'] = Uint8List(1);
        }
        return null;
      };
      await eraseBucket(bucket.client());
      expect(bucket.objects, isEmpty);
      expect(bucket.deleted, isTrue);
    },
  );

  test('a refusal other than "not empty" is passed on', () async {
    final bucket = FakeBucket();
    bucket.intercept = (r) => r.method == 'DELETE'
        ? http.Response('<Error><Code>AccessDenied</Code></Error>', 403)
        : null;
    await expectLater(
      eraseBucket(bucket.client()),
      throwsA(isA<S3Exception>().having((e) => e.isAuth, 'isAuth', true)),
    );
    expect(bucket.deleted, isFalse);
  });
}
