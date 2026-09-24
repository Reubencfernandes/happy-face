import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'paths.dart';

const _channel = MethodChannel('happy_drive/device');

/// How full the phone is.
class DeviceStorage {
  final int total;
  final int free;
  const DeviceStorage({required this.total, required this.free});

  int get used => total - free;
}

/// What Happy Drive itself keeps on the phone.
class AppStorage {
  /// The local copy of the catalogue: what's backed up, places, weather.
  final int library;

  /// Encrypted thumbnails, kept so scrolling doesn't re-download them.
  final int thumbnails;

  /// Downloads being played or opened, and other short-lived files.
  final int temporary;

  const AppStorage({
    required this.library,
    required this.thumbnails,
    required this.temporary,
  });

  int get total => library + thumbnails + temporary;
}

/// The phone's own storage figures, or null where the platform won't say.
Future<DeviceStorage?> deviceStorage() async {
  try {
    final r = await _channel.invokeMapMethod<String, int>('storage');
    final total = r?['total'], free = r?['free'];
    if (total == null || free == null || total <= 0) return null;
    return DeviceStorage(total: total, free: free.clamp(0, total));
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}

/// Adds up the files Happy Drive keeps, by walking its folders.
Future<AppStorage> appStorage({
  Future<Directory> Function() data = appDataDir,
  Future<Directory> Function() temp = getTemporaryDirectory,
}) async {
  var library = 0, thumbnails = 0;
  final dir = await data();
  if (await dir.exists()) {
    await for (final entry in dir.list(followLinks: false)) {
      final name = entry.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final size = await _sizeOf(entry);
      if (name.startsWith('thumbs_')) {
        thumbnails += size;
      } else {
        library += size;
      }
    }
  }
  final tmp = await temp();
  final temporary = await tmp.exists() ? await _sizeOf(tmp) : 0;
  return AppStorage(
    library: library,
    thumbnails: thumbnails,
    temporary: temporary,
  );
}

Future<int> _sizeOf(FileSystemEntity entity) async {
  try {
    if (entity is File) return await entity.length();
    if (entity is! Directory) return 0;
    var sum = 0;
    await for (final f in entity.list(recursive: true, followLinks: false)) {
      if (f is File) {
        try {
          sum += await f.length();
        } on FileSystemException {
          // Deleted while we looked: it takes no room now.
        }
      }
    }
    return sum;
  } on FileSystemException {
    return 0;
  }
}

/// Pages of a PDF on disk, drawn by the phone's own PDF renderer.
class PdfPages {
  final String path;
  PdfPages(this.path);

  Future<int> count() async =>
      await _channel.invokeMethod<int>('pdfPageCount', {'path': path}) ?? 0;

  /// Page [index] (from 0) as a JPEG [width] pixels across.
  Future<Uint8List?> render(int index, {required int width}) =>
      _channel.invokeMethod<Uint8List>('pdfRenderPage', {
        'path': path,
        'page': index,
        'width': width,
      });

  Future<void> close() async {
    try {
      await _channel.invokeMethod<void>('pdfClose');
    } catch (_) {}
  }
}
