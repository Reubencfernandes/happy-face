import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:happy_drive/data/bucket_name.dart';
import 'package:happy_drive/data/hf_profile.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Client serving(Map<String, Object> routes, {List<String>? seen}) =>
    MockClient((request) async {
      seen?.add(request.url.path);
      final body = routes[request.url.path];
      return switch (body) {
        null => http.Response('{"error":"Not found"}', 404),
        final int status => http.Response('', status),
        _ => http.Response(jsonEncode(body), 200),
      };
    });

void main() {
  group('Hugging Face profile', () {
    test('reads the public profile of a user', () async {
      final profile = await fetchHfProfile(
        'reuben',
        client: serving({
          '/api/users/reuben/overview': {
            'user': 'reuben',
            'fullname': 'Reuben Fernandes',
            'avatarUrl': 'https://cdn-avatars.huggingface.co/v1/abc.jpeg',
            'isPro': true,
            'numBuckets': 3,
          },
        }),
      );
      expect(profile?.username, 'reuben');
      expect(profile?.displayName, 'Reuben Fernandes');
      expect(
        profile?.avatarUrl,
        'https://cdn-avatars.huggingface.co/v1/abc.jpeg',
      );
      expect(profile?.isPro, isTrue);
      expect(profile?.buckets, 3);
      expect(profile?.initials, 'RF');
    });

    test('falls back to the organisation profile', () async {
      final seen = <String>[];
      final profile = await fetchHfProfile(
        'acme-labs',
        client: serving({
          '/api/organizations/acme-labs/overview': {
            'name': 'acme-labs',
            'fullname': 'Acme Labs',
            'avatarUrl': '/avatars/acme.png',
          },
        }, seen: seen),
      );
      expect(seen, [
        '/api/users/acme-labs/overview',
        '/api/organizations/acme-labs/overview',
      ]);
      expect(profile?.username, 'acme-labs');
      // A site-relative avatar is made absolute so Image.network can load it.
      expect(profile?.avatarUrl, 'https://huggingface.co/avatars/acme.png');
    });

    test('an SVG avatar counts as no avatar', () async {
      // Hugging Face draws the "no picture yet" avatars as SVG, which
      // Flutter can't decode: initials look better than a broken box.
      final profile = await fetchHfProfile(
        'reuben',
        client: serving({
          '/api/users/reuben/overview': {
            'user': 'reuben',
            'avatarUrl': '/avatars/2f8a.svg',
          },
        }),
      );
      expect(profile?.username, 'reuben');
      expect(profile?.avatarUrl, isNull);
      expect(profile?.initials, 'R');
    });

    test('keeps the signed-in name when the reply omits it', () async {
      final profile = await fetchHfProfile(
        'reuben',
        client: serving({
          '/api/users/reuben/overview': {'fullname': 'Reuben'},
        }),
      );
      expect(profile?.username, 'reuben');
      expect(profile?.avatarUrl, isNull);
    });

    test('a missing or broken profile is just no profile', () async {
      expect(await fetchHfProfile('nobody', client: serving({})), isNull);
      expect(
        await fetchHfProfile(
          'reuben',
          client: serving({'/api/users/reuben/overview': 500}),
        ),
        isNull,
      );
      expect(await fetchHfProfile('  ', client: serving({})), isNull);
    });

    test('survives a round trip through the settings cache', () {
      const profile = HfProfile(
        username: 'reuben',
        fullName: 'Reuben Fernandes',
        avatarUrl: 'https://example.com/a.png',
        isPro: true,
        buckets: 2,
      );
      final copy = HfProfile.fromJson(
        jsonDecode(jsonEncode(profile.toJson())) as Map<String, dynamic>,
      );
      expect(copy.username, profile.username);
      expect(copy.fullName, profile.fullName);
      expect(copy.avatarUrl, profile.avatarUrl);
      expect(copy.isPro, isTrue);
      expect(copy.buckets, 2);
    });
  });

  group('the avatar itself', () {
    test('is downloaded so it can be kept and shown offline', () async {
      final bytes = Uint8List.fromList(List.filled(64, 7));
      final avatar = await fetchHfAvatar(
        'https://cdn-avatars.huggingface.co/a.png',
        client: MockClient(
          (_) async => http.Response.bytes(
            bytes,
            200,
            headers: {'content-type': 'image/webp'},
          ),
        ),
      );
      expect(avatar, bytes);
    });

    test('anything that is not an image is no avatar', () async {
      Future<Uint8List?> served(http.Response response) => fetchHfAvatar(
        'https://cdn-avatars.huggingface.co/a.png',
        client: MockClient((_) async => response),
      );
      // An HTML error page, an SVG placeholder, a 404, an empty body.
      expect(
        await served(
          http.Response('<html>', 200, headers: {'content-type': 'text/html'}),
        ),
        isNull,
      );
      expect(
        await served(
          http.Response(
            '<svg/>',
            200,
            headers: {'content-type': 'image/svg+xml'},
          ),
        ),
        isNull,
      );
      expect(await served(http.Response('', 404)), isNull);
      expect(
        await served(
          http.Response.bytes(
            Uint8List(0),
            200,
            headers: {'content-type': 'image/png'},
          ),
        ),
        isNull,
      );
    });
  });

  group('private storage allowance', () {
    // Hugging Face's published limits: 100GB free, 1TB with PRO, and
    // per-seat for organisations, which depends on billing we can't see.
    test('a free account gets the documented 100GB', () {
      const profile = HfProfile(username: 'reuben');
      expect(profile.privateAllowance, 100000000000);
      expect(profile.allowanceLabel, '100 GB');
      expect(profile.planLabel, 'Free plan');
    });

    test('PRO gets 1TB', () {
      const profile = HfProfile(username: 'reuben', isPro: true);
      expect(profile.privateAllowance, 1000000000000);
      expect(profile.allowanceLabel, '1 TB');
      expect(profile.planLabel, 'PRO');
    });

    test('an organisation is per-seat, so nothing is claimed', () {
      const org = HfProfile(username: 'acme-labs', plan: 'team');
      expect(org.privateAllowance, isNull);
      expect(org.allowanceLabel, isNull);
      expect(org.planLabel, 'Team plan');
    });
  });

  group('bucket names', () {
    test('are valid Hugging Face bucket names', () {
      final pattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$');
      for (var i = 0; i < 200; i++) {
        expect(pattern.hasMatch(generateBucketName()), isTrue);
      }
    });

    test('are different from one another', () {
      final names = {for (var i = 0; i < 50; i++) generateBucketName()};
      expect(names.length, greaterThan(40));
    });
  });
}
