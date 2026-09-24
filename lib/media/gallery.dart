import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

import '../data/local_db.dart';
import '../sync/uploader.dart';
import 'metadata.dart';

/// The phone's photo and video library, via photo_manager.
class Gallery {
  const Gallery();

  /// Photos and videos both, so a backup isn't half the memory.
  static const _types = RequestType.common;

  static const _permission = PermissionRequestOption(
    androidPermission: AndroidPermission(
      type: _types,
      // Without this Android 10+ hands us photos with GPS stripped.
      mediaLocation: true,
    ),
  );

  Future<PermissionState> requestAccess() =>
      PhotoManager.requestPermissionExtend(requestOption: _permission);

  Future<PermissionState> currentAccess() =>
      PhotoManager.getPermissionState(requestOption: _permission);

  Future<void> openSettings() => PhotoManager.openSetting();

  /// Lists every photo and video on the phone (dates only; nothing is read).
  Future<List<DeviceAsset>> scan() async {
    final paths = await PhotoManager.getAssetPathList(
      type: _types,
      onlyAll: true,
    );
    if (paths.isEmpty) return const [];
    final all = paths.first;
    final count = await all.assetCountAsync;
    final out = <DeviceAsset>[];
    const page = 500;
    for (var start = 0; start < count; start += page) {
      final assets = await all.getAssetListRange(
        start: start,
        end: start + page > count ? count : start + page,
      );
      for (final a in assets) {
        final created = a.createDateTime;
        out.add(
          DeviceAsset(
            assetId: a.id,
            takenAt: created.toUtc(),
            tzOffsetMinutes: created.timeZoneOffset.inMinutes,
            modifiedAt: a.modifiedDateTime.toUtc(),
            isVideo: a.type == AssetType.video,
          ),
        );
      }
    }
    return out;
  }

  Future<Uint8List?> thumbnail(String assetId, {int size = 400}) async {
    final asset = await AssetEntity.fromId(assetId);
    return asset?.thumbnailDataWithSize(
      ThumbnailSize.square(size),
      quality: 80,
    );
  }

  Future<Uint8List?> original(String assetId) async {
    final asset = await AssetEntity.fromId(assetId);
    return asset?.originBytes;
  }

  /// The phone's own copy, for a player that wants a path rather than bytes.
  /// Null when the photo lives in iCloud and isn't downloaded.
  Future<File?> fileFor(String assetId) async {
    final asset = await AssetEntity.fromId(assetId);
    return asset?.file;
  }

  Future<UploadSource?> sourceFor(String assetId) async {
    final asset = await AssetEntity.fromId(assetId);
    if (asset == null) return null;
    final latLng = await asset.latlngAsync();
    final created = asset.createDateTime;
    // Asked of the file system before anything is read. Without it a 2 GB
    // video is discovered to be 2 GB only once it is already in memory, by
    // which time the app has been killed.
    int? bytes;
    try {
      bytes = await asset.fileSize;
    } catch (_) {
      // Unknown: the uploader checks again once it has the file.
    }
    double? coordinate(double? v) => v == null || v == 0 ? null : v;
    return UploadSource(
      name: await asset.titleAsync,
      assetId: asset.id,
      size: bytes,
      read: () async {
        final bytes = await asset.originBytes;
        if (bytes == null) {
          throw const FormatException(
            'This photo is not on the phone (it may be in iCloud only).',
          );
        }
        return bytes;
      },
      // The untouched original, as [read] gives, for files too big to read
      // in one go. On iPhone this can download it from iCloud first.
      file: () => asset.originFile,
      thumbnail: () => asset.thumbnailDataWithSize(
        const ThumbnailSize.square(400),
        quality: 80,
      ),
      known: PhotoMetadata(
        takenAt: created.toUtc(),
        tzOffsetMinutes: created.timeZoneOffset.inMinutes,
        lat: coordinate(latLng?.latitude),
        lng: coordinate(latLng?.longitude),
        width: asset.width == 0 ? null : asset.width,
        height: asset.height == 0 ? null : asset.height,
      ),
    );
  }

  /// Deletes photos and videos from the phone's library. The phone asks the
  /// person to confirm first (iOS always, Android 11 and later), so this
  /// returns only the ids that actually went.
  Future<Set<String>> deleteFromPhone(List<String> assetIds) async {
    if (assetIds.isEmpty) return const {};
    final gone = await PhotoManager.editor.deleteWithIds(assetIds);
    return gone.toSet();
  }

  /// Like [saveToPhone], from a file on disk rather than bytes in memory.
  Future<String> saveFileToPhone(
    File file,
    String filename, {
    String? mime,
  }) async {
    switch (mediaKindOf(mime)) {
      case MediaKind.image:
        await PhotoManager.editor.saveImageWithPath(file.path, title: filename);
        return 'your photos';
      case MediaKind.video:
        await PhotoManager.editor.saveVideo(file, title: filename);
        return 'your videos';
      case MediaKind.file:
        final dir = Platform.isAndroid
            ? await getExternalStorageDirectory() ??
                  await getApplicationDocumentsDirectory()
            : await getApplicationDocumentsDirectory();
        return (await file.copy('${dir.path}/$filename')).path;
    }
  }

  /// Puts a photo or video back in the phone's library, and anything else
  /// in the app's own folder. Returns where it landed, for the message.
  Future<String> saveToPhone(
    Uint8List bytes,
    String filename, {
    String? mime,
  }) async {
    switch (mediaKindOf(mime)) {
      case MediaKind.image:
        await PhotoManager.editor.saveImage(bytes, filename: filename);
        return 'your photos';
      case MediaKind.video:
        // saveVideo wants a file, so the bytes take a short detour.
        final temp = File('${(await getTemporaryDirectory()).path}/$filename');
        await temp.writeAsBytes(bytes);
        try {
          await PhotoManager.editor.saveVideo(temp, title: filename);
        } finally {
          await temp.delete().catchError((_) => temp);
        }
        return 'your videos';
      case MediaKind.file:
        final dir = Platform.isAndroid
            ? await getExternalStorageDirectory() ??
                  await getApplicationDocumentsDirectory()
            : await getApplicationDocumentsDirectory();
        final out = File('${dir.path}/$filename');
        await out.writeAsBytes(bytes);
        return out.path;
    }
  }
}
