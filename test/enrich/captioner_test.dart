import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:happy_drive/app/credentials.dart';
import 'package:happy_drive/app/session.dart';
import 'package:happy_drive/crypto/vault.dart';
import 'package:happy_drive/data/bucket_layout.dart';
import 'package:happy_drive/data/catalogue.dart';
import 'package:happy_drive/data/local_db.dart';
import 'package:happy_drive/data/remote_catalogue.dart';
import 'package:happy_drive/enrich/captioner.dart';
import 'package:happy_drive/enrich/enricher.dart';
import 'package:happy_drive/enrich/places.dart';
import 'package:happy_drive/enrich/weather.dart';
import 'package:happy_drive/sync/photo_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../app/session_test.dart' show FakeGallery;
import '../support/fake_bucket.dart';

String reply(String content) => jsonEncode({
  'choices': [
    {
      'message': {'role': 'assistant', 'content': content},
    },
  ],
});

void main() {
  group('Captioner', () {
    test('sends the thumbnail as a data URL with the token and model', () async {
      late http.Request seen;
      final captioner = Captioner(
        client: MockClient((r) async {
          seen = r;
          return http.Response(
            reply(
              '{"caption": "A dog on a beach at sunset", "tags": ["Dog", "beach", "sunset"]}',
            ),
            200,
          );
        }),
      );
      final result = await captioner.describe(
        Uint8List.fromList([0xFF, 0xD8, 0xFF, 1, 2]),
        model: 'Qwen/Qwen3.8-27B',
        token: 'hf_test',
      );
      expect(result.caption, 'A dog on a beach at sunset');
      expect(result.tags, ['dog', 'beach', 'sunset']);

      expect(
        seen.url.toString(),
        'https://router.huggingface.co/v1/chat/completions',
      );
      expect(seen.headers['Authorization'], 'Bearer hf_test');
      final body = jsonDecode(seen.body) as Map<String, dynamic>;
      expect(body['model'], 'Qwen/Qwen3.8-27B');
      final content = (body['messages'] as List).single['content'] as List;
      expect(content.first['type'], 'text');
      expect(content.last['type'], 'image_url');
      expect(
        content.last['image_url']['url'],
        'data:image/jpeg;base64,${base64Encode([0xFF, 0xD8, 0xFF, 1, 2])}',
      );
    });

    test('tolerates reasoning blocks, code fences and chatter', () {
      final r = Captioner.parse(
        '<think>The user wants JSON. I see a mountain.</think>\n'
        'Sure! Here you go:\n```json\n{"caption": "Snowy mountain road", "tags": ["snow", "road", " road "]}\n```',
      );
      expect(r.caption, 'Snowy mountain road');
      expect(r.tags, ['snow', 'road']);
      expect(
        Captioner.parse('A plate of fish curry and rice.').caption,
        'A plate of fish curry and rice.',
      );
      expect(
        () => Captioner.parse('{"oops": '),
        throwsA(isA<CaptionException>()),
      );
      expect(() => Captioner.parse(''), throwsA(isA<CaptionException>()));
    });

    test('maps HTTP errors to what the app should do', () async {
      Future<CaptionFailure> failureFor(int status, [String body = '']) async {
        final c = Captioner(
          client: MockClient((r) async => http.Response(body, status)),
        );
        try {
          await c.describe(Uint8List(1), model: 'm', token: 't');
        } on CaptionException catch (e) {
          return e.failure;
        }
        fail('expected a failure for $status');
      }

      expect(await failureFor(401), CaptionFailure.token);
      expect(await failureFor(402), CaptionFailure.credits);
      expect(await failureFor(429), CaptionFailure.busy);
      expect(
        await failureFor(
          400,
          '{"error": "Model does not support image input"}',
        ),
        CaptionFailure.model,
      );
      expect(await failureFor(503), CaptionFailure.other);
      expect(
        const CaptionException(CaptionFailure.credits, '').pausesCaptioning,
        isTrue,
      );
      expect(
        const CaptionException(CaptionFailure.busy, '').pausesCaptioning,
        isFalse,
      );
    });
  });

  group('caption enrichment', () {
    late FakeBucket bucket;
    late Vault vault;
    late Session session;
    final now = DateTime.utc(2026, 9, 15, 12);

    setUp(() async {
      bucket = FakeBucket();
      vault = await Vault.fromMasterKey(List.filled(32, 6));
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
      final other = RemoteCatalogue(bucket.client(), vault);
      final ops = <CatalogueOp>[];
      for (var i = 0; i < 6; i++) {
        final id = 'photo$i';
        final thumbKey = BucketLayout.thumbnail(id);
        bucket.objects[thumbKey] = await vault.seal([
          0xFF,
          0xD8,
          0xFF,
          i,
        ], context: thumbKey);
        bucket.objects[BucketLayout.original(id)] = await vault.seal(
          List.filled(5000, i),
          context: BucketLayout.original(id),
        );
        ops.add(
          PutOp(
            PhotoRecord(
              id: id,
              name: '$id.jpg',
              mime: 'image/jpeg',
              size: 5000,
              takenAt: DateTime.utc(2025, 1, i + 1),
              // Half were uploaded before AI was turned on.
              uploadedAt: i < 3
                  ? DateTime.utc(2026, 1, 1)
                  : DateTime.utc(2026, 9, 10),
            ),
            i + 1,
          ),
        );
      }
      await other.commit(ops);
      await session.sync();
      session.settings
        ..aiCaptions = true
        ..aiEnabledAt = DateTime.utc(2026, 9, 1);
    });
    tearDown(() => session.dispose());

    Enricher enricher(
      Future<http.Response> Function(http.Request) handler, {
      String? token = 'hf_test',
    }) => Enricher(
      session,
      loadPlaces: () async => PlaceIndex.parse('', ''),
      weather: WeatherClient(
        client: MockClient((r) async => fail('weather is off')),
      ),
      captioner: Captioner(client: MockClient(handler)),
      readToken: () async => token,
      clock: () => now,
      sleep: (_) async {},
    );

    test(
      'describes only photos uploaded after AI was turned on, sending thumbnails',
      () async {
        final sentImages = <String>[];
        await enricher((r) async {
          final content =
              (jsonDecode(r.body)['messages'] as List).single['content']
                  as List;
          sentImages.add(content.last['image_url']['url'] as String);
          return http.Response(
            reply('{"caption": "Test photo", "tags": ["test"]}'),
            200,
          );
        }).run();

        expect(sentImages, hasLength(3));
        for (final url in sentImages) {
          // Thumbnails are a few bytes here; originals are 5 KB.
          expect(base64Decode(url.split(',').last).length, lessThan(100));
        }
        expect(session.db.photo('photo5')!.caption, 'Test photo');
        expect(
          session.db.photo('photo5')!.captionModel,
          Settings.defaultAiModel,
        );
        expect(session.db.photo('photo0')!.caption, isNull);
        expect(session.db.search('test').map((r) => r.id).toSet(), {
          'photo3',
          'photo4',
          'photo5',
        });
        expect(session.settings.aiUsedToday(now), 3);

        session.settings.aiWholeLibrary = true;
        await enricher(
          (r) async => http.Response(reply('{"caption": "Older photo"}'), 200),
        ).run();
        expect(session.db.photo('photo0')!.caption, 'Older photo');
        expect(session.settings.aiUsedThisMonth(now), 6);
      },
    );

    test('the daily limit is respected across runs', () async {
      session.settings
        ..aiWholeLibrary = true
        ..aiDailyLimit = 4;
      var calls = 0;
      Future<http.Response> ok(http.Request r) async {
        calls++;
        return http.Response(reply('{"caption": "x"}'), 200);
      }

      await enricher(ok).run();
      await enricher(ok).run();
      expect(calls, 4);
      expect(session.db.jobCount(JobKind.caption), 2);
    });

    test('running out of credits pauses descriptions until resumed', () async {
      var calls = 0;
      await enricher((r) async {
        calls++;
        return http.Response('{"error": "insufficient credits"}', 402);
      }).run();
      expect(calls, 1, reason: 'stops at the first 402');
      expect(session.settings.aiPausedReason, contains('credits'));

      await enricher((r) async => fail('paused')).run();

      session.settings.aiPausedReason = null;
      await enricher(
        (r) async => http.Response(reply('{"caption": "Back"}'), 200),
      ).run();
      expect(session.db.photo('photo3')!.caption, 'Back');
    });

    test('without a token nothing is sent', () async {
      await enricher((r) async => fail('no token'), token: null).run();
      expect(session.db.jobCount(JobKind.caption), 6);
    });

    test('a photo another phone already described is not sent again', () async {
      await RemoteCatalogue(bucket.client(), vault).commit([
        PatchOp('photo5', {'caption': 'From the other phone'}, 99),
      ]);
      await session.sync();
      final sent = <String>[];
      await enricher((r) async {
        sent.add(r.body);
        return http.Response(reply('{"caption": "New"}'), 200);
      }).run();
      expect(sent, hasLength(2));
      expect(session.db.photo('photo5')!.caption, 'From the other phone');
    });
  });
}
