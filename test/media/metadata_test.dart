import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:happy_drive/media/image_type.dart';
import 'package:happy_drive/media/metadata.dart';

import '../support/exif_jpeg.dart';

void main() {
  group('EXIF metadata', () {
    test('date, time zone, GPS and size from a camera JPEG', () async {
      final jpeg = jpegWithExif(
        dateTimeOriginal: '2025:12:31 23:30:15',
        offsetTimeOriginal: '+05:30',
        // 15° 29' 24" N, 73° 49' 12" E  (Panaji)
        latitude: [
          [15, 1],
          [29, 1],
          [24, 1],
        ],
        longitude: [
          [73, 1],
          [49, 1],
          [1200, 100],
        ],
      );
      final m = await readPhotoMetadata(
        jpeg,
        zoneGuess: (_) => fail('offset was present'),
      );
      expect(m.takenAt, DateTime.utc(2025, 12, 31, 18, 0, 15));
      expect(m.tzOffsetMinutes, 330);
      expect(m.lat, closeTo(15.49, 0.0001));
      expect(m.lng, closeTo(73.82, 0.0001));
      expect(m.width, 4032);
      expect(m.height, 3024);
    });

    test('southern and western hemispheres are negative', () async {
      final jpeg = jpegWithExif(
        dateTimeOriginal: '2024:02:10 08:00:00',
        offsetTimeOriginal: '-03:00',
        latitude: [
          [22, 1],
          [54, 1],
          [0, 1],
        ],
        latitudeRef: 'S',
        longitude: [
          [43, 1],
          [12, 1],
          [0, 1],
        ],
        longitudeRef: 'W',
      );
      final m = await readPhotoMetadata(jpeg);
      expect(m.lat, closeTo(-22.9, 0.0001));
      expect(m.lng, closeTo(-43.2, 0.0001));
      expect(m.takenAt, DateTime.utc(2024, 2, 10, 11));
    });

    test('without an offset, the phone time zone is assumed', () async {
      final jpeg = jpegWithExif(dateTimeOriginal: '2023:07:04 12:00:00');
      final m = await readPhotoMetadata(
        jpeg,
        zoneGuess: (wall) {
          expect(wall, DateTime.utc(2023, 7, 4, 12));
          return 120;
        },
      );
      expect(m.takenAt, DateTime.utc(2023, 7, 4, 10));
      expect(m.tzOffsetMinutes, 120);
      expect(m.lat, isNull);
    });

    test('files without EXIF or with garbage never throw', () async {
      expect(
        (await readPhotoMetadata([0xFF, 0xD8, 0xFF, 0xD9])).takenAt,
        isNull,
      );
      expect(
        (await readPhotoMetadata(utf8.encode('not an image'))).takenAt,
        isNull,
      );
      expect((await readPhotoMetadata([])).takenAt, isNull);
    });

    test('gallery facts fill the gaps EXIF leaves', () {
      final exif = PhotoMetadata(lat: 1, lng: 2);
      final gallery = PhotoMetadata(
        takenAt: DateTime.utc(2020),
        tzOffsetMinutes: 60,
        lat: 9,
        lng: 9,
        width: 10,
      );
      final merged = exif.orElse(gallery);
      expect(merged.lat, 1);
      expect(merged.takenAt, DateTime.utc(2020));
      expect(merged.tzOffsetMinutes, 60);
      expect(merged.width, 10);
    });

    test('parsers reject nonsense', () {
      expect(parseExifDateTime('0000:00:00 00:00:00'), isNull);
      expect(
        parseExifDateTime('2024-05-06T07:08:09'),
        DateTime.utc(2024, 5, 6, 7, 8, 9),
      );
      expect(parseExifOffset('+15:00'), isNull);
      expect(parseExifOffset('-0800'), -480);
      expect(gpsToDecimal([0, 0, 0], 'N'), isNull, reason: 'null island');
      expect(gpsToDecimal([1, 2], 'N'), isNull);
    });
  });

  group('image type sniffing', () {
    test('recognises formats by signature, not extension', () {
      expect(sniffImageMime([0xFF, 0xD8, 0xFF, 0xE0]), 'image/jpeg');
      expect(
        sniffImageMime(base64Decode('iVBORw0KGgoAAAANSUhEUg==')),
        'image/png',
      );
      expect(sniffImageMime(ascii.encode('GIF89a...')), 'image/gif');
      expect(
        sniffImageMime(ascii.encode('RIFF\x00\x00\x00\x00WEBPVP8 ')),
        'image/webp',
      );
      expect(
        sniffImageMime([0, 0, 0, 24, ...ascii.encode('ftypheic')]),
        'image/heic',
      );
      expect(
        sniffImageMime([0, 0, 0, 24, ...ascii.encode('ftypmif1')]),
        'image/heif',
      );
      expect(
        sniffImageMime([0, 0, 0, 24, ...ascii.encode('ftypisom')]),
        isNull,
        reason: 'mp4 video',
      );
      expect(sniffImageMime(ascii.encode('%PDF-1.7')), isNull);
      expect(sniffImageMime([]), isNull);
    });
  });
}
