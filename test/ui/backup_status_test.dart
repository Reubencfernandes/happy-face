import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:happy_drive/app/credentials.dart';
import 'package:happy_drive/app/session.dart';
import 'package:happy_drive/crypto/vault.dart';
import 'package:happy_drive/data/local_db.dart';
import 'package:happy_drive/sync/photo_store.dart';
import 'package:happy_drive/sync/uploader.dart';
import 'package:happy_drive/ui/backup_status.dart';
import 'package:happy_drive/ui/theme.dart';

import '../app/session_test.dart' show FakeGallery;
import '../support/fake_bucket.dart';
import '../sync/uploader_test.dart' show FakeCodec;

void main() {
  late Session session;

  setUp(() async {
    final bucket = FakeBucket();
    final vault = await Vault.fromMasterKey(List.filled(32, 6));
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
      gallery: FakeGallery(12),
      codec: FakeCodec(),
    );
  });
  tearDown(() => session.dispose());

  /// A backup caught part-way through, which a real one passes too quickly
  /// for a widget test to photograph.
  void halfway({int failed = 0}) {
    session.upload = UploadProgress(
      total: 40,
      completed: 12,
      uploaded: 10,
      skipped: 2,
      failed: failed,
      active: [
        const ActiveUpload(
          index: 12,
          name: 'holiday.mov',
          phase: UploadPhase.uploading,
          bytesSent: 2 * 1024 * 1024,
          bytesTotal: 8 * 1024 * 1024,
        ),
        const ActiveUpload(
          index: 13,
          name: 'IMG_0042.HEIC',
          phase: UploadPhase.preparing,
        ),
      ],
      bytesUploaded: 30 * 1024 * 1024,
      startedAt: DateTime.now().subtract(const Duration(seconds: 30)),
    );
    session.settingsChanged();
  }

  /// Opens the sheet and lets it slide in. Not pumpAndSettle: a file that
  /// is still being encrypted has an indeterminate bar, which never settles.
  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.text('Details'));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> pumpBar(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: ListenableBuilder(
            listenable: session,
            builder: (context, _) => BackupStatusBar(session: session),
          ),
        ),
      ),
    );
  }

  testWidgets('the bar counts and measures what is going up', (tester) async {
    await pumpBar(tester);
    // Nothing running: the bar keeps out of the way.
    expect(find.textContaining('Backing up'), findsNothing);

    halfway();
    await tester.pump();
    // 12 settled plus a quarter of the video in flight.
    expect(find.text('Backing up 13 of 40 · 31%'), findsOne);
    // With four workers, naming one means naming whichever is slowest, so
    // the bar counts them instead.
    expect(find.textContaining('2 files at once'), findsOne);
    expect(find.textContaining('holiday.mov'), findsNothing);
    // The rate comes from the bytes and the clock, so only its shape is sure.
    expect(find.textContaining('MB/s'), findsOne);
    expect(find.textContaining('left'), findsOne);

    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    // The file in flight moves the bar, rather than it sitting on 12/40
    // until a whole batch of catalogue entries lands.
    expect(bar.value, closeTo(12.25 / 40, 0.001));
    expect(tester.takeException(), isNull);
  });

  testWidgets('one file in flight is named', (tester) async {
    await pumpBar(tester);
    session.upload = UploadProgress(
      total: 3,
      completed: 1,
      uploaded: 1,
      skipped: 0,
      failed: 0,
      active: const [
        ActiveUpload(
          index: 1,
          name: 'holiday.mov',
          phase: UploadPhase.uploading,
          bytesSent: 1024,
          bytesTotal: 4096,
        ),
      ],
      bytesUploaded: 2048,
      startedAt: DateTime.now().subtract(const Duration(seconds: 10)),
    );
    session.settingsChanged();
    await tester.pump();
    expect(find.textContaining('holiday.mov'), findsOne);
  });

  testWidgets('getting ready says so instead of showing an empty bar', (
    tester,
  ) async {
    await pumpBar(tester);
    session.upload = UploadProgress(
      total: 200,
      completed: 0,
      uploaded: 0,
      skipped: 0,
      failed: 0,
      startedAt: DateTime.now(),
      stage: BackupStage.preparing,
    );
    session.settingsChanged();
    await tester.pump();

    expect(find.text('Getting your photos ready…'), findsOne);
    // Indeterminate: there is nothing yet to measure.
    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, isNull);
  });

  testWidgets('stopping says how much is left to finish', (tester) async {
    await pumpBar(tester);
    halfway();
    session.upload = UploadProgress(
      total: 40,
      completed: 12,
      uploaded: 10,
      skipped: 2,
      failed: 0,
      active: session.upload!.active,
      bytesUploaded: 30 * 1024 * 1024,
      startedAt: DateTime.now().subtract(const Duration(seconds: 30)),
      stage: BackupStage.stopping,
    );
    session.settingsChanged();
    await tester.pump();

    expect(find.text('Stopping — finishing 2 files'), findsOne);
    // No point estimating a finish time for a run that is ending.
    expect(find.textContaining('left'), findsNothing);
  });

  testWidgets('the bar opens the detail sheet, file by file', (tester) async {
    await pumpBar(tester);
    halfway();
    await tester.pump();

    await openSheet(tester);

    expect(find.text('Backing up'), findsOne);
    expect(find.text('Going up now'), findsOne);
    // Both workers, with what each is doing and how far the bytes have got.
    expect(find.text('holiday.mov'), findsOne);
    expect(find.textContaining('Uploading · 2.0 MB of 8.0 MB'), findsOne);
    expect(find.text('IMG_0042.HEIC'), findsOne);
    expect(find.text('Encrypting'), findsOne);
    // The tallies.
    expect(find.text('Already safe'), findsOne);
    expect(find.text('Left'), findsOne);
    expect(find.text('28'), findsOne);
    expect(find.text('Stop'), findsOne);
  });

  testWidgets('failures are named with their reason', (tester) async {
    await pumpBar(tester);
    session.recentResults.addAll([
      const UploadResult(
        UploadSource(name: 'huge.mov', read: _noBytes),
        UploadOutcome.failed,
        error: 'This file is 900 MB.',
      ),
      const UploadResult(
        UploadSource(name: 'beach.jpg', read: _noBytes),
        UploadOutcome.uploaded,
      ),
    ]);
    halfway(failed: 1);
    await tester.pump();

    await openSheet(tester);

    expect(find.text('Didn\'t work'), findsOne);
    expect(find.text('Just finished'), findsOne);
    expect(find.text('beach.jpg'), findsOne);
    // The failure is called out on its own as well as in the run of
    // finished files, so it appears in both lists.
    expect(find.text('huge.mov'), findsNWidgets(2));
    expect(find.text('This file is 900 MB.'), findsNWidgets(2));
  });

  testWidgets('a real backup fills the sheet and then stands down', (
    tester,
  ) async {
    // Real work, outside the test's fake clock: the crypto wants timers.
    await tester.runAsync(session.scanGallery);
    await tester.runAsync(session.backUpPending);
    await pumpBar(tester);

    expect(find.textContaining('Backing up'), findsNothing);
    expect(session.recentResults, hasLength(12));
    expect(session.upload!.done, isTrue);
    expect(session.upload!.bytesUploaded, greaterThan(0));

    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    unawaited(showBackupSheet(ctx, session));
    await tester.pumpAndSettle();

    expect(find.text('Backup finished'), findsOne);
    expect(find.textContaining('12 of 12 done'), findsOne);
    expect(find.text('asset0.jpg'), findsOne);
    expect(find.text('Stop'), findsNothing);
  });
}

Future<Never> _noBytes() async => throw UnimplementedError();
