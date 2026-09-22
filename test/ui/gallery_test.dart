import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:happy_drive/app/credentials.dart';
import 'package:happy_drive/app/session.dart';
import 'package:happy_drive/crypto/vault.dart';
import 'package:happy_drive/data/catalogue.dart';
import 'package:happy_drive/data/local_db.dart';
import 'package:happy_drive/data/remote_catalogue.dart';
import 'package:happy_drive/media/gallery.dart';
import 'package:happy_drive/sync/photo_store.dart';
import 'package:happy_drive/ui/home_screen.dart';
import 'package:happy_drive/ui/photo_thumb.dart';
import 'package:photo_manager/photo_manager.dart';

import '../support/fake_bucket.dart';

/// A phone that hasn't granted photo access.
class NoGallery extends Gallery {
  const NoGallery();
  @override
  Future<PermissionState> currentAccess() async => PermissionState.denied;
  @override
  Future<PermissionState> requestAccess() async => PermissionState.denied;
}

Future<void> pumpUntil(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 300; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 16));
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('Timed out waiting for $finder');
}

void main() {
  testWidgets('the gallery has a floating nav, a calendar and tap-to-select', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bucket = FakeBucket();
    final vault = (await tester.runAsync(
      () => Vault.fromMasterKey(List.filled(32, 5)),
    ))!;
    // Two photos on one day, one on another, from another device.
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
        PutOp(rec('aa01', DateTime.utc(2024, 1, 15, 12)), 1),
        PutOp(rec('aa02', DateTime.utc(2024, 1, 15, 9)), 2),
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
    await pumpUntil(tester, find.text('Mon, 15 Jan 2024'));

    // The chrome: a big title, a backup arrow, and the floating bar.
    expect(find.text('Gallery'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget);
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
    expect(find.byIcon(Icons.home_rounded), findsOneWidget);
    expect(find.byIcon(Icons.calendar_today_outlined), findsOneWidget);

    // "Select photos" starts selection without anyone long-pressing.
    await tester.tap(find.byIcon(Icons.filter_list_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select photos'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Choose photos'), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_unchecked), findsWidgets);

    // A tap now picks a photo rather than opening it.
    await tester.tap(find.byType(PhotoThumb).first);
    await tester.pump();
    expect(find.text('1 selected'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump();
    expect(find.text('Gallery'), findsOneWidget);

    // One lit slot that travels between tabs, not four that blink.
    expect(find.byType(AnimatedPositionedDirectional), findsOneWidget);
    double pill() => tester
        .widget<AnimatedPositionedDirectional>(
          find.byType(AnimatedPositionedDirectional),
        )
        .start!;
    expect(pill(), 0, reason: 'starts over the gallery tab');

    // The calendar tab lays the months out as squares.
    await tester.tap(find.byIcon(Icons.calendar_today_outlined));
    await pumpUntil(tester, find.text('January 2024'));
    expect(pill(), greaterThan(0), reason: 'slid to the calendar tab');
    expect(find.text('Calendar'), findsOneWidget);
    expect(find.text('July 2023'), findsOneWidget);
    // Every day of both months is a square, photo or no photo.
    expect(find.text('15'), findsNWidgets(2));
    expect(find.text('31'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}
