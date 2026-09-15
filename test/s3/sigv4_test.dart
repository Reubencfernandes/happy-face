import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:happy_drive/s3/sigv4.dart';

String signatureOf(Map<String, String> headers) => RegExp(
  r'Signature=([0-9a-f]{64})',
).firstMatch(headers['authorization']!)!.group(1)!;

void main() {
  group('AWS SigV4 test suite', () {
    const signer = SigV4Signer(
      S3Credentials('AKIDEXAMPLE', 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY'),
      service: 'service',
    );

    test('get-vanilla', () {
      final h = signer.sign(
        method: 'GET',
        uri: Uri.parse('https://example.amazonaws.com/'),
        payloadHash: emptyPayloadHash,
        now: DateTime.utc(2015, 8, 30, 12, 36),
      );
      expect(
        h['authorization'],
        'AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/'
        'aws4_request, SignedHeaders=host;x-amz-date, Signature='
        '5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31',
      );
    });
  });

  group('AWS S3 documentation examples', () {
    const signer = SigV4Signer(
      S3Credentials(
        'AKIAIOSFODNN7EXAMPLE',
        'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
      ),
    );
    final now = DateTime.utc(2013, 5, 24);
    const host = 'https://examplebucket.s3.amazonaws.com';

    test('GET object with range', () {
      final h = signer.sign(
        method: 'GET',
        uri: Uri.parse('$host/test.txt'),
        headers: {
          'range': 'bytes=0-9',
          'x-amz-content-sha256': emptyPayloadHash,
        },
        payloadHash: emptyPayloadHash,
        now: now,
      );
      expect(
        signatureOf(h),
        'f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41',
      );
    });

    test('PUT object with an encoded key and signed payload', () {
      final hash = sha256Hex(utf8.encode('Welcome to Amazon S3.'));
      final h = signer.sign(
        method: 'PUT',
        uri: Uri.parse(r'https://examplebucket.s3.amazonaws.com/test$file.text'),
        headers: {
          'date': 'Fri, 24 May 2013 00:00:00 GMT',
          'x-amz-storage-class': 'REDUCED_REDUNDANCY',
          'x-amz-content-sha256': hash,
        },
        payloadHash: hash,
        now: now,
      );
      expect(
        signatureOf(h),
        '98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd',
      );
    });

    test('GET bucket lifecycle (valueless query parameter)', () {
      final h = signer.sign(
        method: 'GET',
        uri: Uri.parse('$host/?lifecycle'),
        headers: {'x-amz-content-sha256': emptyPayloadHash},
        payloadHash: emptyPayloadHash,
        now: now,
      );
      expect(
        signatureOf(h),
        'fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543',
      );
    });

    test('list objects (query parameters are sorted)', () {
      final h = signer.sign(
        method: 'GET',
        uri: Uri.parse('$host/?max-keys=2&prefix=J'),
        headers: {'x-amz-content-sha256': emptyPayloadHash},
        payloadHash: emptyPayloadHash,
        now: now,
      );
      expect(
        signatureOf(h),
        '34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7',
      );
    });
  });

  test('never emits checksum or chunked headers', () {
    const signer = SigV4Signer(S3Credentials('HFAKTEST', 'secret'));
    final h = signer.sign(
      method: 'PUT',
      uri: Uri.parse('https://s3.hf.co/me/bucket/v1/o/ab/cd'),
      headers: {'x-amz-content-sha256': emptyPayloadHash},
      payloadHash: emptyPayloadHash,
      now: DateTime.utc(2026),
    );
    expect(h.keys.where((k) => k.contains('checksum')), isEmpty);
    expect(h.values.where((v) => v.contains('aws-chunked')), isEmpty);
  });
}
