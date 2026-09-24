import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:happy_drive/app/credentials.dart';
import 'package:happy_drive/s3/s3_client.dart';
import 'package:happy_drive/ui/connect_screen.dart';
import 'package:happy_drive/ui/theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A Hugging Face account with buckets in it: which exist, which already
/// hold a library, and whether the gateway is willing to list them.
class FakeAccount {
  final Set<String> buckets;
  final Set<String> withLibrary;
  final bool listable;
  final created = <String>[];

  FakeAccount({
    Set<String>? buckets,
    Set<String>? withLibrary,
    this.listable = true,
  }) : buckets = buckets ?? {},
       withLibrary = withLibrary ?? {};

  BucketClient client(StoredAccount a) => BucketClient(
    namespace: a.namespace,
    bucket: a.bucket,
    credentials: a.credentials,
    client: MockClient(_handle),
    sleep: (_) async {},
  );

  Future<http.Response> _handle(http.Request r) async {
    // Unsigned requests are what the public-bucket check makes: refuse them,
    // which is what a private bucket does.
    if (!r.headers.containsKey('authorization')) {
      return http.Response('<Error><Code>AccessDenied</Code></Error>', 403);
    }
    final parts = Uri.decodeComponent(
      r.url.path,
    ).split('/').where((p) => p.isNotEmpty).toList();
    if (parts.length == 1) {
      if (!listable) return http.Response('', 403);
      return http.Response(
        '<ListAllMyBucketsResult><Buckets>'
        '${buckets.map((b) => '<Bucket><Name>$b</Name></Bucket>').join()}'
        '</Buckets></ListAllMyBucketsResult>',
        200,
      );
    }
    final bucket = parts[1];
    final key = parts.skip(2).join('/');
    if (key.isEmpty) {
      if (r.method == 'PUT') {
        buckets.add(bucket);
        created.add(bucket);
        return http.Response('', 200);
      }
      if (r.method == 'HEAD') {
        return http.Response('', buckets.contains(bucket) ? 200 : 404);
      }
      return http.Response('<ListBucketResult></ListBucketResult>', 200);
    }
    if (key == 'v1/keys' && withLibrary.contains(bucket)) {
      return http.Response('', 200);
    }
    return http.Response('', 404);
  }
}

void main() {
  late FakeAccount cloud;
  late List<ConnectResult> connected;

  Future<void> open(WidgetTester tester, {StoredAccount? previous}) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: ConnectScreen(
          clientFactory: cloud.client,
          previous: previous,
          onConnected: connected.add,
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> fillKeys(WidgetTester tester) async {
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Hugging Face username'),
      'reuben',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Access key'),
      'HFAKTEST1234',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Secret'),
      'secretsecret',
    );
  }

  /// The bucket field, which is whichever of the two is on screen.
  Future<void> nameBucket(WidgetTester tester, String name) =>
      tester.enterText(find.widgetWithText(TextFormField, 'Bucket name'), name);

  Future<void> connect(WidgetTester tester) async {
    await tester.tap(find.text('Connect'));
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  setUp(() {
    cloud = FakeAccount();
    connected = [];
  });

  testWidgets('the bucket is asked about up front, not hidden away', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('Where the photos go'), findsOneWidget);
    expect(find.text('New bucket'), findsOneWidget);
    expect(find.text('My bucket'), findsOneWidget);
    expect(find.text('A new private bucket, made in your account'), findsOne);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a new bucket is created and connected to', (tester) async {
    await open(tester);
    await fillKeys(tester);
    await nameBucket(tester, 'sunny-otter-482');
    await connect(tester);

    expect(cloud.created, ['sunny-otter-482']);
    expect(connected, hasLength(1));
    expect(connected.single.account.bucket, 'sunny-otter-482');
    expect(connected.single.hasLibrary, isFalse);
  });

  testWidgets('a new bucket won\'t be pointed at somebody\'s library', (
    tester,
  ) async {
    cloud = FakeAccount(buckets: {'old-one'}, withLibrary: {'old-one'});
    await open(tester);
    await fillKeys(tester);
    await nameBucket(tester, 'old-one');
    await connect(tester);

    expect(connected, isEmpty);
    expect(
      find.textContaining('already holds a Happy Drive library'),
      findsOne,
    );
  });

  testWidgets(
    'after a reinstall, the old library is offered before a new one',
    (tester) async {
      cloud = FakeAccount(buckets: {'old-one'}, withLibrary: {'old-one'});
      await open(tester);
      await fillKeys(tester);
      await nameBucket(tester, 'sunny-otter-482');
      await connect(tester);

      expect(find.text('You already have a library'), findsOneWidget);
      expect(cloud.created, isEmpty, reason: 'nothing is made while asking');
      await tester.tap(find.text('old-one'));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(cloud.created, isEmpty);
      expect(connected.single.account.bucket, 'old-one');
      expect(connected.single.hasLibrary, isTrue);
    },
  );

  testWidgets('an empty library can still be started on purpose', (
    tester,
  ) async {
    cloud = FakeAccount(buckets: {'old-one'}, withLibrary: {'old-one'});
    await open(tester);
    await fillKeys(tester);
    await nameBucket(tester, 'sunny-otter-482');
    await connect(tester);
    await tester.tap(find.text('Start an empty one'));
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(cloud.created, ['sunny-otter-482']);
    expect(connected.single.hasLibrary, isFalse);
  });

  testWidgets('an existing bucket is opened rather than made', (tester) async {
    cloud = FakeAccount(buckets: {'old-one'}, withLibrary: {'old-one'});
    await open(tester);
    await fillKeys(tester);
    await tester.tap(find.text('My bucket'));
    await tester.pump();
    await nameBucket(tester, 'old-one');
    await connect(tester);

    expect(cloud.created, isEmpty, reason: 'nothing new is made');
    expect(connected.single.account.bucket, 'old-one');
    expect(connected.single.hasLibrary, isTrue);
  });

  testWidgets('a misspelt existing bucket is not quietly created', (
    tester,
  ) async {
    cloud = FakeAccount(buckets: {'old-one'});
    await open(tester);
    await fillKeys(tester);
    await tester.tap(find.text('My bucket'));
    await tester.pump();
    await nameBucket(tester, 'old-once');
    await connect(tester);

    expect(cloud.created, isEmpty);
    expect(connected, isEmpty);
    expect(find.textContaining('There\'s no bucket named'), findsOne);
  });

  testWidgets('browsing lists the buckets and says which hold a library', (
    tester,
  ) async {
    cloud = FakeAccount(
      buckets: {'old-one', 'spare', 'models'},
      withLibrary: {'old-one'},
    );
    await open(tester);
    await fillKeys(tester);
    await tester.tap(find.text('My bucket'));
    await tester.pump();

    await tester.tap(find.text('Browse my buckets'));
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(find.text('Your buckets'), findsOne);
    expect(find.text('old-one'), findsOne);
    expect(find.text('Has a Happy Drive library'), findsOne);
    expect(find.text('No library in here yet'), findsNWidgets(2));

    await tester.tap(find.text('old-one'));
    await tester.pumpAndSettle();
    await connect(tester);
    expect(connected.single.account.bucket, 'old-one');
  });

  testWidgets('when Hugging Face won\'t list, it says to type the name', (
    tester,
  ) async {
    cloud = FakeAccount(buckets: {'old-one'}, listable: false);
    await open(tester);
    await fillKeys(tester);
    await tester.tap(find.text('My bucket'));
    await tester.pump();
    await tester.tap(find.text('Browse my buckets'));
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(find.textContaining('didn\'t list your buckets'), findsOne);
  });

  testWidgets('a phone that has connected before starts on its own bucket', (
    tester,
  ) async {
    cloud = FakeAccount(buckets: {'old-one'}, withLibrary: {'old-one'});
    await open(
      tester,
      previous: const StoredAccount(
        namespace: 'reuben',
        bucket: 'old-one',
        accessKeyId: 'HFAKTEST1234',
        secretAccessKey: '',
      ),
    );
    expect(find.text('The bucket your library is already in'), findsOne);
    expect(
      tester
          .widgetList<EditableText>(find.byType(EditableText))
          .map((e) => e.controller.text),
      contains('old-one'),
    );
  });
}
