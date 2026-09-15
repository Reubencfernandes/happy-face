import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// AWS-style credentials. For Hugging Face these are the `HFAK…` access key
/// and its secret, generated from a user access token.
class S3Credentials {
  final String accessKeyId;
  final String secretAccessKey;
  const S3Credentials(this.accessKeyId, this.secretAccessKey);
}

/// SHA-256 of an empty body, used for GET/HEAD/DELETE requests.
const emptyPayloadHash =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

final _unreserved = RegExp(r'[A-Za-z0-9\-_.~]');

/// Signs HTTP requests with AWS Signature Version 4.
///
/// Deliberately never adds `x-amz-checksum-*` or `aws-chunked` framing: the
/// Hugging Face S3 gateway does not parse them.
class SigV4Signer {
  final S3Credentials credentials;
  final String region;
  final String service;
  const SigV4Signer(
    this.credentials, {
    this.region = 'us-east-1',
    this.service = 's3',
  });

  /// Returns [headers] plus `host`, `x-amz-date` and `authorization`.
  ///
  /// Every header passed in is signed. S3 callers add `x-amz-content-sha256`
  /// themselves.
  Map<String, String> sign({
    required String method,
    required Uri uri,
    Map<String, String> headers = const {},
    required String payloadHash,
    required DateTime now,
  }) {
    final all = <String, String>{
      for (final e in headers.entries) e.key.toLowerCase(): e.value,
    };
    all['host'] = _hostHeader(uri);
    all.putIfAbsent('x-amz-date', () => _amzDate(now.toUtc()));
    final amzDate = all['x-amz-date']!;
    final date = amzDate.substring(0, 8);

    final names = all.keys.toList()..sort();
    final canonicalHeaders =
        names.map((n) => '$n:${_trimHeader(all[n]!)}\n').join();
    final signedHeaders = names.join(';');
    final canonicalRequest = [
      method.toUpperCase(),
      canonicalPath(uri),
      canonicalQuery(uri),
      canonicalHeaders,
      signedHeaders,
      payloadHash,
    ].join('\n');

    final scope = '$date/$region/$service/aws4_request';
    final stringToSign = [
      'AWS4-HMAC-SHA256',
      amzDate,
      scope,
      sha256Hex(utf8.encode(canonicalRequest)),
    ].join('\n');

    var key = _hmac(
      utf8.encode('AWS4${credentials.secretAccessKey}'),
      utf8.encode(date),
    );
    for (final part in [region, service, 'aws4_request']) {
      key = _hmac(key, utf8.encode(part));
    }
    final signature = _hex(_hmac(key, utf8.encode(stringToSign)));

    return {
      ...headers,
      'host': all['host']!,
      'x-amz-date': amzDate,
      'authorization':
          'AWS4-HMAC-SHA256 Credential=${credentials.accessKeyId}/$scope, '
          'SignedHeaders=$signedHeaders, Signature=$signature',
    };
  }

  /// S3 canonical URI: each segment decoded, then encoded exactly once.
  static String canonicalPath(Uri uri) {
    final path = uri.path.isEmpty ? '/' : uri.path;
    return path
        .split('/')
        .map((s) => rfc3986(Uri.decodeComponent(s)))
        .join('/');
  }

  static String canonicalQuery(Uri uri) {
    if (uri.query.isEmpty) return '';
    final pairs = <List<String>>[];
    for (final part in uri.query.split('&')) {
      if (part.isEmpty) continue;
      final i = part.indexOf('=');
      final k = Uri.decodeQueryComponent(i < 0 ? part : part.substring(0, i));
      final v = i < 0 ? '' : Uri.decodeQueryComponent(part.substring(i + 1));
      pairs.add([rfc3986(k), rfc3986(v)]);
    }
    pairs.sort(
      (a, b) => a[0] == b[0] ? a[1].compareTo(b[1]) : a[0].compareTo(b[0]),
    );
    return pairs.map((p) => '${p[0]}=${p[1]}').join('&');
  }

  /// Percent-encodes everything except RFC 3986 unreserved characters.
  static String rfc3986(String input) {
    final out = StringBuffer();
    for (final byte in utf8.encode(input)) {
      final c = String.fromCharCode(byte);
      if (byte < 128 && _unreserved.hasMatch(c)) {
        out.write(c);
      } else {
        out.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
    return out.toString();
  }

  static String _hostHeader(Uri uri) {
    final defaultPort = (uri.scheme == 'https' && uri.port == 443) ||
        (uri.scheme == 'http' && uri.port == 80);
    return uri.hasPort && !defaultPort ? '${uri.host}:${uri.port}' : uri.host;
  }

  static String _amzDate(DateTime utc) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${utc.year.toString().padLeft(4, '0')}${two(utc.month)}'
        '${two(utc.day)}T${two(utc.hour)}${two(utc.minute)}${two(utc.second)}Z';
  }

  static String _trimHeader(String v) =>
      v.trim().replaceAll(RegExp(r'\s+'), ' ');

  static Uint8List _hmac(List<int> key, List<int> data) =>
      Uint8List.fromList(Hmac(sha256, key).convert(data).bytes);

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
