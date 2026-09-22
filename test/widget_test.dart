import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:happy_drive/app/credentials.dart';
import 'package:happy_drive/app/session.dart';
import 'package:happy_drive/crypto/vault.dart';
import 'package:happy_drive/data/catalogue.dart';
import 'package:happy_drive/data/local_db.dart';
import 'package:happy_drive/data/remote_catalogue.dart';
import 'package:happy_drive/main.dart';
import 'package:happy_drive/media/gallery.dart';
import 'package:happy_drive/sync/photo_store.dart';
import 'package:happy_drive/ui/home_screen.dart';
import 'package:photo_manager/photo_manager.dart';

import 'support/fake_bucket.dart';

/// A phone that hasn't granted photo access.
class NoGallery extends Gallery {
  const NoGallery();
  @override
  Future<PermissionState> currentAccess() async => PermissionState.denied;
  @override
  Future<PermissionState> requestAccess() async => PermissionState.denied;
}

const fastKdf = KdfParams(memoryKiB: 256, iterations: 1, parallelism: 1);

void usePhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Pumps frames while letting real async work (isolates, file IO) run.
Future<void> pumpUntil(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 400; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump(const Duration(milliseconds: 16));
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('Timed out waiting for $finder');
}

Future<void> fill(WidgetTester tester, String label, String text) =>
    tester.enterText(find.widgetWithText(TextFormField, label), text);

/// The welcome screen greets a new phone; the key fields live one tap in.
Future<void> openConnectForm(WidgetTester tester) async {
  await pumpUntil(tester, find.text('Get started'));
  await tester.tap(find.text('Get started'));
  await pumpUntil(tester, find.text('Connect'));
}

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  // Lists build lazily: scroll until the target exists and is on screen.
  await tester.scrollUntilVisible(
    finder,
    120,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('connect screen fits a phone, hides the secret and validates', (
    tester,
  ) async {
    usePhone(tester);
    await tester.pumpWidget(const HappyDriveApp(gallery: NoGallery()));
    await openConnectForm(tester);

    final secret = tester.widget<TextField>(
      find.descendant(
        of: find.widgetWithText(TextFormField, 'Secret'),
        matching: find.byType(TextField),
      ),
    );
    expect(secret.obscureText, isTrue);

    await tester.tap(find.text('Connect'));
    await tester.pump();
    expect(find.text('Enter your username, e.g. reuben'), findsOneWidget);
    expect(
      find.text('Paste the access key (starts with HFAK)'),
      findsOneWidget,
    );

    await tester.tap(find.text('Where do I get these?'));
    await tester.pumpAndSettle();
    expect(find.text('Open Access Tokens'), findsOneWidget);
    expect(find.text('Generate S3 credentials'), findsOneWidget);
    expect(find.text('Copy both values'), findsOneWidget);
    // The three huggingface.co screenshots showing where to click.
    expect(find.byType(Image), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the welcome screen leads to the details page', (tester) async {
    usePhone(tester);
    await tester.pumpWidget(const HappyDriveApp(gallery: NoGallery()));
    await pumpUntil(tester, find.text('Get started'));
    expect(find.text('Welcome to Happy Drive'), findsOneWidget);
    // Nothing is asked for until the user has agreed to start.
    expect(find.byType(TextFormField), findsNothing);

    await tester.tap(find.text('Get started'));
    await pumpUntil(tester, find.text('Connect'));
    expect(find.text('Let\'s get\nStarted'), findsOneWidget);
    // The bucket is asked about up front, starting on a new one.
    expect(find.text('Where the photos go'), findsOneWidget);
    expect(find.text('New bucket'), findsOneWidget);
    expect(
      find.text('A new private bucket, made in your account'),
      findsOneWidget,
    );
    // A new library is named for the user rather than sharing one name, and
    // that name is on screen in the field, ready to be changed.
    expect(find.text('happy-drive'), findsNothing);
    expect(
      tester
          .widgetList<EditableText>(find.byType(EditableText))
          .map((e) => e.controller.text),
      contains(matches(RegExp(r'^[a-z]+-[a-z]+-\d{3}$'))),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a public bucket is refused until it is made private', (
    tester,
  ) async {
    usePhone(tester);
    final bucket = FakeBucket(public: true);
    await tester.pumpWidget(
      HappyDriveApp(gallery: const NoGallery(), clientFactory: bucket.client),
    );
    await openConnectForm(tester);
    await fill(tester, 'Hugging Face username', 'reuben');
    await fill(tester, 'Access key', 'HFAKTEST1234');
    await fill(tester, 'Secret', 'supersecretvalue');
    await tester.tap(find.text('Connect'));
    await pumpUntil(tester, find.textContaining('is public'));
    expect(find.text('Create your passphrase'), findsNothing);
  });

  testWidgets('first run: connect, create a passphrase, land on the timeline', (
    tester,
  ) async {
    usePhone(tester);
    final bucket = FakeBucket();
    final dir = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('happy_drive_test'),
    ))!;
    addTearDown(() => tester.runAsync(() => dir.delete(recursive: true)));

    await tester.pumpWidget(
      HappyDriveApp(
        gallery: const NoGallery(),
        clientFactory: bucket.client,
        dataDir: () async => dir,
        kdfParams: fastKdf,
      ),
    );
    await openConnectForm(tester);
    await fill(tester, 'Hugging Face username', 'reuben');
    await fill(tester, 'Access key', 'HFAKTEST1234');
    await fill(tester, 'Secret', 'supersecretvalue');
    await tester.tap(find.text('Connect'));
    await pumpUntil(tester, find.text('Create\nYour passphrase'));
    // The connect page is a route now: let it finish sliding away.
    await tester.pumpAndSettle();

    await fill(tester, 'Passphrase', 'mango kite river 42');
    await fill(tester, 'Type it again', 'mango kite river 41');
    await tapVisible(tester, find.text('Create library'));
    expect(find.text('The passphrases don\'t match'), findsOneWidget);

    await fill(tester, 'Type it again', 'mango kite river 42');
    await tapVisible(tester, find.text('Create library'));
    expect(find.textContaining('confirm you understand'), findsOneWidget);

    await tapVisible(tester, find.byType(Checkbox));
    await tapVisible(tester, find.text('Create library'));
    await pumpUntil(tester, find.text('Your memories start here'));

    expect(bucket.objects.keys, contains('v1/keys'));
    expect(
      String.fromCharCodes(bucket.objects['v1/keys']!),
      isNot(contains('mango')),
    );
    expect(find.text('Allow photo access'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('timeline groups cloud photos by day, newest first', (
    tester,
  ) async {
    usePhone(tester);
    final bucket = FakeBucket();
    final vault = (await tester.runAsync(
      () => Vault.fromMasterKey(List.filled(32, 5)),
    ))!;
    // Another device already backed up three photos.
    await tester.runAsync(() async {
      final other = RemoteCatalogue(bucket.client(), vault);
      PhotoRecord rec(String id, DateTime taken) => PhotoRecord(
        id: id,
        name: '$id.jpg',
        mime: 'image/jpeg',
        size: 1000,
        takenAt: taken,
        uploadedAt: DateTime.utc(2026, 9, 1),
      );
      await other.commit([
        PutOp(rec('aa01', DateTime.utc(2024, 1, 1, 12)), 1),
        PutOp(rec('aa02', DateTime.utc(2024, 1, 1, 9)), 2),
        PutOp(rec('aa03', DateTime.utc(2023, 7, 4, 18)), 3),
      ]);
    });

    final client = bucket.client();
    final session = Session(
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
    addTearDown(session.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(session: session, onSignOut: () {}),
      ),
    );
    await pumpUntil(tester, find.text('Mon, 1 Jan 2024'));

    final newer = tester.getTopLeft(find.text('Mon, 1 Jan 2024'));
    final older = tester.getTopLeft(find.text('Tue, 4 Jul 2023'));
    expect(newer.dy, lessThan(older.dy));
    expect(find.textContaining('3 photos in storage'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
