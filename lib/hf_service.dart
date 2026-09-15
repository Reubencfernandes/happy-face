import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

class DriveException implements Exception {
  final String message;
  DriveException(this.message);
  @override
  String toString() => message;
}

class Photo {
  final String path;
  final int size;
  Photo(this.path, this.size);
  String get name =>
      path.split('/').last.replaceFirst(RegExp(r'^[a-f0-9]{24}--'), '');
}

class HfService {
  final String repo;
  final String token;
  final http.Client client;
  HfService({required this.repo, required this.token, http.Client? client})
    : client = client ?? http.Client();
  Map<String, String> get auth => {'Authorization': 'Bearer $token'};
  Uri endpoint(String path) => Uri.https('huggingface.co', path);
  void close() => client.close();
  void check(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    throw DriveException(switch (response.statusCode) {
      401 || 403 => 'Access denied. Check your token and dataset permissions.',
      404 => 'Dataset or photo not found. Check the dataset name.',
      429 => 'Hugging Face is busy. Please try again shortly.',
      _ =>
        'Hugging Face request failed (${response.statusCode}). Please try again.',
    });
  }

  Future<dynamic> jsonPost(
    Uri uri,
    Object body, {
    String contentType = 'application/json',
  }) async {
    final response = await client
        .post(
          uri,
          headers: {
            ...auth,
            'Content-Type': contentType,
            if (contentType == 'application/vnd.git-lfs+json')
              'Accept': contentType,
          },
          body: contentType == 'application/x-ndjson' ? body : jsonEncode(body),
        )
        .timeout(const Duration(minutes: 3));
    check(response);
    return response.body.isEmpty ? null : jsonDecode(response.body);
  }

  Future<void> connect() async {
    if (!RegExp(r'^[\w-]+/[\w.-]+$').hasMatch(repo) ||
        !token.startsWith('hf_')) {
      throw DriveException(
        'Enter a dataset name like username/my-photos and an hf_ token.',
      );
    }
    final response = await client
        .get(endpoint('/api/datasets/$repo'), headers: auth)
        .timeout(const Duration(seconds: 30));
    check(response);
    if (jsonDecode(response.body)['private'] != true) {
      throw DriveException(
        'This dataset is public. Select a private dataset for your photos.',
      );
    }
  }

  Future<List<Photo>> listPhotos() async {
    await connect();
    Uri? page = endpoint(
      '/api/datasets/$repo/tree/main',
    ).replace(queryParameters: {'recursive': 'true', 'limit': '100'});
    final photos = <Photo>[];
    final seen = <String>{};
    while (page != null && seen.add(page.toString())) {
      if (page.scheme != 'https' || page.host != 'huggingface.co') {
        throw DriveException('Unexpected pagination URL.');
      }
      final response = await client
          .get(page, headers: auth)
          .timeout(const Duration(seconds: 30));
      check(response);
      for (final item in jsonDecode(response.body) as List) {
        final path = item['path'] as String;
        if (item['type'] == 'file' &&
            path.startsWith('photos/') &&
            RegExp(
              r'\.(jpe?g|png|webp|gif)$',
              caseSensitive: false,
            ).hasMatch(path)) {
          photos.add(Photo(path, item['size'] as int));
        }
      }
      final match = RegExp(
        r'<([^>]+)>;\s*rel="next"',
      ).firstMatch(response.headers['link'] ?? '');
      page = match == null ? null : Uri.parse(match.group(1)!);
    }
    photos.sort((a, b) => b.path.compareTo(a.path));
    return photos;
  }

  Future<Uint8List> download(Photo photo) async {
    if (!photo.path.startsWith('photos/') ||
        photo.path.split('/').contains('..')) {
      throw DriveException('Invalid photo path.');
    }
    Uri uri = endpoint('/datasets/$repo/resolve/main/${photo.path}');
    // Follow redirects explicitly; never forward the HF token to a storage host.
    for (var i = 0; i < 6; i++) {
      if (uri.scheme != 'https') {
        throw DriveException('Refusing an insecure download.');
      }
      final request = http.Request('GET', uri)..followRedirects = false;
      if (uri.host == 'huggingface.co') request.headers.addAll(auth);
      final stream = await client
          .send(request)
          .timeout(const Duration(seconds: 60));
      if ([301, 302, 303, 307, 308].contains(stream.statusCode)) {
        await stream.stream.drain<void>();
        final location = stream.headers['location'];
        if (location == null) {
          throw DriveException('Download redirect is missing.');
        }
        uri = uri.resolve(location);
        continue;
      }
      final response = await http.Response.fromStream(
        stream,
      ).timeout(const Duration(minutes: 3));
      check(response);
      return response.bodyBytes;
    }
    throw DriveException('Too many download redirects.');
  }

  static String imageExtension(Uint8List bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 255 &&
        bytes[1] == 216 &&
        bytes[2] == 255) {
      return 'jpg';
    }
    if (bytes.length >= 8 &&
        base64Encode(bytes.sublist(0, 8)) == 'iVBORw0KGgo=') {
      return 'png';
    }
    if (bytes.length >= 6 &&
        [
          'GIF87a',
          'GIF89a',
        ].contains(ascii.decode(bytes.sublist(0, 6), allowInvalid: true))) {
      return 'gif';
    }
    if (bytes.length >= 12 &&
        ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
        ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP') {
      return 'webp';
    }
    throw DriveException('Choose a JPEG, PNG, GIF, or WebP photo.');
  }

  Future<void> upload(String filename, Uint8List bytes) async {
    if (bytes.length > 25 * 1024 * 1024) {
      throw DriveException('Photos must be 25 MB or smaller.');
    }
    final ext = imageExtension(bytes);
    await connect();
    final random = Random.secure();
    final id = List.generate(
      12,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final stem = filename
        .replaceFirst(RegExp(r'\.[^.]*$'), '')
        .replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    final safeName = stem.isEmpty
        ? 'photo'
        : stem.substring(0, min(100, stem.length));
    final path =
        'photos/${DateTime.now().toUtc().toIso8601String().substring(0, 10)}/$id--$safeName.$ext';
    final pre = await jsonPost(endpoint('/api/datasets/$repo/preupload/main'), {
      'files': [
        {
          'path': path,
          'size': bytes.length,
          'sample': base64Encode(bytes.sublist(0, min(512, bytes.length))),
        },
      ],
    });
    final mode = pre['files'][0]['uploadMode'];
    Map<String, dynamic> operation;
    if (mode == 'lfs') {
      final oid = sha256.convert(bytes).toString();
      final batch = await jsonPost(
        endpoint('/datasets/$repo.git/info/lfs/objects/batch'),
        {
          'operation': 'upload',
          'transfers': ['basic'],
          'hash_algo': 'sha256',
          'objects': [
            {'oid': oid, 'size': bytes.length},
          ],
        },
        contentType: 'application/vnd.git-lfs+json',
      );
      final object = batch['objects'][0];
      if (object['error'] != null) {
        throw DriveException(
          'Hugging Face could not prepare the upload. Check your quota and permissions.',
        );
      }
      if (batch['transfer'] != null && batch['transfer'] != 'basic') {
        throw DriveException(
          'This upload requires an unsupported transfer mode.',
        );
      }
      final actions = object['actions'];
      if (actions?['upload'] != null) {
        final action = actions['upload'];
        final uri = Uri.parse(action['href']);
        if (uri.scheme != 'https') {
          throw DriveException('Refusing an insecure upload.');
        }
        final headers = Map<String, String>.from(action['header'] ?? {});
        check(
          await client
              .put(uri, headers: headers, body: bytes)
              .timeout(const Duration(minutes: 5)),
        );
      }
      if (actions?['verify'] != null) {
        final action = actions['verify'];
        final uri = Uri.parse(action['href']);
        if (uri.scheme != 'https') {
          throw DriveException('Refusing an insecure verification.');
        }
        check(
          await client
              .post(
                uri,
                headers: {
                  if (uri.host == 'huggingface.co') ...auth,
                  ...Map<String, String>.from(action['header'] ?? {}),
                  'Content-Type': 'application/json',
                },
                body: jsonEncode({'oid': oid, 'size': bytes.length}),
              )
              .timeout(const Duration(seconds: 60)),
        );
      }
      operation = {
        'key': 'lfsFile',
        'value': {
          'path': path,
          'algo': 'sha256',
          'oid': oid,
          'size': bytes.length,
        },
      };
    } else if (mode == 'regular') {
      operation = {
        'key': 'file',
        'value': {
          'path': path,
          'encoding': 'base64',
          'content': base64Encode(bytes),
        },
      };
    } else {
      throw DriveException('Unknown Hugging Face upload mode.');
    }
    await jsonPost(
      endpoint('/api/datasets/$repo/commit/main'),
      '${jsonEncode({
        'key': 'header',
        'value': {'summary': 'Add photo from HF Drive'},
      })}\n${jsonEncode(operation)}\n',
      contentType: 'application/x-ndjson',
    );
  }
}
