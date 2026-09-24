import '../s3/s3_client.dart';

/// Deletes everything in the bucket [client] points at, then the bucket.
///
/// S3 won't delete a bucket that still holds objects, and Hugging Face
/// doesn't say whether its gateway empties one for you, so the objects go
/// first, a few at a time. Something written meanwhile makes the gateway
/// answer BucketNotEmpty; the bucket is then listed and emptied once more.
///
/// [onProgress] hears how many objects are gone out of how many were found.
Future<void> eraseBucket(
  BucketClient client, {
  void Function(int done, int total)? onProgress,
  int parallel = 4,
}) async {
  for (var attempt = 0; ; attempt++) {
    final keys = [for (final o in await client.listObjects()) o.key];
    var done = 0;
    onProgress?.call(done, keys.length);
    var next = 0;
    Future<void> worker() async {
      while (next < keys.length) {
        await client.deleteObject(keys[next++]);
        onProgress?.call(++done, keys.length);
      }
    }

    await Future.wait([for (var i = 0; i < parallel; i++) worker()]);
    try {
      await client.deleteBucket();
      return;
    } on S3Exception catch (e) {
      if (!e.isBucketNotEmpty || attempt >= 1) rethrow;
    }
  }
}
