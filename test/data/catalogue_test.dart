import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:happy_drive/data/catalogue.dart';

PhotoRecord photo(String id, {String name = 'IMG.jpg', int takenAt = 1000}) =>
    PhotoRecord(
      id: id,
      name: name,
      mime: 'image/jpeg',
      size: 10,
      takenAt: DateTime.fromMillisecondsSinceEpoch(takenAt, isUtc: true),
      uploadedAt: DateTime.fromMillisecondsSinceEpoch(5000, isUtc: true),
    );

void main() {
  test('put, patch and delete', () {
    final c = Catalogue();
    expect(c.apply(PutOp(photo('a'), 1)), isTrue);
    expect(c.apply(PatchOp('a', {'caption': 'a dog on a beach'}, 2)), isTrue);
    expect(c.records['a']!.caption, 'a dog on a beach');
    expect(c.apply(PatchOp('a', {'caption': null}, 3)), isTrue);
    expect(c.records['a']!.caption, isNull);
    expect(c.apply(DeleteOp('a', 4)), isTrue);
    expect(c.records, isEmpty);
    expect(c.apply(PatchOp('a', {'caption': 'late'}, 5)), isFalse);
  });

  test('a stale put cannot resurrect a later delete, a newer one can', () {
    final c = Catalogue()..apply(DeleteOp('a', 10));
    expect(c.apply(PutOp(photo('a'), 9)), isFalse);
    expect(c.records, isEmpty);
    expect(c.apply(PutOp(photo('a'), 11)), isTrue);
    expect(c.records.keys, ['a']);
    expect(c.tombstones, isEmpty);
  });

  test('uploading the same photo again keeps its enrichment', () {
    final c = Catalogue()
      ..apply(PutOp(photo('a'), 1))
      ..apply(
        PatchOp('a', {
          'caption': 'sunset',
          'place': 'Goa',
          'tags': ['sea'],
        }, 2),
      )
      ..apply(PutOp(photo('a', name: 'copy.jpg'), 3));
    expect(c.records['a']!.name, 'copy.jpg');
    expect(c.records['a']!.caption, 'sunset');
    expect(c.records['a']!.place, 'Goa');
    expect(c.records['a']!.tags, ['sea']);
  });

  test('devices converge regardless of the order ops arrive in', () {
    final ops = <CatalogueOp>[
      PutOp(photo('a'), 1),
      PutOp(photo('b'), 2),
      PatchOp('a', {'caption': 'first'}, 3),
      PatchOp('a', {'caption': 'second'}, 4),
      DeleteOp('b', 5),
      PutOp(photo('c'), 6),
      PatchOp('c', {
        'weather': {'code': 61, 'tempC': 24.5},
      }, 7),
    ];
    final expected = jsonEncode((Catalogue()..applyAll(ops)).toJson());
    final random = Random(42);
    for (var i = 0; i < 20; i++) {
      final shuffled = List.of(ops)..shuffle(random);
      expect(jsonEncode((Catalogue()..applyAll(shuffled)).toJson()), expected);
    }
  });

  test('records and ops round-trip through JSON', () {
    final rec = PhotoRecord(
      id: 'x',
      name: 'beach.heic',
      mime: 'image/heic',
      size: 123,
      takenAt: DateTime.utc(2025, 12, 31, 23, 30),
      uploadedAt: DateTime.utc(2026, 1, 2),
      width: 4032,
      height: 3024,
      tzOffsetMinutes: 330,
      compression: 'high',
      lat: 15.49,
      lng: 73.82,
      tags: const ['beach'],
    );
    final op = CatalogueOp.fromJson(
      jsonDecode(jsonEncode(PutOp(rec, 9).toJson())),
    );
    expect(jsonEncode(op.toJson()), jsonEncode(PutOp(rec, 9).toJson()));
    // 23:30 UTC on 31 Dec is already 1 Jan in India.
    expect(rec.localTakenAt.day, 1);
  });
}
