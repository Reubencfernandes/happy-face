import 'dart:typed_data';

import 'package:happy_drive/s3/s3_client.dart';
import 'package:happy_drive/s3/sigv4.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// An in-memory stand-in for a Hugging Face bucket behind the S3 gateway.
/// Honors `If-None-Match: *`, paginates listings and counts requests.
class FakeBucket {
  final Map<String, Uint8List> objects = {};
  final List<String> log = [];
  int pageSize;

  /// Called before each request; return a response to inject a failure.
  http.Response? Function(http.Request request)? intercept;

  /// When true, unsigned requests may list the bucket (a public bucket).
  bool public;

  FakeBucket({this.pageSize = 1000, this.public = false});

  static const _prefix = '/reuben/happy-drive';

  int count(String method) => log.where((l) => l.startsWith('$method ')).length;

  BucketClient client([Object? _]) => BucketClient(
    namespace: 'reuben',
    bucket: 'happy-drive',
    credentials: const S3Credentials('HFAKTEST', 'secret'),
    client: MockClient(_handle),
    sleep: (_) async {},
  );

  Future<http.Response> _handle(http.Request r) async {
    final injected = intercept?.call(r);
    if (injected != null) return injected;
    if (!r.headers.containsKey('authorization') && !public) {
      return http.Response('<Error><Code>AccessDenied</Code></Error>', 403);
    }
    final path = Uri.decodeComponent(r.url.path);
    if (!path.startsWith(_prefix)) return http.Response('', 404);
    final key = path.length > _prefix.length + 1
        ? path.substring(_prefix.length + 1)
        : '';
    log.add('${r.method} $key');

    if (key.isEmpty) {
      if (r.method == 'HEAD' || r.method == 'PUT') {
        return http.Response('', 200);
      }
      return _list(r.url.queryParameters);
    }
    switch (r.method) {
      case 'PUT':
        if (r.headers['if-none-match'] == '*' && objects.containsKey(key)) {
          return http.Response(
            '<Error><Code>PreconditionFailed</Code></Error>',
            412,
          );
        }
        objects[key] = r.bodyBytes;
        return http.Response('', 200, headers: {'etag': '"${key.hashCode}"'});
      case 'GET':
        final data = objects[key];
        return data == null
            ? http.Response('<Error><Code>NoSuchKey</Code></Error>', 404)
            : http.Response.bytes(data, 200);
      case 'HEAD':
        final data = objects[key];
        return http.Response(
          '',
          data == null ? 404 : 200,
          headers: {'content-length': '${data?.length ?? 0}'},
        );
      case 'DELETE':
        objects.remove(key);
        return http.Response('', 204);
    }
    return http.Response('', 405);
  }

  http.Response _list(Map<String, String> q) {
    final prefix = q['prefix'] ?? '';
    final keys = objects.keys.where((k) => k.startsWith(prefix)).toList()
      ..sort();
    final start = int.tryParse(q['continuation-token'] ?? '') ?? 0;
    final page = keys.skip(start).take(pageSize).toList();
    final truncated = start + page.length < keys.length;
    final body = StringBuffer('<ListBucketResult>')
      ..write('<IsTruncated>$truncated</IsTruncated>');
    if (truncated) {
      body.write(
        '<NextContinuationToken>${start + page.length}</NextContinuationToken>',
      );
    }
    for (final k in page) {
      body.write(
        '<Contents><Key>$k</Key><Size>${objects[k]!.length}</Size></Contents>',
      );
    }
    body.write('</ListBucketResult>');
    return http.Response(body.toString(), 200);
  }
}
