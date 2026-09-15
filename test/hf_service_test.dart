import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:happy_drive/hf_service.dart';

void main() {
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aKXcAAAAASUVORK5CYII=',
  );
  HfService service(Future<http.Response> Function(http.Request) handler) =>
      HfService(
        repo: 'tester/photos',
        token: 'hf_test_secret',
        client: MockClient(handler),
      );

  test('public repositories cannot be connected or uploaded to', () async {
    final api = service(
      (request) async => http.Response('{"private":false}', 200),
    );
    await expectLater(api.connect(), throwsA(isA<DriveException>()));
    await expectLater(
      api.upload('photo.png', png),
      throwsA(isA<DriveException>()),
    );
    api.close();
  });
  test('listing follows pagination and excludes other repository files', () async {
    final api = service((request) async {
      if (request.url.path == '/api/datasets/tester/photos') {
        return http.Response('{"private":true}', 200);
      }
      if (request.url.queryParameters['cursor'] == 'page2') {
        return http.Response(
          '[{"type":"file","path":"photos/b.png","size":12}]',
          200,
        );
      }
      return http.Response(
        '[{"type":"file","path":"photos/a.jpg","size":20},{"type":"file","path":"README.md","size":8}]',
        200,
        headers: {
          'link':
              '<https://huggingface.co/api/datasets/tester/photos/tree/main?cursor=page2>; rel="next"',
        },
      );
    });
    expect((await api.listPhotos()).map((p) => p.path), [
      'photos/b.png',
      'photos/a.jpg',
    ]);
    api.close();
  });
  test('download never forwards the HF token to storage redirects', () async {
    final api = service((request) async {
      if (request.url.host == 'huggingface.co') {
        expect(request.headers['Authorization'], 'Bearer hf_test_secret');
        return http.Response(
          '',
          302,
          headers: {'location': 'https://storage.example/photo.png'},
        );
      }
      expect(request.headers.containsKey('Authorization'), false);
      return http.Response.bytes(png, 200);
    });
    expect(await api.download(Photo('photos/a.png', png.length)), png);
    api.close();
  });
  test(
    'regular upload commits intact bytes under a unique photo path',
    () async {
      final paths = <String>[];
      final api = service((request) async {
        if (request.url.path.endsWith('/tester/photos')) {
          return http.Response('{"private":true}', 200);
        }
        if (request.url.path.contains('/preupload/')) {
          return http.Response('{"files":[{"uploadMode":"regular"}]}', 200);
        }
        final lines = request.body.trim().split('\n').map(jsonDecode).toList();
        expect(lines[0]['key'], 'header');
        expect(lines[1]['key'], 'file');
        expect(base64Decode(lines[1]['value']['content']), png);
        final path = lines[1]['value']['path'] as String;
        expect(
          path,
          matches(r'^photos/\d{4}-\d{2}-\d{2}/[a-f0-9]{24}--photo.png$'),
        );
        paths.add(path);
        return http.Response('{}', 200);
      });
      await api.upload('photo.png', png);
      await api.upload('photo.png', png);
      expect(paths[0], isNot(paths[1]));
      api.close();
    },
  );
  test('LFS upload sends bytes, verifies, then commits its object', () async {
    final steps = <String>[];
    final api = service((request) async {
      if (request.url.path.endsWith('/tester/photos')) {
        return http.Response('{"private":true}', 200);
      }
      if (request.url.path.contains('/preupload/')) {
        return http.Response('{"files":[{"uploadMode":"lfs"}]}', 200);
      }
      if (request.url.path.endsWith('/batch')) {
        expect(jsonDecode(request.body)['transfers'], ['basic']);
        return http.Response(
          '{"transfer":"basic","objects":[{"actions":{"upload":{"href":"https://storage.example/upload"},"verify":{"href":"https://huggingface.co/verify"}}}]}',
          200,
        );
      }
      if (request.method == 'PUT') {
        expect(request.bodyBytes, png);
        expect(request.headers.containsKey('Authorization'), false);
        steps.add('upload');
        return http.Response('', 200);
      }
      if (request.url.path == '/verify') {
        steps.add('verify');
        return http.Response('{}', 200);
      }
      final operation = jsonDecode(request.body.trim().split('\n')[1]);
      expect(operation['key'], 'lfsFile');
      expect(operation['value']['size'], png.length);
      steps.add('commit');
      return http.Response('{}', 200);
    });
    await api.upload('photo.png', png);
    expect(steps, ['upload', 'verify', 'commit']);
    api.close();
  });
  test('invalid image content fails before contacting Hugging Face', () async {
    final api = service((request) async {
      fail('Unexpected network request');
    });
    await expectLater(
      api.upload('fake.jpg', Uint8List.fromList([1, 2, 3])),
      throwsA(isA<DriveException>()),
    );
    api.close();
  });
}
