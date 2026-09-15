import 'dart:convert';

/// Identifies an image from its first bytes rather than trusting the file
/// extension. Returns null for anything that isn't a supported photo.
String? sniffImageMime(List<int> bytes) {
  bool startsWith(List<int> sig, [int offset = 0]) {
    if (bytes.length < offset + sig.length) return false;
    for (var i = 0; i < sig.length; i++) {
      if (bytes[offset + i] != sig[i]) return false;
    }
    return true;
  }

  String ascii4(int offset) => bytes.length < offset + 4
      ? ''
      : latin1.decode(bytes.sublist(offset, offset + 4));

  if (startsWith([0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  if (startsWith([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return 'image/png';
  }
  if (startsWith(ascii.encode('GIF87a')) ||
      startsWith(ascii.encode('GIF89a'))) {
    return 'image/gif';
  }
  if (ascii4(0) == 'RIFF' && ascii4(8) == 'WEBP') return 'image/webp';
  // ISO-BMFF: size(4) 'ftyp' brand(4). iPhones save HEIC.
  if (ascii4(4) == 'ftyp') {
    final brand = ascii4(8);
    if (const {
      'heic',
      'heix',
      'hevc',
      'hevx',
      'heim',
      'heis',
    }.contains(brand)) {
      return 'image/heic';
    }
    if (const {'mif1', 'msf1'}.contains(brand)) return 'image/heif';
    if (const {'avif', 'avis'}.contains(brand)) return 'image/avif';
  }
  return null;
}

String extensionForMime(String mime) => switch (mime) {
  'image/jpeg' => 'jpg',
  'image/png' => 'png',
  'image/gif' => 'gif',
  'image/webp' => 'webp',
  'image/heic' => 'heic',
  'image/heif' => 'heif',
  'image/avif' => 'avif',
  _ => 'bin',
};
