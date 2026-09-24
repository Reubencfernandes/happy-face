import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:happy_drive/app/credentials.dart';
import 'package:happy_drive/app/session.dart';
import 'package:happy_drive/crypto/vault.dart';
import 'package:happy_drive/data/bucket_layout.dart';
import 'package:happy_drive/data/catalogue.dart';
import 'package:happy_drive/data/local_db.dart';
import 'package:happy_drive/data/remote_catalogue.dart';
import 'package:happy_drive/media/gallery.dart';
import 'package:happy_drive/sync/photo_store.dart';
import 'package:happy_drive/ui/photo_viewer.dart';
import 'package:happy_drive/ui/theme.dart';
import 'package:photo_manager/photo_manager.dart';

import '../support/fake_bucket.dart';

class NoGallery extends Gallery {
  const NoGallery();
  @override
  Future<PermissionState> currentAccess() async => PermissionState.denied;
}

/// A phone that still has the file, with bytes of its own.
class HasOriginal extends Gallery {
  final Uint8List bytes;
  const HasOriginal(this.bytes);
  @override
  Future<PermissionState> currentAccess() async => PermissionState.authorized;
  @override
  Future<Uint8List?> original(String assetId) async => bytes;
  @override
  Future<Uint8List?> thumbnail(String assetId, {int size = 400}) async => null;
}

TimelineItem cloudItem(String id, String mime) => TimelineItem(
  photoId: id,
  assetId: null,
  takenAt: DateTime.utc(2026, 3, 2, 14),
  tzOffsetMinutes: 0,
  state: BackupState.cloudOnly,
  mime: mime,
);

void main() {
  late FakeBucket bucket;
  late Vault vault;
  late Session session;

  Future<void> store(
    String id,
    String name,
    String mime,
    Uint8List body,
  ) async {
    final key = BucketLayout.original(id);
    bucket.objects[key] = await vault.seal(body, context: key);
    final other = RemoteCatalogue(bucket.client(), vault);
    await other.load();
    await other.commit([
      PutOp(
        PhotoRecord(
          id: id,
          name: name,
          mime: mime,
          size: body.length,
          takenAt: DateTime.utc(2026, 3, 2, 14),
          uploadedAt: DateTime.utc(2026, 3, 2),
        ),
        1,
      ),
    ]);
  }

  Future<void> pumpViewer(WidgetTester tester, TimelineItem item) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: PhotoViewer(session: session, items: [item], initialIndex: 0),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  setUp(() async {
    bucket = FakeBucket();
    vault = await Vault.fromMasterKey(List.filled(32, 8));
    final client = bucket.client();
    session = Session(
      account: const StoredAccount(
        namespace: 'reuben',
        bucket: 'happy-drive',
        accessKeyId: 'HFAKTEST',
        secretAccessKey: 'x',
      ),
      bucket: client,
      vault: vault,
      db: LocalDb.inMemory(),
      photos: PhotoStore(client, vault),
      credentials: const CredentialStore(),
      gallery: const NoGallery(),
    );
  });
  tearDown(() => session.dispose());

  testWidgets('a video offers to play rather than to be downloaded', (
    tester,
  ) async {
    await tester.runAsync(
      () => store('cc01', 'holiday.mp4', 'video/mp4', Uint8List(64)),
    );
    await tester.runAsync(session.sync);
    await pumpViewer(tester, cloudItem('cc01', 'video/mp4'));

    expect(find.byIcon(Icons.play_arrow_rounded), findsOne);
    expect(find.textContaining('Save it to your phone'), findsNothing);
    // The download is still there for keeping a copy.
    expect(find.text('Save to phone'), findsOne);
  });

  testWidgets('sound gets the player too', (tester) async {
    await tester.runAsync(
      () => store('cc02', 'voice.m4a', 'audio/mp4', Uint8List(64)),
    );
    await tester.runAsync(session.sync);
    await pumpViewer(tester, cloudItem('cc02', 'audio/mp4'));

    expect(find.byIcon(Icons.play_arrow_rounded), findsOne);
  });

  testWidgets('a short text file is shown, not described', (tester) async {
    final body = Uint8List.fromList(utf8.encode('dear diary\nit rained'));
    await tester.runAsync(() => store('cc03', 'note.txt', 'text/plain', body));
    await tester.runAsync(session.sync);
    await pumpViewer(tester, cloudItem('cc03', 'text/plain'));

    expect(find.textContaining('dear diary'), findsOne);
  });

  testWidgets('a text file on the phone is read from the phone', (
    tester,
  ) async {
    final onPhone = Uint8List.fromList(utf8.encode('the phone\'s own copy'));
    final inCloud = Uint8List.fromList(utf8.encode('the bucket\'s copy'));
    await tester.runAsync(
      () => store('cc05', 'note.txt', 'text/plain', inCloud),
    );
    await tester.runAsync(session.sync);
    // The same file, also sitting on the phone.
    session = Session(
      account: session.account,
      bucket: bucket.client(),
      vault: vault,
      db: session.db,
      photos: session.photos,
      credentials: const CredentialStore(),
      gallery: HasOriginal(onPhone),
    );
    final before = bucket.count('GET');

    await pumpViewer(
      tester,
      TimelineItem(
        photoId: 'cc05',
        assetId: 'asset-note',
        takenAt: DateTime.utc(2026, 3, 2, 14),
        tzOffsetMinutes: 0,
        state: BackupState.backedUp,
        mime: 'text/plain',
      ),
    );

    expect(find.textContaining("the phone's own copy"), findsOne);
    expect(find.textContaining("the bucket's copy"), findsNothing);
    expect(
      bucket.count('GET'),
      before,
      reason: 'the phone already had it; nothing was downloaded',
    );
  });

  testWidgets('the viewer says which copy is on screen', (tester) async {
    final bytes = Uint8List.fromList([0xFF, 0xD8, 0xFF, 1, 2, 3]);
    await tester.runAsync(
      () => store('cc06', 'beach.jpg', 'image/jpeg', bytes),
    );
    await tester.runAsync(session.sync);
    session = Session(
      account: session.account,
      bucket: bucket.client(),
      vault: vault,
      db: session.db,
      photos: session.photos,
      credentials: const CredentialStore(),
      gallery: HasOriginal(bytes),
    );

    await pumpViewer(
      tester,
      TimelineItem(
        photoId: 'cc06',
        assetId: 'asset-beach',
        takenAt: DateTime.utc(2026, 3, 2, 14),
        tzOffsetMinutes: 0,
        state: BackupState.backedUp,
        mime: 'image/jpeg',
      ),
    );
    expect(find.text('Original, from this phone'), findsOne);
  });

  testWidgets('a compressed backup is named as one', (tester) async {
    await tester.runAsync(() async {
      final body = Uint8List.fromList([0xFF, 0xD8, 0xFF, 4, 5, 6]);
      final key = BucketLayout.original('cc07');
      bucket.objects[key] = await vault.seal(body, context: key);
      final other = RemoteCatalogue(bucket.client(), vault);
      await other.load();
      await other.commit([
        PutOp(
          PhotoRecord(
            id: 'cc07',
            name: 'sunset.jpg',
            mime: 'image/jpeg',
            size: body.length,
            takenAt: DateTime.utc(2026, 3, 2, 14),
            uploadedAt: DateTime.utc(2026, 3, 2),
            compression: 'balanced',
          ),
          1,
        ),
      ]);
    });
    await tester.runAsync(session.sync);
    await pumpViewer(tester, cloudItem('cc07', 'image/jpeg'));

    expect(find.text('From your storage · Balanced copy'), findsOne);
  });

  testWidgets('a file nothing can open says so, and offers the download', (
    tester,
  ) async {
    await tester.runAsync(
      () => store('cc04', 'taxes.zip', 'application/zip', Uint8List(64)),
    );
    await tester.runAsync(session.sync);
    await pumpViewer(tester, cloudItem('cc04', 'application/zip'));

    expect(find.text('taxes.zip'), findsOne);
    expect(find.textContaining('can\'t open this kind of file'), findsOne);
    expect(find.text('Save to this phone'), findsOne);
  });
}
