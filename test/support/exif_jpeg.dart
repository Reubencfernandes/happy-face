import 'dart:convert';
import 'dart:typed_data';

/// Builds a tiny JPEG carrying a real EXIF block, laid out the way cameras
/// write it (little-endian TIFF, Exif and GPS sub-IFDs).
Uint8List jpegWithExif({
  String? dateTimeOriginal,
  String? offsetTimeOriginal,
  List<List<int>>? latitude,
  String latitudeRef = 'N',
  List<List<int>>? longitude,
  String longitudeRef = 'E',
  int width = 4032,
  int height = 3024,
  List<int> filler = const [],
}) {
  final tiff = _Tiff();
  final exif = <_Entry>[
    if (dateTimeOriginal != null) _Entry.ascii(0x9003, dateTimeOriginal),
    if (offsetTimeOriginal != null) _Entry.ascii(0x9011, offsetTimeOriginal),
    _Entry.long(0xA002, width),
    _Entry.long(0xA003, height),
  ];
  final gps = <_Entry>[
    if (latitude != null) ...[
      _Entry.ascii(0x0001, latitudeRef),
      _Entry.rationals(0x0002, latitude),
    ],
    if (longitude != null) ...[
      _Entry.ascii(0x0003, longitudeRef),
      _Entry.rationals(0x0004, longitude),
    ],
  ];

  // IFD0 holds pointers to the Exif and GPS IFDs.
  const ifd0At = 8;
  final ifd0Size = _Tiff.ifdSize(gps.isEmpty ? 1 : 2);
  final exifAt = ifd0At + ifd0Size;
  final exifEnd = exifAt + _Tiff.ifdSize(exif.length) + _Tiff.dataSize(exif);
  final gpsAt = exifEnd;

  tiff.header(ifd0At);
  tiff.ifd([
    _Entry.long(0x8769, exifAt),
    if (gps.isNotEmpty) _Entry.long(0x8825, gpsAt),
  ], ifd0At);
  tiff.ifd(exif, exifAt);
  if (gps.isNotEmpty) tiff.ifd(gps, gpsAt);

  final app1 = [...ascii.encode('Exif'), 0, 0, ...tiff.bytes];
  return Uint8List.fromList([
    0xFF, 0xD8, // SOI
    0xFF, 0xE1, (app1.length + 2) >> 8, (app1.length + 2) & 0xFF, ...app1,
    ...filler,
    0xFF, 0xD9, // EOI
  ]);
}

class _Entry {
  final int tag;
  final int type; // 2 ASCII, 4 LONG, 5 RATIONAL
  final int count;
  final List<int> data;
  _Entry(this.tag, this.type, this.count, this.data);

  factory _Entry.ascii(int tag, String s) {
    final d = [...ascii.encode(s), 0];
    return _Entry(tag, 2, d.length, d);
  }

  factory _Entry.long(int tag, int v) => _Entry(tag, 4, 1, _le32(v));

  factory _Entry.rationals(int tag, List<List<int>> values) =>
      _Entry(tag, 5, values.length, [
        for (final r in values) ...[..._le32(r[0]), ..._le32(r[1])],
      ]);

  bool get inline => data.length <= 4;
  int get paddedSize => inline ? 0 : data.length + (data.length.isOdd ? 1 : 0);
}

class _Tiff {
  final List<int> bytes = [];

  static int ifdSize(int entries) => 2 + entries * 12 + 4;
  static int dataSize(List<_Entry> entries) =>
      entries.fold(0, (sum, e) => sum + e.paddedSize);

  void header(int firstIfd) =>
      bytes.addAll([0x49, 0x49, 0x2A, 0x00, ..._le32(firstIfd)]);

  void ifd(List<_Entry> entries, int at) {
    assert(bytes.length == at, 'IFD placed at ${bytes.length}, expected $at');
    var dataAt = at + ifdSize(entries.length);
    final data = <int>[];
    bytes.addAll(_le16(entries.length));
    for (final e in entries) {
      bytes
        ..addAll(_le16(e.tag))
        ..addAll(_le16(e.type))
        ..addAll(_le32(e.count));
      if (e.inline) {
        bytes.addAll([...e.data, ...List.filled(4 - e.data.length, 0)]);
      } else {
        bytes.addAll(_le32(dataAt));
        data.addAll(e.data);
        if (e.data.length.isOdd) data.add(0);
        dataAt += e.paddedSize;
      }
    }
    bytes
      ..addAll(_le32(0))
      ..addAll(data);
  }
}

List<int> _le16(int v) => [v & 0xFF, (v >> 8) & 0xFF];
List<int> _le32(int v) => [
  v & 0xFF,
  (v >> 8) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 24) & 0xFF,
];
