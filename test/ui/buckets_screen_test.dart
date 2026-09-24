import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:happy_drive/app/credentials.dart';
import 'package:happy_drive/data/storage_usage.dart';
import 'package:happy_drive/s3/s3_client.dart';
import 'package:happy_drive/ui/buckets_screen.dart';
import 'package:happy_drive/ui/theme.dart';

const account = StoredAccount(
  namespace: 'reuben',
  bucket: 'happy-drive',
  accessKeyId: 'HFAKTEST',
  secretAccessKey: 'x',
);

final usage = StorageUsage([
  const BucketUsage(
    name: 'happy-drive',
    connected: true,
    bytes: {UsageKind.photos: 5000000, UsageKind.catalogue: 900},
    objects: 164,
  ),
  const BucketUsage(
    name: 'old-library',
    connected: false,
    bytes: {UsageKind.photos: 2000000, UsageKind.catalogue: 400},
    objects: 12,
  ),
  const BucketUsage(name: 'snug-cove-542', connected: false),
]);

void main() {
  late List<String> erased;
  late bool? popped;

  Future<void> open(WidgetTester tester) async {
    erased = [];
    popped = null;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                popped = await Navigator.of(context).push<bool>(
                  MaterialPageRoute(
                    builder: (_) => BucketsScreen(
                      account: account,
                      usage: usage,
                      // Never used for requests: the eraser is fake.
                      clientFactory: defaultBucketClient,
                      erase: (BucketClient client, {onProgress}) async {
                        erased.add(client.bucket);
                        onProgress?.call(1, 1);
                      },
                    ),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('the bucket this phone uses can\'t be deleted', (tester) async {
    await open(tester);
    expect(find.text('happy-drive'), findsOneWidget);
    expect(find.byTooltip('Delete happy-drive'), findsNothing);
    expect(find.byTooltip('Delete old-library'), findsOneWidget);
    expect(find.byTooltip('Delete snug-cove-542'), findsOneWidget);
    expect(find.textContaining('Happy Drive library'), findsOneWidget);
  });

  testWidgets('deleting waits for the name to be typed', (tester) async {
    await open(tester);
    await tester.tap(find.byTooltip('Delete old-library'));
    await tester.pumpAndSettle();
    expect(find.textContaining('permanently deletes 12 files'), findsOneWidget);
    expect(find.textContaining('holds a Happy Drive library'), findsOneWidget);

    FilledButton delete() => tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Delete'),
    );
    expect(delete().onPressed, isNull);
    await tester.enterText(find.byType(TextField), 'old-librar');
    await tester.pump();
    expect(delete().onPressed, isNull);
    await tester.enterText(find.byType(TextField), 'old-library');
    await tester.pump();
    expect(delete().onPressed, isNotNull);

    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(erased, ['old-library']);
    expect(find.text('old-library'), findsNothing);
    expect(find.text('Deleted old-library'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(popped, isTrue, reason: 'Settings measures again');
  });

  testWidgets('cancelling deletes nothing', (tester) async {
    await open(tester);
    await tester.tap(find.byTooltip('Delete snug-cove-542'));
    await tester.pumpAndSettle();
    expect(find.textContaining('This bucket is empty'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(erased, isEmpty);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(popped, isFalse);
  });
}
