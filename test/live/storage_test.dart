// These checks print a report for a person to read.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:happy_drive/crypto/vault.dart';
import 'package:happy_drive/data/bucket_layout.dart';
import 'package:happy_drive/data/local_db.dart';
import 'package:happy_drive/data/remote_catalogue.dart';
import 'package:happy_drive/media/compress.dart';
import 'package:happy_drive/s3/s3_client.dart';
import 'package:happy_drive/s3/sigv4.dart';
import 'package:happy_drive/sync/photo_store.dart';
import 'package:happy_drive/sync/uploader.dart';

/// Drives the whole storage stack against a real S3 server.
class NoCodec implements ImageCodec {
  @override
  Future<Uint8List?> compress(Uint8List b, Compression l) async => null;
  @override
  Future<Uint8List?> thumbnail(Uint8List b, {int size = 400}) async =>
      Uint8List.fromList(b.sublist(0, b.length ~/ 4));
}

/// Live end-to-end check against real storage. Skipped unless configured.
///
/// Set `HF_NAMESPACE` (your Hugging Face username), `HFAK_KEY` and
/// `HFAK_SECRET`, then run `flutter test test/live/storage_test.dart`.
///
/// It creates a throwaway bucket, uses it, and leaves it behind for you to
/// inspect. S3_ENDPOINT and TEST_IMAGE can point it at a local server instead.
void main() {
  final env = Platform.environment;
  final namespace = env['HF_NAMESPACE'];
  final key = env['HFAK_KEY'];
  final secret = env['HFAK_SECRET'];
  if (namespace == null || key == null || secret == null) {
    test(
      'live storage check',
      () {},
      skip: 'set HF_NAMESPACE, HFAK_KEY and HFAK_SECRET to run',
    );
    return;
  }
  final endpoint = Uri.parse(env['S3_ENDPOINT'] ?? 'https://s3.hf.co');
  final photo = env['TEST_IMAGE'] != null
      ? File(env['TEST_IMAGE']!).readAsBytesSync()
      : Uint8List.fromList([
          0xFF,
          0xD8,
          0xFF,
          0xE0,
          ...List.generate(4096, (i) => i % 251),
          0xFF,
          0xD9,
        ]);
  final bucketName =
      'happy-drive-test-${DateTime.now().millisecondsSinceEpoch}';

  BucketClient client() => BucketClient(
    namespace: namespace,
    bucket: bucketName,
    credentials: S3Credentials(key, secret),
    endpoint: endpoint,
  );

  test(
    'end to end: connect, back up, read back, dedupe, delete',
    () async {
      final bucket = client();

      // 1. Connect: the bucket doesn't exist, so create it.
      expect(await bucket.bucketExists(), isFalse);
      await bucket.createBucket();
      expect(await bucket.bucketExists(), isTrue);
      print('1. bucket $bucketName created and found');
      print('   publicly listable: ${await bucket.isPubliclyListable()}');

      // 2. Set up the library key, and prove it can't be created twice.
      final (vault, envelope) = await Vault.create('mango kite river 42');
      await bucket.putObject(BucketLayout.keys, envelope, ifNoneMatch: '*');
      var refusedSecondWrite = false;
      try {
        await bucket.putObject(BucketLayout.keys, envelope, ifNoneMatch: '*');
      } on S3Exception catch (e) {
        refusedSecondWrite = e.isPreconditionFailed;
      }
      print('2. key stored; second write refused: $refusedSecondWrite');

      // 3. Unlock from "another phone" using only the passphrase.
      final reopened = await Vault.unlock(
        await bucket.getObject(BucketLayout.keys),
        'mango kite river 42',
      );
      expect(await reopened.exportMasterKey(), await vault.exportMasterKey());
      print('3. unlocked on a second device with the passphrase');

      // 4. Back up three photos, one a duplicate.
      final db = LocalDb.inMemory();
      final catalogue = RemoteCatalogue(bucket, vault);
      await catalogue.load();
      final uploader = Uploader(
        bucket: bucket,
        vault: vault,
        catalogue: catalogue,
        db: db,
        codec: NoCodec(),
        batchSize: 2,
      );
      final second = Uint8List.fromList([...photo, 0]);
      final results = await uploader.run([
        UploadSource(name: 'beach.jpg', read: () async => photo),
        UploadSource(name: 'beach-copy.jpg', read: () async => photo),
        UploadSource(name: 'beach2.jpg', read: () async => second),
      ]);
      print('4. outcomes: ${results.map((r) => r.outcome.name).toList()}');
      expect(
        results.where((r) => r.outcome == UploadOutcome.uploaded),
        hasLength(2),
      );
      expect(
        results.where((r) => r.outcome == UploadOutcome.duplicate),
        hasLength(1),
      );

      // 5. Nothing readable is in the bucket.
      final id = results.first.photoId!;
      final stored = await bucket.getObject(BucketLayout.original(id));
      expect(stored, isNot(photo));
      expect(latin1.decode(stored), isNot(contains('JFIF')));
      final all = await bucket.listObjects();
      print(
        '5. ${all.length} objects; names: ${all.take(3).map((o) => o.key).toList()}',
      );
      expect(all.every((o) => !o.key.contains('beach')), isTrue);

      // 6. Read a photo back and check it is byte-for-byte the original.
      final store = PhotoStore(bucket, vault);
      expect(await store.original(id), photo);
      expect(await store.thumbnail(id), photo.sublist(0, photo.length ~/ 4));
      print('6. original downloaded and decrypted byte-for-byte');

      // 7. A fresh device sees the same library.
      final fresh = RemoteCatalogue(client(), reopened);
      await fresh.load();
      expect(fresh.state.records, hasLength(2));
      db.replaceAll(fresh.state);
      expect(db.timeline(), hasLength(2));
      print('7. another device loaded ${fresh.state.records.length} photos');

      // 8. Compaction folds the journal into a snapshot.
      await fresh.compactIfNeeded(threshold: 1);
      final afterCompact = await bucket.listObjects(
        prefix: RemoteCatalogue.indexPrefix,
      );
      final journalLeft = await bucket.listObjects(
        prefix: RemoteCatalogue.journalPrefix,
      );
      print(
        '8. snapshots: ${afterCompact.map((o) => o.key).toList()}, journal left: ${journalLeft.length}',
      );

      // 9. Delete frees the space.
      await bucket.deleteObject(BucketLayout.original(id));
      await bucket.deleteObject(BucketLayout.thumbnail(id));
      final remaining = await bucket.listObjects(prefix: 'v1/o/');
      print('9. originals left after delete: ${remaining.length}');
      expect(remaining, hasLength(1));

      print(
        'Done. Delete the test bucket at '
        'https://huggingface.co/buckets/$namespace/$bucketName when finished.',
      );
      db.close();
      bucket.close();
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
