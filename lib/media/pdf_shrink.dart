import 'dart:convert';
import 'dart:io' show ZLibDecoder, ZLibEncoder;
import 'dart:typed_data';

/// Re-encodes one JPEG, or returns null to leave it alone.
typedef JpegReencoder = Future<Uint8List?> Function(Uint8List jpeg);

/// Makes a PDF smaller by re-encoding the photos inside it.
///
/// Pictures are nearly always what makes a PDF big — a scanned page is a
/// photo of a page — so they are the only thing touched. Text, fonts and
/// drawings are copied byte for byte, which means nothing about how the
/// document reads can change.
///
/// Only JPEG pictures are re-encoded: colour ones, and grey ones such as
/// scanned pages. CMYK, spot-colour and masked pictures are left alone,
/// because the re-encoder only writes ordinary colour JPEG.
///
/// Returns null whenever the PDF isn't one it fully understands — encrypted,
/// damaged, or with nothing worth shrinking — so the caller keeps the
/// original. A smaller file that opens wrong is far worse than no saving.
Future<Uint8List?> shrinkPdf(
  Uint8List pdf,
  JpegReencoder reencode, {
  int minImageBytes = 24 * 1024,
}) async {
  try {
    return await _PdfShrinker(pdf, reencode, minImageBytes).run();
  } catch (_) {
    // Declined, damaged, or a shape this reader has never met: whatever
    // went wrong, the original is what gets stored.
    return null;
  }
}

/// Thrown for anything the shrinker declines to touch.
class _Unsupported implements Exception {
  const _Unsupported();
}

class _PdfShrinker {
  final Uint8List pdf;
  final JpegReencoder reencode;
  final int minImageBytes;

  late final _XrefTable table;

  _PdfShrinker(this.pdf, this.reencode, this.minImageBytes);

  Future<Uint8List?> run() async {
    if (!_startsWithAt(pdf, 0, _ascii('%PDF-'))) throw const _Unsupported();
    table = _XrefReader(pdf).read(_startXref(pdf));
    if (table.trailer.containsKey('Encrypt')) throw const _Unsupported();

    // Where one object's bytes stop is where the next thing the xref knows
    // about starts; the object's own `endobj` narrows it from there.
    final boundaries = <int>{
      pdf.length,
      ...table.sections,
      for (final e in table.entries.values)
        if (e.type == 1) e.offset,
    }.toList()..sort();
    int boundaryAfter(int offset) {
      var lo = 0, hi = boundaries.length - 1;
      while (lo < hi) {
        final mid = (lo + hi) >> 1;
        if (boundaries[mid] > offset) {
          hi = mid;
        } else {
          lo = mid + 1;
        }
      }
      return boundaries[lo];
    }

    final objects = <_Obj>[];
    for (final MapEntry(key: number, value: e) in table.entries.entries) {
      if (e.type != 1) continue;
      objects.add(_readObject(number, e, boundaryAfter(e.offset)));
    }
    objects.sort((a, b) => a.offset.compareTo(b.offset));

    var changed = 0;
    for (final o in objects) {
      if (!o.isShrinkableImage(minImageBytes)) continue;
      final replaced = await _shrinkImage(o);
      if (replaced != null) {
        o.replacement = replaced;
        changed++;
      }
    }
    if (changed == 0) return null;

    final out = _write(objects);
    // Read back what was written the same way the original was read. Any
    // disagreement means the rewrite is wrong somewhere, and the original
    // is kept.
    final check = _XrefReader(out).read(_startXref(out));
    for (final MapEntry(key: number, value: e) in check.entries.entries) {
      if (e.type != 1) continue;
      final head = _ObjectHeader.at(out, e.offset);
      if (head == null || head.number != number) throw const _Unsupported();
    }
    return out;
  }

  _Obj _readObject(int number, _Entry e, int limit) {
    final head = _ObjectHeader.at(pdf, e.offset);
    if (head == null || head.number != number) throw const _Unsupported();
    final lexer = _Lexer(pdf, head.bodyStart, limit);
    final value = lexer.value();
    lexer.skipSpace();
    if (lexer.keywordAhead('endobj')) {
      return _Obj(number, head.generation, e.offset, lexer.pos + 6, value);
    }
    if (value is! _Dict || !lexer.keywordAhead('stream')) {
      throw const _Unsupported();
    }
    var dataStart = lexer.pos + 6;
    if (pdf[dataStart] == 0x0D) dataStart++;
    if (pdf[dataStart] == 0x0A) dataStart++;

    // The stated length when it can be trusted, else the last `endstream`
    // before the next object.
    var dataEnd = -1;
    final length = _resolve(value['Length']);
    if (length is int && dataStart + length <= limit) {
      var p = dataStart + length;
      while (p < limit && _isSpace(pdf[p])) {
        p++;
      }
      if (_startsWithAt(pdf, p, _ascii('endstream'))) {
        dataEnd = dataStart + length;
      }
    }
    if (dataEnd < 0) {
      final at = _lastIndexOf(pdf, _ascii('endstream'), dataStart, limit);
      if (at < 0) throw const _Unsupported();
      dataEnd = at;
      if (dataEnd > dataStart && pdf[dataEnd - 1] == 0x0A) dataEnd--;
      if (dataEnd > dataStart && pdf[dataEnd - 1] == 0x0D) dataEnd--;
    }
    final endstream = _indexOf(pdf, _ascii('endstream'), dataEnd, limit);
    if (endstream < 0) throw const _Unsupported();
    final after = _Lexer(pdf, endstream + 9, limit)..skipSpace();
    if (!after.keywordAhead('endobj')) throw const _Unsupported();
    return _Obj(
      number,
      head.generation,
      e.offset,
      after.pos + 6,
      value,
      dataStart: dataStart,
      dataEnd: dataEnd,
    );
  }

  /// What a reference points at, when it is a plain top-level object — a
  /// /Length, say, is often an object of its own. Objects packed inside
  /// object streams aren't unpacked; callers treat them as unknown.
  Object? _resolve(Object? v) {
    if (v is! _Ref) return v;
    final e = table.entries[v.number];
    if (e == null || e.type != 1) return null;
    final head = _ObjectHeader.at(pdf, e.offset);
    if (head == null || head.number != v.number) return null;
    return _Lexer(pdf, head.bodyStart, pdf.length).value();
  }

  bool _isGray(Object? space) {
    if (space == const _Name('DeviceGray')) return true;
    if (space is! List || space.isEmpty) return false;
    if (space.first == const _Name('CalGray')) return true;
    if (space.first != const _Name('ICCBased') || space.length < 2) {
      return false;
    }
    // An ICC profile says how many channels it describes.
    final profile = _resolve(space[1]);
    return profile is _Dict && profile['N'] == 1;
  }

  Future<Uint8List?> _shrinkImage(_Obj o) async {
    final data = Uint8List.sublistView(pdf, o.dataStart, o.dataEnd);
    final before = jpegInfo(data);
    if (before == null) return null;
    final dict = o.value as _Dict;
    // Colour pictures are decoded and re-encoded channel for channel, so
    // whatever colour space the PDF gives them still applies. The encoder
    // only writes colour, though, so a grey picture — every scanned page —
    // comes back as colour, and is then labelled plain RGB. That is only
    // right when it really was plain grey, not a spot colour.
    if (before.components == 3) {
      // Without the usual colour transform the samples are stored as RGB,
      // which a phone's decoder would misread as YCbCr.
      final parms = dict['DecodeParms'];
      final transform = parms is _Dict ? parms['ColorTransform'] : null;
      if (transform != null && transform != 1) return null;
    } else if (before.components != 1 ||
        !_isGray(_resolve(dict['ColorSpace']))) {
      return null;
    }
    final out = await reencode(_withoutExif(data));
    if (out == null || out.length >= data.length * 0.9) return null;
    final after = jpegInfo(out);
    if (after == null) return null;
    // A picture that comes back with as many channels as it had keeps its
    // colour space; one that came in grey and left in colour is now RGB.
    final String? newSpace;
    if (after.components == before.components) {
      newSpace = null;
    } else if (before.components == 1 && after.components == 3) {
      newSpace = '/DeviceRGB';
    } else {
      return null;
    }
    // The same picture, only smaller: a rotation or a crop would move it on
    // the page.
    final ratio = before.width / before.height;
    if ((after.width / after.height - ratio).abs() > ratio * 0.02) return null;

    final header = dict.rewrite(pdf, {
      'Width': '${after.width}',
      'Height': '${after.height}',
      'Length': '${out.length}',
      'Filter': '/DCTDecode',
      'BitsPerComponent': '8',
      'DecodeParms': null,
      'ColorSpace': ?newSpace,
    });
    return _concat([
      _ascii('${o.number} ${o.generation} obj\n'),
      header,
      _ascii('\nstream\n'),
      out,
      _ascii('\nendstream\nendobj'),
    ]);
  }

  Uint8List _write(List<_Obj> objects) {
    final out = BytesBuilder(copy: false);
    // The original first line, then the customary binary comment.
    var eol = 0;
    while (eol < pdf.length && pdf[eol] != 0x0A && pdf[eol] != 0x0D) {
      eol++;
    }
    out.add(Uint8List.sublistView(pdf, 0, eol));
    out.add(const [0x0A, 0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]);

    final entries = <int, _Entry>{};
    for (final o in objects) {
      // The old cross-reference streams are replaced by the one written
      // below, and a linearisation hint would now point at the wrong bytes.
      if (o.isXrefStream || o.isLinearization) continue;
      entries[o.number] = _Entry(1, out.length, o.generation);
      out.add(o.replacement ?? Uint8List.sublistView(pdf, o.offset, o.end));
      out.addByte(0x0A);
    }
    for (final MapEntry(key: number, value: e) in table.entries.entries) {
      if (e.type == 2) entries[number] = e;
    }
    var size = table.size;
    for (final n in entries.keys) {
      if (n >= size) size = n + 1;
    }

    final keep = [
      for (final key in const ['Root', 'Info', 'ID'])
        if (table.trailerRaw[key] case final raw?) '/$key $raw',
    ].join(' ');
    final xrefAt = out.length;
    if (entries.values.any((e) => e.type == 2)) {
      // Objects packed inside object streams can only be pointed at from a
      // cross-reference stream, so one is written, as object number [size].
      entries[size] = _Entry(1, xrefAt, 0);
      final rows = BytesBuilder();
      for (var n = 0; n <= size; n++) {
        final e = entries[n] ?? const _Entry(0, 0, 0);
        final second = e.type == 2 ? e.stream : e.offset;
        final third = e.type == 2 ? e.index : (e.type == 0 ? 0 : e.generation);
        rows.add([
          e.type,
          (second >> 24) & 0xFF,
          (second >> 16) & 0xFF,
          (second >> 8) & 0xFF,
          second & 0xFF,
          (third >> 8) & 0xFF,
          third & 0xFF,
        ]);
      }
      final packed = ZLibEncoder().convert(rows.takeBytes());
      out.add(
        _ascii(
          '$size 0 obj\n<< /Type /XRef /Size ${size + 1} /W [1 4 2] '
          '/Filter /FlateDecode /Length ${packed.length} $keep >>\nstream\n',
        ),
      );
      out.add(packed);
      out.add(_ascii('\nendstream\nendobj\n'));
    } else {
      final s = StringBuffer('xref\n0 $size\n');
      for (var n = 0; n < size; n++) {
        final e = entries[n];
        if (e == null || e.type != 1) {
          s.write('0000000000 65535 f\r\n');
        } else {
          s.write(
            '${e.offset.toString().padLeft(10, '0')} '
            '${e.generation.toString().padLeft(5, '0')} n\r\n',
          );
        }
      }
      s.write('trailer\n<< /Size $size $keep >>\n');
      out.add(_ascii(s.toString()));
    }
    out.add(_ascii('startxref\n$xrefAt\n%%EOF\n'));
    return out.takeBytes();
  }
}

/// One top-level object, where it sits, and what is known about it.
class _Obj {
  final int number;
  final int generation;
  final int offset;

  /// Just past its `endobj`.
  final int end;
  final Object? value;
  final int dataStart;
  final int dataEnd;
  Uint8List? replacement;

  _Obj(
    this.number,
    this.generation,
    this.offset,
    this.end,
    this.value, {
    this.dataStart = -1,
    this.dataEnd = -1,
  });

  _Dict? get _dict => value is _Dict ? value as _Dict : null;

  bool get isXrefStream => _dict?['Type'] == const _Name('XRef');
  bool get isLinearization => _dict?.containsKey('Linearized') ?? false;

  /// A plain JPEG picture, big enough to be worth the trouble.
  bool isShrinkableImage(int minBytes) {
    final d = _dict;
    if (d == null || dataStart < 0) return false;
    if (dataEnd - dataStart < minBytes) return false;
    if (d['Subtype'] != const _Name('Image')) return false;
    final filter = d['Filter'];
    final isJpeg =
        filter == const _Name('DCTDecode') ||
        (filter is List &&
            filter.length == 1 &&
            filter.first == const _Name('DCTDecode'));
    if (!isJpeg) return false;
    // Anything that reinterprets the samples would read the new ones wrong.
    if (d.containsKey('Decode') || d['ImageMask'] == true) return false;
    if (d['Mask'] is List) return false;
    final bits = d['BitsPerComponent'];
    if (bits != null && bits != 8) return false;
    // The colour space is judged against the JPEG itself, which knows how
    // many channels it has; see [_PdfShrinker._shrinkImage].
    return true;
  }
}

class _Entry {
  /// 0 free, 1 at a byte offset, 2 packed inside an object stream.
  final int type;
  final int offset;
  final int generation;
  const _Entry(this.type, this.offset, this.generation);

  int get stream => offset;
  int get index => generation;
}

class _XrefTable {
  final entries = <int, _Entry>{};

  /// Where every cross-reference section starts.
  final sections = <int>[];
  final trailer = <String, Object?>{};

  /// The trailer's values as written, to be copied into the new trailer.
  final trailerRaw = <String, String>{};
  var size = 0;
}

/// Follows the chain of cross-reference sections, newest first, so a newer
/// entry for an object always wins over an older one.
class _XrefReader {
  final Uint8List pdf;
  _XrefReader(this.pdf);

  _XrefTable read(int start) {
    final table = _XrefTable();
    final seen = <int>{};
    int? next = start;
    while (next != null) {
      if (!seen.add(next) || seen.length > 64) throw const _Unsupported();
      next = _section(next, table);
    }
    if (!table.trailer.containsKey('Root')) throw const _Unsupported();
    return table;
  }

  /// Reads one section into [table] and returns the offset of the one
  /// before it, if any.
  int? _section(int offset, _XrefTable table) {
    table.sections.add(offset);
    final lexer = _Lexer(pdf, offset, pdf.length)..skipSpace();
    final _Dict trailer;
    if (lexer.keywordAhead('xref')) {
      lexer.pos += 4;
      final found = <int, _Entry>{};
      while (true) {
        lexer.skipSpace();
        if (lexer.keywordAhead('trailer')) {
          lexer.pos += 7;
          break;
        }
        final first = lexer.value();
        final count = lexer.value();
        if (first is! int || count is! int) throw const _Unsupported();
        for (var i = 0; i < count; i++) {
          final off = lexer.value();
          final gen = lexer.value();
          final kind = lexer.value();
          if (off is! int || gen is! int) throw const _Unsupported();
          found[first + i] = kind == const _Keyword('n')
              ? _Entry(1, off, gen)
              : _Entry(0, 0, gen);
        }
      }
      final t = lexer.value();
      if (t is! _Dict) throw const _Unsupported();
      trailer = t;
      _mergeTrailer(table, trailer);
      found.forEach((n, e) => table.entries.putIfAbsent(n, () => e));
      // A hybrid file keeps some entries in a stream as well; the table's
      // own entries come first.
      if (trailer['XRefStm'] case final int at) {
        table.sections.add(at);
        _stream(at, table);
      }
    } else {
      trailer = _stream(offset, table);
    }
    final prev = trailer['Prev'];
    return prev is int ? prev : null;
  }

  _Dict _stream(int offset, _XrefTable table) {
    final head = _ObjectHeader.at(pdf, offset);
    if (head == null) throw const _Unsupported();
    final lexer = _Lexer(pdf, head.bodyStart, pdf.length);
    final dict = lexer.value();
    if (dict is! _Dict || dict['Type'] != const _Name('XRef')) {
      throw const _Unsupported();
    }
    lexer.skipSpace();
    if (!lexer.keywordAhead('stream')) throw const _Unsupported();
    var start = lexer.pos + 6;
    if (pdf[start] == 0x0D) start++;
    if (pdf[start] == 0x0A) start++;
    final length = dict['Length'];
    if (length is! int) throw const _Unsupported();
    var data = Uint8List.sublistView(pdf, start, start + length);
    final filter = dict['Filter'];
    if (filter == const _Name('FlateDecode') ||
        (filter is List &&
            filter.length == 1 &&
            filter.first == const _Name('FlateDecode'))) {
      data = Uint8List.fromList(ZLibDecoder().convert(data));
    } else if (filter != null) {
      throw const _Unsupported();
    }

    final w = dict['W'];
    if (w is! List || w.length != 3 || w.any((x) => x is! int)) {
      throw const _Unsupported();
    }
    final widths = w.cast<int>();
    final rowLength = widths.fold(0, (a, b) => a + b);
    var parms = dict['DecodeParms'];
    if (parms is List) parms = parms.isEmpty ? null : parms.first;
    if (parms is _Dict) {
      final predictor = parms['Predictor'];
      if (predictor is int && predictor >= 10) {
        final columns = parms['Columns'];
        data = _unpredictPng(data, columns is int ? columns : rowLength);
      } else if (predictor is int && predictor > 1) {
        throw const _Unsupported();
      }
    }

    final size = dict['Size'];
    if (size is! int) throw const _Unsupported();
    final index = dict['Index'];
    final ranges = index is List ? index.cast<int>() : [0, size];
    var p = 0;
    int field(int width, int fallback) {
      if (width == 0) return fallback;
      var v = 0;
      for (var i = 0; i < width; i++) {
        v = (v << 8) | data[p++];
      }
      return v;
    }

    final found = <int, _Entry>{};
    for (var r = 0; r + 1 < ranges.length; r += 2) {
      for (var i = 0; i < ranges[r + 1]; i++) {
        if (p + rowLength > data.length) throw const _Unsupported();
        final type = field(widths[0], 1);
        final second = field(widths[1], 0);
        final third = field(widths[2], 0);
        found[ranges[r] + i] = _Entry(type > 2 ? 0 : type, second, third);
      }
    }
    found.forEach((n, e) => table.entries.putIfAbsent(n, () => e));
    _mergeTrailer(table, dict);
    return dict;
  }

  void _mergeTrailer(_XrefTable table, _Dict dict) {
    for (final key in dict.keys) {
      table.trailer.putIfAbsent(key, () => dict[key]);
      table.trailerRaw.putIfAbsent(key, () => dict.raw(pdf, key));
    }
    final size = dict['Size'];
    if (size is int && size > table.size) table.size = size;
  }

  /// Undoes the PNG row filters cross-reference streams are often saved with.
  static Uint8List _unpredictPng(Uint8List data, int columns) {
    final rows = data.length ~/ (columns + 1);
    final out = Uint8List(rows * columns);
    for (var r = 0; r < rows; r++) {
      final type = data[r * (columns + 1)];
      for (var c = 0; c < columns; c++) {
        final raw = data[r * (columns + 1) + 1 + c];
        final left = c > 0 ? out[r * columns + c - 1] : 0;
        final up = r > 0 ? out[(r - 1) * columns + c] : 0;
        final upLeft = r > 0 && c > 0 ? out[(r - 1) * columns + c - 1] : 0;
        final predicted = switch (type) {
          0 => 0,
          1 => left,
          2 => up,
          3 => (left + up) >> 1,
          4 => _paeth(left, up, upLeft),
          _ => throw const _Unsupported(),
        };
        out[r * columns + c] = (raw + predicted) & 0xFF;
      }
    }
    return out;
  }

  static int _paeth(int a, int b, int c) {
    final p = a + b - c;
    final pa = (p - a).abs(), pb = (p - b).abs(), pc = (p - c).abs();
    if (pa <= pb && pa <= pc) return a;
    return pb <= pc ? b : c;
  }
}

/// `12 0 obj`, and where the object's value begins.
class _ObjectHeader {
  final int number;
  final int generation;
  final int bodyStart;
  const _ObjectHeader(this.number, this.generation, this.bodyStart);

  static _ObjectHeader? at(Uint8List pdf, int offset) {
    if (offset < 0 || offset >= pdf.length) return null;
    final lexer = _Lexer(pdf, offset, pdf.length);
    try {
      final number = lexer.value(refs: false);
      final generation = lexer.value(refs: false);
      final keyword = lexer.value(refs: false);
      if (number is! int || generation is! int) return null;
      if (keyword != const _Keyword('obj')) return null;
      return _ObjectHeader(number, generation, lexer.pos);
    } on Object {
      return null;
    }
  }
}

class _Name {
  final String name;
  const _Name(this.name);
  @override
  bool operator ==(Object other) => other is _Name && other.name == name;
  @override
  int get hashCode => name.hashCode;
}

class _Keyword {
  final String word;
  const _Keyword(this.word);
  @override
  bool operator ==(Object other) => other is _Keyword && other.word == word;
  @override
  int get hashCode => word.hashCode;
}

class _Ref {
  final int number;
  const _Ref(this.number);
}

/// A dictionary that remembers where each of its values was written, so it
/// can be copied with a few values changed and everything else untouched.
class _Dict {
  final _values = <String, Object?>{};
  final _spans = <String, (int, int)>{};

  Object? operator [](String key) => _values[key];
  bool containsKey(String key) => _values.containsKey(key);
  Iterable<String> get keys => _values.keys;

  String raw(Uint8List pdf, String key) {
    final (start, end) = _spans[key]!;
    return latin1.decode(Uint8List.sublistView(pdf, start, end));
  }

  /// This dictionary with [changes] applied: a string replaces or adds a
  /// value, null removes the key.
  Uint8List rewrite(Uint8List pdf, Map<String, String?> changes) {
    final out = BytesBuilder(copy: false)..add(_ascii('<<'));
    for (final key in _values.keys) {
      if (changes.containsKey(key)) continue;
      final (start, end) = _spans[key]!;
      out
        ..add(_ascii(' /${_escapeName(key)} '))
        ..add(Uint8List.sublistView(pdf, start, end));
    }
    changes.forEach((key, value) {
      if (value != null) out.add(_ascii(' /$key $value'));
    });
    out.add(_ascii(' >>'));
    return out.takeBytes();
  }

  static String _escapeName(String name) => name.replaceAllMapped(
    RegExp(r'[^!-~]|[#()<>\[\]{}/%]'),
    (m) => '#${m[0]!.codeUnitAt(0).toRadixString(16).padLeft(2, '0')}',
  );
}

/// Just enough of the PDF syntax to read dictionaries and find their ends.
class _Lexer {
  final Uint8List b;
  int pos;
  final int limit;
  _Lexer(this.b, this.pos, this.limit);

  void skipSpace() {
    while (pos < limit) {
      final c = b[pos];
      if (_isSpace(c)) {
        pos++;
      } else if (c == 0x25) {
        // A comment runs to the end of the line.
        while (pos < limit && b[pos] != 0x0A && b[pos] != 0x0D) {
          pos++;
        }
      } else {
        return;
      }
    }
  }

  bool keywordAhead(String word) {
    final w = _ascii(word);
    if (!_startsWithAt(b, pos, w)) return false;
    final after = pos + w.length;
    return after >= limit || _isSpace(b[after]) || _isDelimiter(b[after]);
  }

  Object? value({bool refs = true}) {
    skipSpace();
    if (pos >= limit) throw const _Unsupported();
    final c = b[pos];
    if (c == 0x2F) return _Name(_name());
    if (c == 0x28) return _literalString();
    if (c == 0x3C) {
      if (pos + 1 < limit && b[pos + 1] == 0x3C) return _dict();
      return _hexString();
    }
    if (c == 0x5B) {
      pos++;
      final list = <Object?>[];
      while (true) {
        skipSpace();
        if (pos >= limit) throw const _Unsupported();
        if (b[pos] == 0x5D) {
          pos++;
          return list;
        }
        list.add(value());
      }
    }
    if (_isNumberStart(c)) {
      final n = _number();
      if (refs && n is int) {
        // `12 0 R`: look ahead without committing.
        final save = pos;
        skipSpace();
        if (pos < limit && _isDigit(b[pos])) {
          final gen = _number();
          skipSpace();
          if (gen is int && keywordAhead('R')) {
            pos++;
            return _Ref(n);
          }
        }
        pos = save;
      }
      return n;
    }
    final word = _regular();
    if (word.isEmpty) throw const _Unsupported();
    return switch (word) {
      'true' => true,
      'false' => false,
      'null' => null,
      _ => _Keyword(word),
    };
  }

  _Dict _dict() {
    pos += 2;
    final dict = _Dict();
    while (true) {
      skipSpace();
      if (pos + 1 < limit && b[pos] == 0x3E && b[pos + 1] == 0x3E) {
        pos += 2;
        return dict;
      }
      if (pos >= limit || b[pos] != 0x2F) throw const _Unsupported();
      final key = _name();
      skipSpace();
      final start = pos;
      final v = value();
      dict._values[key] = v;
      dict._spans[key] = (start, pos);
    }
  }

  String _name() {
    pos++;
    final bytes = <int>[];
    while (pos < limit) {
      final c = b[pos];
      if (_isSpace(c) || _isDelimiter(c)) break;
      if (c == 0x23 && pos + 2 < limit) {
        final hex = int.tryParse(
          latin1.decode([b[pos + 1], b[pos + 2]]),
          radix: 16,
        );
        if (hex != null) {
          bytes.add(hex);
          pos += 3;
          continue;
        }
      }
      bytes.add(c);
      pos++;
    }
    return latin1.decode(bytes);
  }

  String _regular() {
    final start = pos;
    while (pos < limit && !_isSpace(b[pos]) && !_isDelimiter(b[pos])) {
      pos++;
    }
    return latin1.decode(Uint8List.sublistView(b, start, pos));
  }

  num _number() {
    final word = _regular();
    return int.tryParse(word) ??
        double.tryParse(word) ??
        (throw const _Unsupported());
  }

  String _literalString() {
    pos++;
    var depth = 1;
    final start = pos;
    while (pos < limit) {
      final c = b[pos++];
      if (c == 0x5C) {
        pos++; // whatever is escaped, it isn't a bracket
      } else if (c == 0x28) {
        depth++;
      } else if (c == 0x29 && --depth == 0) {
        return latin1.decode(Uint8List.sublistView(b, start, pos - 1));
      }
    }
    throw const _Unsupported();
  }

  String _hexString() {
    final end = _indexOf(b, const [0x3E], pos, limit);
    if (end < 0) throw const _Unsupported();
    final s = latin1.decode(Uint8List.sublistView(b, pos + 1, end));
    pos = end + 1;
    return s;
  }

  static bool _isDigit(int c) => c >= 0x30 && c <= 0x39;
  static bool _isNumberStart(int c) =>
      _isDigit(c) || c == 0x2B || c == 0x2D || c == 0x2E;
}

/// What the start of a JPEG says about it.
class JpegInfo {
  final int width;
  final int height;
  final int components;
  const JpegInfo(this.width, this.height, this.components);
}

/// Reads a JPEG's frame header, or returns null if [b] isn't a JPEG.
JpegInfo? jpegInfo(Uint8List b) {
  if (b.length < 4 || b[0] != 0xFF || b[1] != 0xD8) return null;
  var p = 2;
  while (p + 3 < b.length) {
    if (b[p] != 0xFF) return null;
    final marker = b[p + 1];
    if (marker == 0xFF) {
      p++;
      continue;
    }
    if (marker == 0xD8 ||
        marker == 0x01 ||
        (marker >= 0xD0 && marker <= 0xD7)) {
      p += 2;
      continue;
    }
    final length = (b[p + 2] << 8) | b[p + 3];
    final isFrame =
        marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC;
    if (isFrame) {
      if (p + 9 >= b.length) return null;
      return JpegInfo(
        (b[p + 7] << 8) | b[p + 8],
        (b[p + 5] << 8) | b[p + 6],
        b[p + 9],
      );
    }
    if (marker == 0xDA) return null;
    p += 2 + length;
  }
  return null;
}

/// The JPEG without its EXIF block. A PDF ignores a picture's EXIF rotation,
/// but a re-encoder honours it, and a scan turned on its side is worse than
/// a scan left large.
Uint8List _withoutExif(Uint8List b) {
  final out = BytesBuilder(copy: false)..add(Uint8List.sublistView(b, 0, 2));
  var p = 2;
  while (p + 3 < b.length && b[p] == 0xFF) {
    final marker = b[p + 1];
    if (marker == 0xDA) break;
    final end = p + 2 + ((b[p + 2] << 8) | b[p + 3]);
    if (end > b.length) return b;
    if (marker != 0xE1) out.add(Uint8List.sublistView(b, p, end));
    p = end;
  }
  out.add(Uint8List.sublistView(b, p));
  return out.takeBytes();
}

int _startXref(Uint8List pdf) {
  final from = pdf.length > 4096 ? pdf.length - 4096 : 0;
  final at = _lastIndexOf(pdf, _ascii('startxref'), from, pdf.length);
  if (at < 0) throw const _Unsupported();
  final v = _Lexer(pdf, at + 9, pdf.length).value(refs: false);
  if (v is! int) throw const _Unsupported();
  return v;
}

bool _isSpace(int c) =>
    c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0x0C || c == 0x00;

bool _isDelimiter(int c) =>
    c == 0x28 ||
    c == 0x29 ||
    c == 0x3C ||
    c == 0x3E ||
    c == 0x5B ||
    c == 0x5D ||
    c == 0x7B ||
    c == 0x7D ||
    c == 0x2F ||
    c == 0x25;

Uint8List _ascii(String s) => latin1.encode(s);

Uint8List _concat(List<List<int>> parts) {
  final out = BytesBuilder(copy: false);
  parts.forEach(out.add);
  return out.takeBytes();
}

bool _startsWithAt(Uint8List b, int at, List<int> sig) {
  if (at < 0 || at + sig.length > b.length) return false;
  for (var i = 0; i < sig.length; i++) {
    if (b[at + i] != sig[i]) return false;
  }
  return true;
}

int _indexOf(Uint8List b, List<int> sig, int from, int to) {
  for (var i = from; i + sig.length <= to; i++) {
    if (b[i] == sig[0] && _startsWithAt(b, i, sig)) return i;
  }
  return -1;
}

int _lastIndexOf(Uint8List b, List<int> sig, int from, int to) {
  for (var i = to - sig.length; i >= from; i--) {
    if (b[i] == sig[0] && _startsWithAt(b, i, sig)) return i;
  }
  return -1;
}
