import 'dart:convert';
import 'dart:io' show SocketException;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:happy_drive/s3/s3_client.dart';
import 'package:happy_drive/s3/sigv4.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

BucketClient clientWith(
  Future<http.Response> Function(http.Request) handler, {
  List<Duration>? sleeps,
  RetryPolicy retry = const RetryPolicy(),
}) => BucketClient(
  namespace: 'reuben',
  bucket: 'happy-drive',
  credentials: const S3Credentials('HFAKTEST', 'secret'),
  client: MockClient(handler),
  retry: retry,
  clock: () => DateTime.utc(2026, 9, 15),
  sleep: (d) async => sleeps?.add(d),
);

void main() {
  test(
    'addresses objects path-style under the namespace and signs them',
    () async {
      late http.Request seen;
      final c = clientWith((r) async {
        seen = r;
        return http.Response('', 200, headers: {'etag': '"abc"'});
      });
      final etag = await c.putObject(
        'v1/o/ab/cdef',
        Uint8List.fromList([1, 2, 3]),
      );
      expect(etag, '"abc"');
      expect(seen.method, 'PUT');
      expect(
        seen.url.toString(),
        'https://s3.hf.co/reuben/happy-drive/v1/o/ab/cdef',
      );
      expect(
        seen.headers['authorization'],
        startsWith(
          'AWS4-HMAC-SHA256 Credential=HFAKTEST/20260915/us-east-1/s3/',
        ),
      );
      expect(seen.headers['x-amz-content-sha256'], sha256Hex([1, 2, 3]));
      expect(seen.bodyBytes, [1, 2, 3]);
    },
  );

  test('conditional writes send the precondition and surface a 412', () async {
    final c = clientWith((r) async {
      expect(r.headers['if-none-match'], '*');
      return http.Response(
        '<Error><Code>PreconditionFailed</Code><Message>exists</Message></Error>',
        412,
      );
    });
    await expectLater(
      c.putObject('v1/keys', Uint8List(1), ifNoneMatch: '*'),
      throwsA(
        isA<S3Exception>().having(
          (e) => e.isPreconditionFailed,
          'precondition',
          true,
        ),
      ),
    );
  });

  test(
    'downloads follow the CDN redirect without forwarding credentials',
    () async {
      final requests = <http.Request>[];
      final c = clientWith((r) async {
        requests.add(r);
        if (r.url.host == 's3.hf.co') {
          return http.Response(
            '',
            302,
            headers: {'location': 'https://cdn.example.com/blob?sig=1'},
          );
        }
        return http.Response.bytes([9, 8, 7], 200);
      });
      expect(await c.getObject('v1/t/ab/cd'), [9, 8, 7]);
      expect(requests, hasLength(2));
      expect(requests.first.headers.containsKey('authorization'), isTrue);
      expect(requests.last.url.host, 'cdn.example.com');
      expect(
        requests.last.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains('authorization')),
      );
    },
  );

  test('refuses insecure redirects', () async {
    final c = clientWith(
      (r) async => http.Response(
        '',
        302,
        headers: {'location': 'http://cdn.example.com/x'},
      ),
    );
    await expectLater(c.getObject('v1/t/ab/cd'), throwsA(isA<S3Exception>()));
  });

  test('listing follows continuation tokens', () async {
    final tokens = <String?>[];
    final c = clientWith((r) async {
      final token = r.url.queryParameters['continuation-token'];
      tokens.add(token);
      expect(r.url.queryParameters['prefix'], 'v1/j/');
      final page = token == null
          ? '<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
                '<IsTruncated>true</IsTruncated><NextContinuationToken>a+b/c=</NextContinuationToken>'
                '<Contents><Key>v1/j/1</Key><Size>10</Size><LastModified>2026-09-15T10:00:00.000Z</LastModified><ETag>"e1"</ETag></Contents>'
                '</ListBucketResult>'
          : '<ListBucketResult><IsTruncated>false</IsTruncated>'
                '<Contents><Key>v1/j/2</Key><Size>20</Size></Contents></ListBucketResult>';
      return http.Response(page, 200);
    });
    final items = await c.listObjects(prefix: 'v1/j/');
    expect(items.map((i) => i.key), ['v1/j/1', 'v1/j/2']);
    expect(items.first.size, 10);
    expect(items.first.lastModified, DateTime.utc(2026, 9, 15, 10));
    expect(tokens, [null, 'a+b/c=']);
  });

  test(
    'retries throttling and server errors with backoff, then succeeds',
    () async {
      var calls = 0;
      final sleeps = <Duration>[];
      final c = clientWith((r) async {
        calls++;
        if (calls == 1) {
          return http.Response('', 429, headers: {'retry-after': '2'});
        }
        if (calls == 2) return http.Response('', 503);
        if (calls == 3) throw const SocketException('offline');
        return http.Response('', 200);
      }, sleeps: sleeps);
      await c.deleteObject('v1/o/ab/cd');
      expect(calls, 4);
      expect(sleeps.first, const Duration(seconds: 2));
      expect(sleeps, hasLength(3));
    },
  );

  test('gives up after the maximum attempts', () async {
    var calls = 0;
    final c = clientWith((r) async {
      calls++;
      return http.Response('', 500);
    }, retry: const RetryPolicy(maxAttempts: 3));
    await expectLater(
      c.deleteObject('v1/o/ab/cd'),
      throwsA(isA<S3Exception>()),
    );
    expect(calls, 3);
  });

  test('bucket existence and public-listing check', () async {
    final c = clientWith((r) async {
      if (r.method == 'HEAD') return http.Response('', 404);
      final signed = r.headers.containsKey('authorization');
      return http.Response('<ListBucketResult/>', signed ? 200 : 403);
    });
    expect(await c.bucketExists(), isFalse);
    expect(await c.isPubliclyListable(), isFalse);
  });

  test(
    'public exposure: an unsigned read counts even when listing is denied',
    () async {
      final c = clientWith((r) async {
        final signed = r.headers.containsKey('authorization');
        // Listing is locked down, but the key envelope is served to anyone.
        if (r.url.queryParameters.containsKey('list-type')) {
          return http.Response('', signed ? 200 : 403);
        }
        return http.Response('{"format":"happydrive-keys"}', 200);
      });
      expect(await c.isPubliclyListable(), isFalse);
      expect(await c.isPubliclyExposed(probeKey: 'v1/keys'), isTrue);
    },
  );

  test(
    'public exposure: a listable bucket is caught before the probe',
    () async {
      var unsignedReads = 0;
      final c = clientWith((r) async {
        if (r.url.queryParameters.containsKey('list-type')) {
          return http.Response('<ListBucketResult/>', 200);
        }
        if (!r.headers.containsKey('authorization')) unsignedReads++;
        return http.Response('', 404);
      });
      // A brand-new public bucket has no key envelope yet, so the listing
      // check is the one that has to catch it.
      expect(await c.isPubliclyExposed(probeKey: 'v1/keys'), isTrue);
      expect(unsignedReads, 0, reason: 'listing already settled it');
    },
  );

  test('public exposure: a private bucket reports clean', () async {
    final c = clientWith((r) async {
      return r.headers.containsKey('authorization')
          ? http.Response('<ListBucketResult/>', 200)
          : http.Response('', 403);
    });
    expect(await c.isPubliclyExposed(probeKey: 'v1/keys'), isFalse);
  });

  test('an upload reports its body going out, in order', () async {
    final sent = <(int, int)>[];
    late int received;
    final c = clientWith((r) async {
      received = r.bodyBytes.length;
      return http.Response('', 200, headers: {'etag': '"abc"'});
    });
    // Bigger than one chunk, so there is more than one report to make.
    final body = Uint8List(200 * 1024);
    await c.putObject('v1/o/ab/one', body, onSent: (n, t) => sent.add((n, t)));

    expect(received, body.length, reason: 'the whole body still arrives');
    expect(sent, isNotEmpty);
    expect(sent.map((e) => e.$2), everyElement(body.length));
    expect(
      sent.map((e) => e.$1),
      orderedEquals(List.of(sent.map((e) => e.$1))..sort()),
    );
    expect(sent.last.$1, body.length);
  });

  test(
    'a download reports its bytes, with the size when the server says',
    () async {
      final got = <(int, int?)>[];
      final body = Uint8List.fromList(List.filled(40000, 3));
      final c = clientWith((r) async => http.Response.bytes(body, 200));
      final bytes = await c.getObject(
        'v1/o/ab/one',
        onReceived: (n, t) {
          got.add((n, t));
        },
      );

      expect(bytes, body);
      expect(got.first, (0, body.length));
      expect(got.last.$1, body.length);
    },
  );

  test('a retried download still returns the whole body', () async {
    var attempts = 0;
    final body = Uint8List.fromList(List.filled(1000, 7));
    final sleeps = <Duration>[];
    final c = clientWith((r) async {
      attempts++;
      if (attempts == 1) {
        return http.Response('busy', 503, headers: {'retry-after': '3'});
      }
      if (attempts == 2) throw const SocketException('dropped');
      return http.Response.bytes(body, 200);
    }, sleeps: sleeps);

    expect(await c.getObject('v1/o/ab/one'), body);
    expect(attempts, 3);
    expect(sleeps.first, const Duration(seconds: 3));
    expect(sleeps, hasLength(2));
  });

  test('a download that dies half way through starts again', () async {
    var attempts = 0;
    final body = Uint8List.fromList(List.filled(1000, 5));
    final progress = <int>[];
    final c = BucketClient(
      namespace: 'reuben',
      bucket: 'happy-drive',
      credentials: const S3Credentials('HFAKTEST', 'secret'),
      clock: () => DateTime.utc(2026, 9, 15),
      sleep: (_) async {},
      client: MockClient.streaming((request, _) async {
        attempts++;
        // The first go hands over half the file and then breaks.
        final stream = attempts == 1 ? _brokenStream(body) : _wholeStream(body);
        return http.StreamedResponse(stream, 200, contentLength: body.length);
      }),
    );

    final got = await c.getObject(
      'v1/o/ab/one',
      onReceived: (n, _) => progress.add(n),
    );
    expect(got, body, reason: 'half a file is no use');
    expect(attempts, 2);
    // The bar goes back to zero for the second attempt, which is honest.
    expect(progress, contains(400));
    expect(progress.last, body.length);
  });

  test('rejects keys the Hugging Face gateway forbids', () {
    for (final key in [
      '/a',
      'a/',
      'a//b',
      'a/../b',
      './a',
      'a..',
      r'a\b',
      'a\u0000b',
      '',
    ]) {
      expect(
        () => BucketClient.validateKey(key),
        throwsArgumentError,
        reason: key,
      );
    }
    BucketClient.validateKey('v1/o/ab/0123abcd');
  });

  test('auth failures produce a friendly message', () async {
    final c = clientWith(
      (r) async => http.Response(
        utf8.decode(utf8.encode('<Error><Code>AccessDenied</Code></Error>')),
        403,
      ),
    );
    await expectLater(
      c.bucketExists(),
      throwsA(
        isA<S3Exception>().having(
          (e) => e.friendly,
          'friendly',
          contains('Access denied'),
        ),
      ),
    );
  });
}

/// Hands over part of the file and then drops the connection.
Stream<List<int>> _brokenStream(Uint8List body) async* {
  yield body.sublist(0, 400);
  throw const SocketException('connection reset');
}

Stream<List<int>> _wholeStream(Uint8List body) async* {
  yield body;
}
