import 'dart:async';
import 'dart:io' show SocketException;
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import 'sigv4.dart';

class S3Exception implements Exception {
  final int statusCode;
  final String code;
  final String message;
  S3Exception(this.statusCode, this.code, this.message);

  bool get isPreconditionFailed => statusCode == 412 || statusCode == 409;
  bool get isNotFound => statusCode == 404;
  bool get isAuth => statusCode == 401 || statusCode == 403;

  /// A message that is safe and useful to show in the UI.
  String get friendly => switch (statusCode) {
    401 || 403 =>
      'Access denied. Check your access key and secret, and that the token '
          'they came from has write access to this bucket.',
    404 => 'Bucket or file not found.',
    429 => 'Hugging Face is busy right now. Try again in a minute.',
    _ =>
      'Hugging Face storage error ($statusCode${code.isEmpty ? '' : ' $code'}).',
  };

  @override
  String toString() => 'S3Exception($statusCode, $code, $message)';
}

class ObjectInfo {
  final String key;
  final int size;
  final DateTime? lastModified;
  final String? etag;
  const ObjectInfo(this.key, this.size, {this.lastModified, this.etag});
}

class RetryPolicy {
  final int maxAttempts;
  final Duration baseDelay;
  final Duration maxDelay;
  const RetryPolicy({
    this.maxAttempts = 5,
    this.baseDelay = const Duration(milliseconds: 400),
    this.maxDelay = const Duration(seconds: 20),
  });

  static const none = RetryPolicy(maxAttempts: 1);

  Duration delayFor(int attempt, Random random) {
    final exp = baseDelay * pow(2, attempt).toInt();
    final capped = exp > maxDelay ? maxDelay : exp;
    // Full jitter: spread retries from several devices apart.
    return capped * (0.5 + random.nextDouble() / 2);
  }
}

final _namePattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$');

/// A client for one Hugging Face Storage Bucket, through the S3-compatible
/// gateway at `https://s3.hf.co/<namespace>`.
class BucketClient {
  final String namespace;
  final String bucket;
  final SigV4Signer signer;
  final http.Client _http;
  final Uri endpoint;
  final RetryPolicy retry;
  final DateTime Function() clock;
  final Future<void> Function(Duration) sleep;
  final Random _random = Random();

  BucketClient({
    required this.namespace,
    required this.bucket,
    required S3Credentials credentials,
    http.Client? client,
    Uri? endpoint,
    this.retry = const RetryPolicy(),
    DateTime Function()? clock,
    Future<void> Function(Duration)? sleep,
  }) : signer = SigV4Signer(credentials),
       _http = client ?? http.Client(),
       endpoint = endpoint ?? Uri.parse('https://s3.hf.co'),
       clock = clock ?? DateTime.now,
       sleep = sleep ?? Future.delayed {
    if (!_namePattern.hasMatch(namespace)) {
      throw ArgumentError('Invalid Hugging Face username: $namespace');
    }
    if (!_namePattern.hasMatch(bucket)) {
      throw ArgumentError('Invalid bucket name: $bucket');
    }
  }

  void close() => _http.close();

  /// Hugging Face bucket keys are stricter than S3's.
  static void validateKey(String key) {
    final bad =
        key.isEmpty ||
        key.startsWith('/') ||
        key.endsWith('/') ||
        key.contains('//') ||
        key.contains('../') ||
        key.startsWith('./') ||
        key.endsWith('..') ||
        key.contains(r'\') ||
        key.contains('\u0000');
    if (bad) throw ArgumentError('Invalid object key: $key');
  }

  Uri _uri({String? key, Map<String, String> query = const {}}) {
    final segments = [namespace, bucket, if (key != null) ...key.split('/')];
    final path = segments.map(SigV4Signer.rfc3986).join('/');
    final base = endpoint.toString().replaceAll(RegExp(r'/+$'), '');
    final q = query.entries
        .map(
          (e) =>
              '${SigV4Signer.rfc3986(e.key)}=${SigV4Signer.rfc3986(e.value)}',
        )
        .join('&');
    return Uri.parse('$base/$path${q.isEmpty ? '' : '?$q'}');
  }

  // ---------------------------------------------------------------- bucket

  /// True if the bucket exists and these credentials can reach it.
  Future<bool> bucketExists() async {
    final r = await _send('HEAD', _uri());
    if (r.statusCode == 404) return false;
    _check(r);
    return true;
  }

  Future<void> createBucket() async {
    _check(await _send('PUT', _uri()));
  }

  /// Makes an unsigned listing request. If it succeeds, anyone on the internet
  /// can list this bucket, which means it was created or switched to public.
  Future<bool> isPubliclyListable() async {
    final r = await _http
        .get(_uri(query: {'list-type': '2', 'max-keys': '1'}))
        .timeout(const Duration(seconds: 30));
    return r.statusCode >= 200 && r.statusCode < 300;
  }

  /// Makes an unsigned request for one object. Listing and reads normally flip
  /// together on Hugging Face, but the wrapped master key is the object an
  /// attacker actually wants, so it is worth asking for directly rather than
  /// inferring its reachability from the listing check.
  Future<bool> isObjectPubliclyReadable(String key) async {
    validateKey(key);
    final r = await _http
        .get(_uri(key: key))
        .timeout(const Duration(seconds: 30));
    return r.statusCode >= 200 && r.statusCode < 300;
  }

  /// True if anyone without credentials can reach this bucket's contents,
  /// either by listing it or by fetching [probeKey] straight out of it.
  ///
  /// A [probeKey] that does not exist yet answers 404 even on a public bucket,
  /// so for a brand-new library the listing check is the one that decides.
  Future<bool> isPubliclyExposed({String? probeKey}) async {
    if (await isPubliclyListable()) return true;
    if (probeKey == null) return false;
    return isObjectPubliclyReadable(probeKey);
  }

  // --------------------------------------------------------------- objects

  /// Uploads [bytes] to [key] and returns the new ETag.
  ///
  /// [ifNoneMatch] `'*'` refuses to overwrite an existing object; [ifMatch]
  /// only overwrites the given version. Both throw an [S3Exception] whose
  /// [S3Exception.isPreconditionFailed] is true when the condition fails.
  ///
  /// [onSent] is called as the body goes out, which is the only sign of life
  /// a large file gives: one upload is one request, so without it a 200 MB
  /// video looks frozen for minutes. A retry starts its count again from 0.
  Future<String?> putObject(
    String key,
    Uint8List bytes, {
    String contentType = 'application/octet-stream',
    String? ifNoneMatch,
    String? ifMatch,
    void Function(int sent, int total)? onSent,
  }) async {
    validateKey(key);
    final r = await _send(
      'PUT',
      _uri(key: key),
      body: bytes,
      headers: {
        'content-type': contentType,
        'if-none-match': ?ifNoneMatch,
        'if-match': ?ifMatch,
      },
      onSent: onSent,
    );
    _check(r);
    return r.headers['etag'];
  }

  /// Downloads [key]. The gateway usually answers with a redirect to a CDN;
  /// that hop is followed without the Authorization header.
  ///
  /// [onReceived] is called as the bytes arrive, so a viewer can show a real
  /// bar while a video comes down. `total` is null if the server won't say.
  ///
  /// A download is retried as a whole — request and body together — because
  /// a stream that dies half way through is the usual way a big file fails,
  /// and half a file is no use. The bar goes back to zero when that happens.
  Future<Uint8List> getObject(
    String key, {
    void Function(int received, int? total)? onReceived,
  }) async {
    validateKey(key);
    for (var attempt = 0; ; attempt++) {
      final last = attempt + 1 >= retry.maxAttempts;
      try {
        return await _download(key, onReceived);
      } on _Retryable catch (e) {
        if (last) throw e.error;
        await sleep(e.after ?? retry.delayFor(attempt, _random));
        continue;
      } on SocketException {
        if (last) rethrow;
      } on TimeoutException {
        if (last) rethrow;
      } on http.ClientException {
        if (last) rethrow;
      }
      await sleep(retry.delayFor(attempt, _random));
    }
  }

  Future<Uint8List> _download(
    String key,
    void Function(int received, int? total)? onReceived,
  ) async {
    var current = _uri(key: key);
    // One attempt each: the loop above owns the retrying.
    var r = await _stream(
      'GET',
      current,
      followRedirects: false,
      retries: false,
    );
    for (var hop = 0; hop < 5 && _isRedirect(r.statusCode); hop++) {
      await r.stream.drain<void>();
      final location = r.headers['location'];
      if (location == null) {
        throw S3Exception(
          r.statusCode,
          'MissingLocation',
          'Redirect without location',
        );
      }
      final next = current = current.resolve(location);
      if (next.scheme != 'https') {
        throw S3Exception(r.statusCode, 'InsecureRedirect', 'Refusing $next');
      }
      // Credentials are never forwarded to the storage host.
      final req = http.Request('GET', next)..followRedirects = false;
      r = await _http.send(req).timeout(const Duration(seconds: 60));
    }
    if (r.statusCode < 200 || r.statusCode >= 300) {
      // An error body is small; read it so the message says what went wrong.
      final response = await http.Response.fromStream(r);
      final error = _errorOf(response);
      throw _worthRetrying(response.statusCode)
          ? _Retryable(error, _retryAfter(response))
          : error;
    }
    return _collect(r, onReceived);
  }

  /// Reads a response body, reporting as it goes. The timeout is per chunk,
  /// so a slow but moving download is never cut off.
  static Future<Uint8List> _collect(
    http.StreamedResponse response,
    void Function(int received, int? total)? onReceived,
  ) async {
    final total = response.contentLength;
    final builder = BytesBuilder(copy: false);
    onReceived?.call(0, total);
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 60),
    )) {
      builder.add(chunk);
      onReceived?.call(builder.length, total);
    }
    return builder.takeBytes();
  }

  Future<ObjectInfo?> headObject(String key) async {
    validateKey(key);
    final r = await _send('HEAD', _uri(key: key), followRedirects: false);
    if (r.statusCode == 404) return null;
    if (!_isRedirect(r.statusCode)) _check(r);
    return ObjectInfo(
      key,
      int.tryParse(r.headers['content-length'] ?? '') ?? 0,
      etag: r.headers['etag'],
    );
  }

  Future<void> deleteObject(String key) async {
    validateKey(key);
    final r = await _send('DELETE', _uri(key: key));
    if (r.statusCode == 404) return;
    _check(r);
  }

  /// The buckets in this namespace, or null when the gateway won't say.
  ///
  /// Hugging Face documents ListObjectsV2 but not ListBuckets, so this is a
  /// best effort: a refusal, a network hiccup or an unexpected body all mean
  /// "unknown", never "the namespace has no other buckets".
  Future<List<String>?> listBuckets() async {
    final base = endpoint.toString().replaceAll(RegExp(r'/+$'), '');
    final http.Response response;
    try {
      response = await _send(
        'GET',
        Uri.parse('$base/${SigV4Signer.rfc3986(namespace)}'),
      );
      if (response.statusCode != 200) return null;
      final doc = XmlDocument.parse(response.body);
      final names = [
        for (final b in doc.findAllElements('Bucket'))
          if (b.getElement('Name')?.innerText case final name?)
            if (name.isNotEmpty) name,
      ];
      return names.isEmpty ? null : names;
    } catch (_) {
      return null;
    }
  }

  /// Lists every object under [prefix], following continuation tokens.
  ///
  /// With a [limit], stops after the page that reaches it, so measuring a
  /// huge bucket can't run forever.
  Future<List<ObjectInfo>> listObjects({String prefix = '', int? limit}) async {
    final out = <ObjectInfo>[];
    String? token;
    do {
      final r = await _send(
        'GET',
        _uri(
          query: {
            'list-type': '2',
            if (prefix.isNotEmpty) 'prefix': prefix,
            'continuation-token': ?token,
          },
        ),
      );
      _check(r);
      final doc = XmlDocument.parse(r.body);
      for (final c in doc.findAllElements('Contents')) {
        String? text(String name) => c.getElement(name)?.innerText;
        out.add(
          ObjectInfo(
            text('Key')!,
            int.tryParse(text('Size') ?? '') ?? 0,
            lastModified: DateTime.tryParse(text('LastModified') ?? ''),
            etag: text('ETag'),
          ),
        );
      }
      final truncated =
          doc.findAllElements('IsTruncated').firstOrNull?.innerText == 'true';
      token = truncated
          ? doc.findAllElements('NextContinuationToken').firstOrNull?.innerText
          : null;
    } while (token != null &&
        token.isNotEmpty &&
        (limit == null || out.length < limit));
    return out;
  }

  // -------------------------------------------------------------- plumbing

  static bool _isRedirect(int status) =>
      const [301, 302, 303, 307, 308].contains(status);

  Future<http.Response> _send(
    String method,
    Uri uri, {
    Uint8List? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    void Function(int sent, int total)? onSent,
  }) async {
    final timeout = _timeoutFor(body?.length ?? 0);
    return http.Response.fromStream(
      await _stream(
        method,
        uri,
        body: body,
        headers: headers,
        followRedirects: followRedirects,
        onSent: onSent,
      ),
    ).timeout(timeout);
  }

  /// Signs, sends and retries, handing back the response before its body has
  /// been read — which is what lets a download report progress.
  Future<http.StreamedResponse> _stream(
    String method,
    Uri uri, {
    Uint8List? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    void Function(int sent, int total)? onSent,
    bool retries = true,
  }) {
    final payload = body ?? Uint8List(0);
    final payloadHash = body == null ? emptyPayloadHash : sha256Hex(payload);
    final timeout = _timeoutFor(payload.length);
    Future<http.StreamedResponse> send() async {
      // Each attempt gets its own request, so a retry sends the body again
      // from the beginning and reports it again from zero.
      final req = _BodyRequest(method, uri, payload, onSent)
        ..followRedirects = followRedirects;
      req.headers.addAll(
        signer.sign(
          method: method,
          uri: uri,
          headers: {...headers, 'x-amz-content-sha256': payloadHash},
          payloadHash: payloadHash,
          now: clock(),
        ),
      );
      return _http.send(req).timeout(timeout);
    }

    return retries ? _withRetry(send) : send();
  }

  /// Allow slow mobile uplinks: a minute plus ~50 KB/s.
  static Duration _timeoutFor(int bytes) =>
      Duration(seconds: 60 + bytes ~/ 50000);

  static bool _worthRetrying(int status) =>
      const [429, 500, 502, 503, 504].contains(status);

  /// What the server asked us to wait, when it asked for something sane.
  static Duration? _retryAfter(http.BaseResponse r) {
    final seconds = int.tryParse(r.headers['retry-after'] ?? '');
    return seconds != null && seconds <= 60 ? Duration(seconds: seconds) : null;
  }

  Future<http.StreamedResponse> _withRetry(
    Future<http.StreamedResponse> Function() run,
  ) async {
    for (var attempt = 0; ; attempt++) {
      final last = attempt + 1 >= retry.maxAttempts;
      try {
        final r = await run();
        if (!last && _worthRetrying(r.statusCode)) {
          // Let go of the body before asking again.
          await r.stream.drain<void>();
          await sleep(_retryAfter(r) ?? retry.delayFor(attempt, _random));
          continue;
        }
        return r;
      } on SocketException {
        if (last) rethrow;
      } on TimeoutException {
        if (last) rethrow;
      } on http.ClientException {
        if (last) rethrow;
      }
      await sleep(retry.delayFor(attempt, _random));
    }
  }

  void _check(http.Response r) {
    if (r.statusCode >= 200 && r.statusCode < 300) return;
    throw _errorOf(r);
  }

  S3Exception _errorOf(http.Response r) {
    var code = '', message = '';
    try {
      final error = XmlDocument.parse(
        r.body,
      ).findAllElements('Error').firstOrNull;
      code = error?.getElement('Code')?.innerText ?? '';
      message = error?.getElement('Message')?.innerText ?? '';
    } catch (_) {
      // Not an XML error body.
    }
    return S3Exception(r.statusCode, code, message);
  }
}

/// A download that failed in a way worth trying again, with what the server
/// asked us to wait and the error to report if we run out of goes.
class _Retryable implements Exception {
  final S3Exception error;
  final Duration? after;
  const _Retryable(this.error, this.after);
}

/// A request whose body is handed over in chunks, so the caller can watch it
/// leave. [http.Request] finalizes to a single blob and says nothing.
class _BodyRequest extends http.BaseRequest {
  final Uint8List body;
  final void Function(int sent, int total)? onSent;

  /// 64 KiB: small enough that the bar moves on a slow uplink, large enough
  /// that the callback isn't the expensive part of an upload.
  static const _chunk = 64 * 1024;

  _BodyRequest(super.method, super.url, this.body, this.onSent) {
    contentLength = body.length;
  }

  @override
  http.ByteStream finalize() {
    super.finalize();
    return http.ByteStream(_chunks());
  }

  Stream<List<int>> _chunks() async* {
    if (body.isEmpty) return;
    for (var start = 0; start < body.length; start += _chunk) {
      final end = start + _chunk > body.length ? body.length : start + _chunk;
      yield Uint8List.sublistView(body, start, end);
      onSent?.call(end, body.length);
    }
  }
}
