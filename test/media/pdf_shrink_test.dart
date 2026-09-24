import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:happy_drive/media/pdf_shrink.dart';

/// Just enough of a JPEG for the frame header to be read.
Uint8List fakeJpeg(int width, int height, {int components = 3, int fill = 0}) {
  final sof = [
    0xFF, 0xC0, 0, 8 + 3 * components, 8, //
    height >> 8, height & 0xFF, width >> 8, width & 0xFF, components,
    for (var c = 0; c < components; c++) ...[c + 1, 0x11, 0],
  ];
  return Uint8List.fromList([
    0xFF, 0xD8, ...sof, ...List.filled(fill, 0x55), 0xFF, 0xD9, //
  ]);
}

/// Halves the picture and cuts it to a tenth of the bytes.
Future<Uint8List?> halve(Uint8List jpeg) async {
  final info = jpegInfo(jpeg)!;
  return fakeJpeg(info.width ~/ 2, info.height ~/ 2, fill: jpeg.length ~/ 10);
}

Uint8List _ascii(String s) => Uint8List.fromList(latin1.encode(s));

/// A one-page PDF around one picture. With [xrefStream], the page tree is
/// packed into an object stream and indexed by a predicted xref stream, the
/// way most PDFs written since 2010 are.
Uint8List buildPdf({
  required Uint8List image,
  required int width,
  required int height,
  String colorSpace = '/DeviceRGB',
  bool xrefStream = false,
  bool encrypted = false,
}) {
  final out = BytesBuilder();
  final offsets = <int, int>{};
  void obj(int n, List<int> body) {
    offsets[n] = out.length;
    out
      ..add(_ascii('$n 0 obj\n'))
      ..add(body)
      ..add(_ascii('\nendobj\n'));
  }

  out.add(_ascii('%PDF-1.7\n%\xE2\xE3\xCF\xD3\n'));
  const catalog = '<< /Type /Catalog /Pages 2 0 R >>';
  const pages = '<< /Type /Pages /Kids [3 0 R] /Count 1 >>';
  const page =
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
      '/Resources << /XObject << /Im1 4 0 R >> >> /Contents 5 0 R >>';
  if (!xrefStream) {
    obj(1, _ascii(catalog));
    obj(2, _ascii(pages));
    obj(3, _ascii(page));
  }
  obj(4, [
    ..._ascii(
      '<< /Type /XObject /Subtype /Image /Width $width /Height $height '
      '/ColorSpace $colorSpace /BitsPerComponent 8 /Filter /DCTDecode '
      '/Length ${image.length} >>\nstream\n',
    ),
    ...image,
    ..._ascii('\nendstream'),
  ]);
  const content = 'q 612 0 0 792 0 0 cm /Im1 Do Q';
  obj(
    5,
    _ascii('<< /Length ${content.length} >>\nstream\n$content\nendstream'),
  );

  const root = '/Root 1 0 R';
  final encrypt = encrypted ? ' /Encrypt 9 0 R' : '';
  if (!xrefStream) {
    final at = out.length;
    final s = StringBuffer('xref\n0 6\n0000000000 65535 f\r\n');
    for (var n = 1; n <= 5; n++) {
      s.write('${offsets[n].toString().padLeft(10, '0')} 00000 n\r\n');
    }
    s.write('trailer\n<< /Size 6 $root$encrypt >>\nstartxref\n$at\n%%EOF\n');
    out.add(_ascii(s.toString()));
    return out.takeBytes();
  }

  // Objects 1-3 packed into object stream 6.
  final packed = StringBuffer();
  final index = <String>[];
  for (final (n, body) in [(1, catalog), (2, pages), (3, page)]) {
    index.add('$n ${packed.length}');
    packed.write('$body\n');
  }
  final header = '${index.join(' ')} ';
  final stm = ZLibEncoder().convert(_ascii('$header$packed'));
  obj(6, [
    ..._ascii(
      '<< /Type /ObjStm /N 3 /First ${header.length} /Filter /FlateDecode '
      '/Length ${stm.length} >>\nstream\n',
    ),
    ...stm,
    ..._ascii('\nendstream'),
  ]);
  final at = out.length;
  final rows = <List<int>>[
    [0, 0, 0, 0, 0, 0xFF, 0xFF],
    for (var i = 0; i < 3; i++) [2, 0, 0, 0, 6, 0, i],
    for (final n in [4, 5, 6])
      [
        1,
        0,
        (offsets[n]! >> 16) & 0xFF,
        (offsets[n]! >> 8) & 0xFF,
        offsets[n]! & 0xFF,
        0,
        0,
      ],
    [1, 0, (at >> 16) & 0xFF, (at >> 8) & 0xFF, at & 0xFF, 0, 0],
  ];
  // PNG "Up" prediction, as Acrobat and most libraries write it.
  final predicted = <int>[];
  for (var r = 0; r < rows.length; r++) {
    predicted.add(2);
    for (var c = 0; c < 7; c++) {
      predicted.add((rows[r][c] - (r == 0 ? 0 : rows[r - 1][c])) & 0xFF);
    }
  }
  final xref = ZLibEncoder().convert(predicted);
  out
    ..add(
      _ascii(
        '7 0 obj\n<< /Type /XRef /Size 8 /W [1 4 2] $root$encrypt '
        '/Filter /FlateDecode /DecodeParms << /Predictor 12 /Columns 7 >> '
        '/Length ${xref.length} >>\nstream\n',
      ),
    )
    ..add(xref)
    ..add(_ascii('\nendstream\nendobj\nstartxref\n$at\n%%EOF\n'));
  return out.takeBytes();
}

void main() {
  final photo = fakeJpeg(2400, 1600, fill: 60000);

  for (final xrefStream in [false, true]) {
    final kind = xrefStream ? 'an xref stream' : 'a classic xref table';
    test('pictures shrink and the PDF still reads, with $kind', () async {
      final pdf = buildPdf(
        image: photo,
        width: 2400,
        height: 1600,
        xrefStream: xrefStream,
      );
      final out = await shrinkPdf(pdf, halve);
      expect(out, isNotNull);
      expect(out!.length, lessThan(pdf.length ~/ 5));
      final text = latin1.decode(out);
      expect(text, contains('/Width 1200'));
      expect(text, contains('/Height 800'));
      expect(text, contains('q 612 0 0 792 0 0 cm /Im1 Do Q'));
      if (xrefStream) expect(text, contains('/Type /ObjStm'));
      // What was written can itself be read and shrunk again, which it
      // can't be if a single offset or entry is wrong.
      final again = await shrinkPdf(out, halve, minImageBytes: 0);
      expect(again, isNotNull);
      expect(latin1.decode(again!), contains('/Width 600'));
    });
  }

  test('a grey scan that comes back in colour is labelled RGB', () async {
    final scan = fakeJpeg(2000, 3000, components: 1, fill: 60000);
    final pdf = buildPdf(
      image: scan,
      width: 2000,
      height: 3000,
      colorSpace: '/DeviceGray',
    );
    final out = await shrinkPdf(pdf, halve);
    expect(latin1.decode(out!), contains('/ColorSpace /DeviceRGB'));
    expect(latin1.decode(out), isNot(contains('/DeviceGray')));
  });

  test('a picture that would be turned or cropped is left alone', () async {
    final pdf = buildPdf(image: photo, width: 2400, height: 1600);
    final out = await shrinkPdf(
      pdf,
      (jpeg) async => fakeJpeg(800, 1200, fill: 10),
    );
    expect(out, isNull);
  });

  test('declines what it must not touch', () async {
    Future<Uint8List?> shrink(Uint8List pdf) => shrinkPdf(pdf, halve);

    expect(
      await shrink(
        buildPdf(image: photo, width: 2400, height: 1600, encrypted: true),
      ),
      isNull,
      reason: 'encrypted streams would be rewritten as garbage',
    );
    final cmyk = fakeJpeg(2400, 1600, components: 4, fill: 60000);
    expect(
      await shrink(
        buildPdf(
          image: cmyk,
          width: 2400,
          height: 1600,
          colorSpace: '/DeviceCMYK',
        ),
      ),
      isNull,
    );
    final spot = fakeJpeg(2000, 3000, components: 1, fill: 60000);
    expect(
      await shrink(
        buildPdf(
          image: spot,
          width: 2000,
          height: 3000,
          colorSpace: '[/Separation /Gold /DeviceCMYK 8 0 R]',
        ),
      ),
      isNull,
      reason: 'grey samples of a spot colour are not grey',
    );
    final small = fakeJpeg(200, 100, fill: 500);
    expect(
      await shrink(buildPdf(image: small, width: 200, height: 100)),
      isNull,
    );
    expect(await shrink(_ascii('%PDF-1.4 and then nonsense')), isNull);
    expect(await shrink(_ascii('not a pdf at all')), isNull);
    final pdf = buildPdf(image: photo, width: 2400, height: 1600);
    expect(
      await shrink(Uint8List.sublistView(pdf, 0, pdf.length - 40)),
      isNull,
      reason: 'a truncated file has no trustworthy xref',
    );
  });
}
