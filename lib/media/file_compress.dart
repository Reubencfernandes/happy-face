import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path_provider/path_provider.dart';

import 'compress.dart';
import 'image_type.dart';
import 'pdf_shrink.dart';

/// A file made smaller, and what kind of file it is now.
class ShrunkFile {
  final Uint8List bytes;
  final String mime;
  const ShrunkFile(this.bytes, this.mime);
}

/// Makes the files that aren't photos smaller: sound and PDFs. Abstract so
/// tests and platforms without the native side can swap it.
abstract class FileCodec {
  /// Whether this is a kind of file [compress] knows how to shrink.
  static bool handles(String mime) =>
      mime.startsWith('audio/') || mime == 'application/pdf';

  /// Returns a smaller copy, or null to keep the original.
  Future<ShrunkFile?> compress(
    Uint8List bytes, {
    required String mime,
    required String name,
    required Compression level,
  });
}

class NativeFileCodec implements FileCodec {
  const NativeFileCodec();

  static const _channel = MethodChannel('happy_drive/media');

  /// AAC bit rates per channel, so a mono voice memo isn't given a music
  /// track's budget. High is indistinguishable from the original to most
  /// ears; Balanced is still clean for music and plenty for speech.
  static const _audioBitsPerChannel = {
    Compression.high: 80000,
    Compression.balanced: 48000,
  };

  @override
  Future<ShrunkFile?> compress(
    Uint8List bytes, {
    required String mime,
    required String name,
    required Compression level,
  }) async {
    if (level == Compression.original) return null;
    if (mime == 'application/pdf') {
      final out = await shrinkPdf(bytes, (jpeg) => _reencodeJpeg(jpeg, level));
      return out == null ? null : ShrunkFile(out, mime);
    }
    if (mime.startsWith('audio/')) {
      final out = await _transcodeAudio(bytes, mime, name, level);
      return out == null ? null : ShrunkFile(out, 'audio/mp4');
    }
    return null;
  }

  /// A picture inside a PDF. Balanced brings pages down to about 150 dpi,
  /// which is still crisp on a phone and on paper.
  static Future<Uint8List?> _reencodeJpeg(
    Uint8List jpeg,
    Compression level,
  ) async {
    final balanced = level == Compression.balanced;
    try {
      final out = await FlutterImageCompress.compressWithList(
        jpeg,
        // The plugin only ever scales down, so huge minimums keep full size.
        minWidth: balanced ? 1240 : 100000,
        minHeight: balanced ? 1240 : 100000,
        quality: balanced ? 70 : 80,
        // A PDF places the raw pixels and ignores EXIF rotation; turning
        // them here would turn the page.
        autoCorrectionAngle: false,
      );
      return out.isEmpty ? null : out;
    } catch (_) {
      return null;
    }
  }

  /// Re-encodes sound as AAC in an .m4a, using the phone's own encoder.
  ///
  /// The platform works on files, so the bytes take a short trip through
  /// the cache folder and are deleted straight after, whatever happens.
  static Future<Uint8List?> _transcodeAudio(
    Uint8List bytes,
    String mime,
    String name,
    Compression level,
  ) async {
    final bits = _audioBitsPerChannel[level];
    if (bits == null) return null;
    final dir = await _workDir();
    final stem =
        '${DateTime.now().microsecondsSinceEpoch}_'
        '${Random().nextInt(1 << 32)}';
    // The extension matters on iOS, which picks the decoder by it.
    final dot = name.lastIndexOf('.');
    final ext = dot > 0 && dot < name.length - 1
        ? name.substring(dot + 1).toLowerCase()
        : extensionForMime(mime);
    final input = File('${dir.path}/$stem.$ext');
    final output = File('${dir.path}/$stem.out.m4a');
    try {
      await input.writeAsBytes(bytes, flush: true);
      final ok = await _channel.invokeMethod<bool>('transcodeAudio', {
        'input': input.path,
        'output': output.path,
        'bitsPerChannel': bits,
      });
      if (ok != true || !await output.exists()) return null;
      final out = await output.readAsBytes();
      return out.isEmpty ? null : out;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    } finally {
      for (final f in [input, output]) {
        try {
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
  }

  static Future<Directory>? _dir;

  /// The folder files are converted in. Anything a crash left there last
  /// time is cleared out the first time it is used.
  static Future<Directory> _workDir() => _dir ??= () async {
    final dir = Directory('${(await getTemporaryDirectory()).path}/shrinking');
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
    return dir.create(recursive: true);
  }();
}
