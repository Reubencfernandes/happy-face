import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:happy_drive/app/credentials.dart';
import 'package:happy_drive/app/session.dart';
import 'package:happy_drive/crypto/vault.dart';
import 'package:happy_drive/data/local_db.dart';
import 'package:happy_drive/sync/photo_store.dart';
import 'package:happy_drive/ui/delete_sheet.dart';
import 'package:happy_drive/ui/theme.dart';

import '../app/session_test.dart' show FakeGallery;
import '../support/fake_bucket.dart';
import '../sync/uploader_test.dart' show FakeCodec;

/// A phone whose owner says no to deleting some of its photos.
class DeletingGallery extends FakeGallery {
  final Set<String> refused;
  final deleted = <String>[];
  DeletingGallery(super.count, {this.refused = const {}});

  @override
  Future<Set<String>> deleteFromPhone(List<String> assetIds) async {
    final gone = assetIds.where((id) => !refused.contains(id)).toSet();
    deleted.addAll(gone);
    return gone;
  }
}

TimelineItem item({String? photoId, String? assetId}) => TimelineItem(
  photoId: photoId,
  assetId: assetId,
  takenAt: DateTime.utc(2026, 9, 1),
  tzOffsetMinutes: 0,
  state: photoId == null
      ? BackupState.localOnly
      : assetId == null
      ? BackupState.cloudOnly
      : BackupState.backedUp,
);

void main() {
  late FakeBucket bucket;
  late DeletingGallery gallery;
  late Session session;
  late List<TimelineItem> items;

  Future<void> setUpSession({Set<String> refused = const {}}) async {
    bucket = FakeBucket();
    gallery = DeletingGallery(3, refused: refused);
    final vault = await Vault.fromMasterKey(List.filled(32, 4));
    final client = bucket.client();
    session = Session(
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
    await session.scanGallery();
    final results = await session.backUpAssets([gallery.id(0), gallery.id(1)]);
    items = [
      for (final r in results)
        item(photoId: r.photoId, assetId: r.source.assetId),
      item(assetId: gallery.id(2)),
    ];
  }

  test('from Happy Drive only: the phone keeps its copies', () async {
    await setUpSession();
    final outcome = await deleteItems(session, items, DeleteFrom.drive);
    expect(outcome.fromDrive, hasLength(2));
    expect(outcome.fromPhone, isEmpty);
    expect(gallery.deleted, isEmpty);
    expect(session.db.photo(items[0].photoId!), isNull);
    expect(outcome.apply(items[0])!.state, BackupState.localOnly);
  });

  test('from the phone only: the backups stay', () async {
    await setUpSession();
    final outcome = await deleteItems(session, items, DeleteFrom.phone);
    expect(gallery.deleted, [gallery.id(0), gallery.id(1), gallery.id(2)]);
    expect(outcome.fromDrive, isEmpty);
    expect(session.db.photo(items[0].photoId!), isNotNull);
    expect(outcome.apply(items[0])!.state, BackupState.cloudOnly);
    expect(outcome.apply(items[2]), isNull, reason: 'it was only here');
  });

  test('everywhere: a photo the phone kept keeps its backup too', () async {
    await setUpSession(refused: {'asset1'});
    final outcome = await deleteItems(session, items, DeleteFrom.both);
    expect(outcome.fromPhone, {gallery.id(0), gallery.id(2)});
    expect(outcome.fromDrive, {items[0].photoId});
    expect(session.db.photo(items[1].photoId!), isNotNull);
    expect(outcome.apply(items[0]), isNull);
    expect(outcome.apply(items[1])!.state, BackupState.backedUp);
  });

  testWidgets('only the places an item is in are offered', (tester) async {
    DeleteFrom? picked;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                picked = await askWhereToDelete(context, [item(assetId: 'a')]),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    ListTile tile(String title) =>
        tester.widget<ListTile>(find.widgetWithText(ListTile, title));
    expect(tile('Delete from Happy Drive').enabled, isFalse);
    expect(tile('Delete everywhere').enabled, isFalse);
    expect(tile('Delete from this phone').enabled, isTrue);
    expect(
      find.textContaining('only on this phone, so it will be gone'),
      findsOneWidget,
    );
    await tester.tap(find.text('Delete from this phone'));
    await tester.pumpAndSettle();
    expect(picked, DeleteFrom.phone);
  });
}
