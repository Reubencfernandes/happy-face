import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:happy_drive/app/credentials.dart';
import 'package:happy_drive/app/session.dart';
import 'package:happy_drive/crypto/vault.dart';
import 'package:happy_drive/data/hf_profile.dart';
import 'package:happy_drive/data/local_db.dart';
import 'package:happy_drive/media/gallery.dart';
import 'package:happy_drive/sync/photo_store.dart';
import 'package:happy_drive/ui/settings_screen.dart';
import 'package:happy_drive/ui/usage_bar.dart';
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

/// The session the settings screen is given, with [objects] in its bucket.
Session sessionWith(
  WidgetTester tester,
  FakeBucket bucket,
  Vault vault, {
  HfProfile? cached,
}) {
  final client = bucket.client();
  final db = LocalDb.inMemory();
  if (cached != null) {
    // What a previous lookup left behind, which the screen trusts on open.
    db.setSetting('hfProfile', jsonEncode(cached.toJson()));
  }
  final session = Session(
    account: const StoredAccount(
      namespace: 'reuben',
      bucket: 'happy-drive',
      accessKeyId: 'HFAKTEST',
      secretAccessKey: 'x',
    ),
    bucket: client,
    vault: vault,
    db: db,
    photos: PhotoStore(client, vault),
    credentials: const CredentialStore(),
    gallery: const NoGallery(),
  );
  addTearDown(session.dispose);
  return session;
}

void main() {
  testWidgets('storage is measured against the account allowance', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bucket = FakeBucket();
    bucket.objects['v1/o/aa/aa1'] = Uint8List(2 * 1024 * 1024 * 1024);
    final vault = (await tester.runAsync(
      () => Vault.fromMasterKey(List.filled(32, 3)),
    ))!;
    final session = sessionWith(
      tester,
      bucket,
      vault,
      cached: const HfProfile(
        username: 'reuben',
        fullName: 'Reuben Fernandes',
        isPro: true,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(session: session, onSignOut: () {}),
      ),
    );
    // The cached profile is there before any network call.
    expect(find.text('Reuben Fernandes'), findsOneWidget);
    expect(find.text('PRO'), findsOneWidget);

    await pumpUntil(tester, find.textContaining('of 1 TB'));
    // 2 GB of a terabyte: the rest is free, and the plan is named.
    expect(find.textContaining('PRO ·'), findsOneWidget);
    expect(find.text('Free'), findsOneWidget);
    expect(find.text('997.85 GB'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings shows who is signed in and what fills the bucket', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bucket = FakeBucket();
    bucket.objects
      ..['v1/o/aa/aa1'] = Uint8List(4 * 1024 * 1024)
      ..['v1/t/aa/aa1'] = Uint8List(64 * 1024)
      ..['v1/keys'] = Uint8List(256);

    final vault = (await tester.runAsync(
      () => Vault.fromMasterKey(List.filled(32, 3)),
    ))!;
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
        home: SettingsScreen(session: session, onSignOut: () {}),
      ),
    );

    // No profile picture in a test, so the avatar falls back to an initial.
    expect(find.text('R'), findsOneWidget);
    expect(find.text('@reuben'), findsOneWidget);

    await pumpUntil(tester, find.textContaining('4.3 MB'));
    expect(find.byType(UsageBar), findsNWidgets(2));
    // The bucket's own row, then what is inside it.
    // Both the Text.rich and the RichText it builds match here.
    expect(find.textContaining('this app', findRichText: true), findsWidgets);
    expect(find.text('Photos'), findsOneWidget);
    expect(find.text('Thumbnails'), findsOneWidget);
    expect(find.text('Index'), findsOneWidget);
    // No profile in a test, so no allowance is claimed and no free-space
    // row is invented.
    expect(find.textContaining('of 100 GB'), findsNothing);
    expect(find.text('Free'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
