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
  'video/mp4' => 'mp4',
  'video/quicktime' => 'mov',
  'video/webm' => 'webm',
  'video/x-matroska' => 'mkv',
  'video/x-msvideo' => 'avi',
  'video/3gpp' => '3gp',
  'audio/mpeg' => 'mp3',
  'audio/mp4' => 'm4a',
  'audio/ogg' => 'ogg',
  'audio/flac' => 'flac',
  'audio/wav' => 'wav',
  'application/pdf' => 'pdf',
  'application/zip' => 'zip',
  'text/plain' => 'txt',
  _ => 'bin',
};

/// What the file name says it is, for the formats sniffing can't name.
const _byExtension = {
  'mp4': 'video/mp4',
  'm4v': 'video/mp4',
  'mov': 'video/quicktime',
  'webm': 'video/webm',
  'mkv': 'video/x-matroska',
  'avi': 'video/x-msvideo',
  '3gp': 'video/3gpp',
  'mp3': 'audio/mpeg',
  'm4a': 'audio/mp4',
  'aac': 'audio/aac',
  'ogg': 'audio/ogg',
  'flac': 'audio/flac',
  'wav': 'audio/wav',
  'pdf': 'application/pdf',
  'zip': 'application/zip',
  'txt': 'text/plain',
  'md': 'text/markdown',
  'csv': 'text/csv',
  'json': 'application/json',
  'doc': 'application/msword',
  'docx':
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'xls': 'application/vnd.ms-excel',
  'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'ppt': 'application/vnd.ms-powerpoint',
  'pptx':
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
};

/// Identifies anything Happy Drive is asked to store: a photo, a video, or
/// any other file. Sniffing wins over the file name, which can lie; a name
/// with a known extension is the fallback, and anything else is stored as
/// plain bytes rather than refused.
String sniffMime(List<int> bytes, {String? name}) =>
    sniffImageMime(bytes) ??
    _sniffOtherMime(bytes) ??
    mimeForName(name) ??
    'application/octet-stream';

/// The mime a file name implies, or null when its extension is unknown.
String? mimeForName(String? name) {
  final dot = name?.lastIndexOf('.') ?? -1;
  if (name == null || dot < 0 || dot == name.length - 1) return null;
  return _byExtension[name.substring(dot + 1).toLowerCase()];
}

String? _sniffOtherMime(List<int> bytes) {
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

  // ISO-BMFF again, this time the brands that mean moving pictures.
  if (ascii4(4) == 'ftyp') {
    final brand = ascii4(8);
    if (brand == 'qt  ') return 'video/quicktime';
    if (brand == 'M4A ') return 'audio/mp4';
    if (brand.startsWith('3g')) return 'video/3gpp';
    return 'video/mp4';
  }
  if (ascii4(4) == 'moov' || ascii4(4) == 'mdat') return 'video/quicktime';
  if (startsWith([0x1A, 0x45, 0xDF, 0xA3])) {
    final head = latin1.decode(
      bytes.sublist(0, bytes.length < 64 ? bytes.length : 64),
    );
    return head.contains('webm') ? 'video/webm' : 'video/x-matroska';
  }
  if (ascii4(0) == 'RIFF') {
    final kind = ascii4(8);
    if (kind == 'AVI ') return 'video/x-msvideo';
    if (kind == 'WAVE') return 'audio/wav';
  }
  if (startsWith(ascii.encode('ID3'))) return 'audio/mpeg';
  if (ascii4(0) == 'OggS') return 'audio/ogg';
  if (ascii4(0) == 'fLaC') return 'audio/flac';
  if (startsWith(ascii.encode('%PDF'))) return 'application/pdf';
  if (startsWith([0x50, 0x4B, 0x03, 0x04])) return 'application/zip';
  return null;
}
