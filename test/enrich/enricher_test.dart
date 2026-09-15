import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:happy_drive/app/credentials.dart';
import 'package:happy_drive/app/session.dart';
import 'package:happy_drive/crypto/vault.dart';
import 'package:happy_drive/data/catalogue.dart';
import 'package:happy_drive/data/local_db.dart';
import 'package:happy_drive/data/remote_catalogue.dart';
import 'package:happy_drive/enrich/enricher.dart';
import 'package:happy_drive/enrich/places.dart';
import 'package:happy_drive/enrich/weather.dart';
import 'package:happy_drive/sync/photo_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../app/session_test.dart' show FakeGallery;
import '../support/fake_bucket.dart';
import 'weather_test.dart' show hourly;

void main() {
  late FakeBucket bucket;
  late Vault vault;
  late Session session;
  final places = PlaceIndex.parse(
    utf8.decode(
      gzip.decode(File('assets/places/cities.tsv.gz').readAsBytesSync()),
    ),
    File('assets/places/countries.tsv').readAsStringSync(),
  );
  final now = DateTime.utc(2026, 9, 15);

  PhotoRecord rec(String id, {double? lat, double? lng, DateTime? taken}) =>
      PhotoRecord(
        id: id,
        name: '$id.jpg',
        mime: 'image/jpeg',
        size: 1,
        takenAt: taken ?? DateTime.utc(2025, 6, 1, 9),
        uploadedAt: DateTime.utc(2025, 6, 2),
        lat: lat,
        lng: lng,
      );

  Enricher enricher({http.Client? weatherHttp}) => Enricher(
    session,
    loadPlaces: () async => places,
    weather: WeatherClient(
      clock: () => now,
      client: weatherHttp ?? MockClient((r) async => fail('weather is off')),
    ),
    clock: () => now,
    sleep: (_) async {},
  );

  setUp(() async {
    bucket = FakeBucket();
    vault = await Vault.fromMasterKey(List.filled(32, 8));
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
      gallery: FakeGallery(0),
    );
    // Photos uploaded by another phone that never enriched them.
    await RemoteCatalogue(bucket.client(), vault).commit([
      PutOp(rec('goa', lat: 15.4909, lng: 73.8278), 1),
      PutOp(rec('lisbon', lat: 38.7223, lng: -9.1393), 2),
      PutOp(rec('ocean', lat: 30.0, lng: -40.0), 3),
      PutOp(rec('nogps'), 4),
    ]);
    await session.sync();
  });
  tearDown(() => session.dispose());

  test('place names are added offline and shared with other devices', () async {
    await enricher().run();
    expect(session.db.photo('goa')!.place, 'Panjim');
    expect(session.db.photo('goa')!.country, 'India');
    expect(session.db.photo('lisbon')!.place, 'Lisbon');
    expect(session.db.photo('ocean')!.place, isNull);
    expect(
      session.db.places().map((p) => p.place),
      containsAll(['Panjim', 'Lisbon']),
    );
    expect(session.db.jobCount(JobKind.place), 0);

    // At sea: tried once, never queued again.
    session.db.enqueueMissingEnrichment();
    expect(session.db.jobCount(JobKind.place), 0);

    final otherPhone = RemoteCatalogue(bucket.client(), vault);
    await otherPhone.load();
    expect(otherPhone.state.records['lisbon']!.country, 'Portugal');
    expect(
      bucket.objects.values.every((v) => !latin1.decode(v).contains('Lisbon')),
      isTrue,
    );
  });

  test('weather stays off until enabled, then fills in', () async {
    await enricher().run();
    expect(session.db.photo('goa')!.weather, isNull);
    expect(session.db.jobCount(JobKind.weather), 3);

    session.settings.weather = true;
    var requests = 0;
    await enricher(
      weatherHttp: MockClient((r) async {
        requests++;
        return http.Response(hourly('2025-06-01'), 200);
      }),
    ).run();
    expect(session.db.photo('goa')!.weather!['summary'], 'Clear sky');
    expect(session.db.photo('lisbon')!.weather!['tempC'], 20.9);
    expect(session.db.photo('nogps')!.weather, isNull);
    expect(requests, 3);
    expect(session.db.jobCount(JobKind.weather), 0);
  });

  test('weather not yet published is retried later, not dropped', () async {
    session.settings.weather = true;
    await enricher(
      weatherHttp: MockClient(
        (r) async => http.Response(
          hourly('2025-06-01', codes: List.filled(24, null)),
          200,
        ),
      ),
    ).run();
    expect(session.db.photo('goa')!.weather, isNull);
    expect(session.db.jobCount(JobKind.weather), 3);
    expect(session.db.dueJobs(JobKind.weather, now), isEmpty);
    expect(
      session.db.dueJobs(JobKind.weather, now.add(const Duration(days: 3))),
      hasLength(3),
    );
  });

  test('going offline stops the weather pass without losing jobs', () async {
    session.settings.weather = true;
    await enricher(
      weatherHttp: MockClient(
        (r) async => throw const SocketException('offline'),
      ),
    ).run();
    expect(session.db.dueJobs(JobKind.weather, now), hasLength(3));
  });
}
