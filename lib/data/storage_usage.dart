import '../app/credentials.dart';
import '../s3/s3_client.dart';
import 'bucket_layout.dart';
import 'remote_catalogue.dart';

/// What a stored object is for, so the storage bar can say where the space
/// went rather than just how much is gone.
enum UsageKind {
  photos('Photos'),
  thumbnails('Thumbnails'),
  catalogue('Index'),
  other('Other files');

  final String label;
  const UsageKind(this.label);

  static UsageKind of(String key) {
    if (key.startsWith(BucketLayout.originalPrefix)) return photos;
    if (key.startsWith(BucketLayout.thumbnailPrefix)) return thumbnails;
    if (key == BucketLayout.keys ||
        key.startsWith(RemoteCatalogue.journalPrefix) ||
        key.startsWith(RemoteCatalogue.indexPrefix)) {
      return catalogue;
    }
    return other;
  }
}

/// How much one bucket is holding.
class BucketUsage {
  final String name;

  /// True for the bucket this phone backs up to.
  final bool connected;
  final Map<UsageKind, int> bytes;
  final int objects;

  /// The listing stopped at the object cap, so this is a floor.
  final bool partial;

  /// Why the size is unknown, for buckets these keys can't read.
  final String? error;

  const BucketUsage({
    required this.name,
    required this.connected,
    this.bytes = const {},
    this.objects = 0,
    this.partial = false,
    this.error,
  });

  int get total => bytes.values.fold(0, (sum, b) => sum + b);

  /// Kinds present here, largest first.
  List<MapEntry<UsageKind, int>> get breakdown =>
      bytes.entries.where((e) => e.value > 0).toList()
        ..sort((a, b) => b.value.compareTo(a.value));
}

/// Every bucket this account's keys could be measured against.
class StorageUsage {
  /// The connected bucket first, then the rest largest first.
  final List<BucketUsage> buckets;

  /// True when the gateway wouldn't list the namespace, so only the
  /// connected bucket is accounted for.
  final bool onlyConnected;

  const StorageUsage(this.buckets, {this.onlyConnected = false});

  int get total => buckets.fold(0, (sum, b) => sum + b.total);
  BucketUsage? get connected => buckets.where((b) => b.connected).firstOrNull;
}

/// Adds up what each bucket in the namespace holds, by listing objects.
///
/// The connected bucket is always measured. Others are measured too when the
/// S3 gateway lists them; buckets these keys can't read are reported with an
/// error rather than dropped, so the total is never quietly wrong.
Future<StorageUsage> measureStorage({
  required StoredAccount account,
  required BucketClient connected,
  BucketClientFactory clientFactory = defaultBucketClient,
  int maxObjectsPerBucket = 20000,
}) async {
  final names = await connected.listBuckets();
  final usage = [
    await _measure(
      connected,
      account.bucket,
      connected: true,
      cap: maxObjectsPerBucket,
    ),
  ];
  for (final name in names ?? const <String>[]) {
    if (name == account.bucket) continue;
    final client = clientFactory(
      StoredAccount(
        namespace: account.namespace,
        bucket: name,
        accessKeyId: account.accessKeyId,
        secretAccessKey: account.secretAccessKey,
      ),
    );
    try {
      usage.add(
        await _measure(
          client,
          name,
          connected: false,
          cap: maxObjectsPerBucket,
        ),
      );
    } finally {
      client.close();
    }
  }
  // The connected bucket stays first; the rest are ordered by size.
  final others = usage.skip(1).toList()
    ..sort((a, b) => b.total.compareTo(a.total));
  return StorageUsage([usage.first, ...others], onlyConnected: names == null);
}

Future<BucketUsage> _measure(
  BucketClient client,
  String name, {
  required bool connected,
  required int cap,
}) async {
  try {
    final objects = await client.listObjects(limit: cap);
    final bytes = <UsageKind, int>{};
    for (final o in objects) {
      bytes.update(
        UsageKind.of(o.key),
        (b) => b + o.size,
        ifAbsent: () => o.size,
      );
    }
    return BucketUsage(
      name: name,
      connected: connected,
      bytes: bytes,
      objects: objects.length,
      partial: objects.length >= cap,
    );
  } on S3Exception catch (e) {
    return BucketUsage(name: name, connected: connected, error: e.friendly);
  }
}
