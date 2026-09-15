import 'dart:typed_data';

import 'package:flutter_image_compress/flutter_image_compress.dart';

enum Compression {
  /// Untouched bytes.
  original('Original', 'Exactly what the camera saved'),

  /// Re-encoded at high quality, full resolution. Typically 40-60% smaller.
  high('High', 'Full size, visually identical, much smaller'),

  /// Shortest side about 1920 px. Great on phones and TVs, a fraction of
  /// the size.
  balanced('Balanced', 'Smaller size, still sharp on any screen');

  final String label;
  final String description;
  const Compression(this.label, this.description);

  static Compression parse(String? name) =>
      values.firstWhere((c) => c.name == name, orElse: () => original);
}

/// Re-encodes photos. Abstract so tests and platforms without the native
/// plugin can swap it.
abstract class ImageCodec {
  /// Returns re-encoded JPEG bytes, or null if this image can't be processed.
  Future<Uint8List?> compress(Uint8List bytes, Compression level);

  /// A small JPEG for the timeline grid.
  Future<Uint8List?> thumbnail(Uint8List bytes, {int size = 400});
}

class NativeImageCodec implements ImageCodec {
  const NativeImageCodec();

  @override
  Future<Uint8List?> compress(Uint8List bytes, Compression level) async {
    if (level == Compression.original) return bytes;
    try {
      final out = await FlutterImageCompress.compressWithList(
        bytes,
        // The plugin only ever scales down, so huge minimums keep full size.
        minWidth: level == Compression.balanced ? 1920 : 100000,
        minHeight: level == Compression.balanced ? 1920 : 100000,
        quality: level == Compression.balanced ? 80 : 90,
        keepExif: true,
      );
      return out.isEmpty ? null : out;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Uint8List?> thumbnail(Uint8List bytes, {int size = 400}) async {
    try {
      final out = await FlutterImageCompress.compressWithList(
        bytes,
        minWidth: size,
        minHeight: size,
        quality: 75,
      );
      return out.isEmpty ? null : out;
    } catch (_) {
      return null;
    }
  }
}
