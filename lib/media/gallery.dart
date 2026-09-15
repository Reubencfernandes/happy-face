import 'dart:typed_data';

import 'package:photo_manager/photo_manager.dart';

import '../data/local_db.dart';
import '../sync/uploader.dart';
import 'metadata.dart';

/// The phone's photo library, via photo_manager.
class Gallery {
  const Gallery();

  static const _permission = PermissionRequestOption(
    androidPermission: AndroidPermission(
      type: RequestType.image,
      // Without this Android 10+ hands us photos with GPS stripped.
      mediaLocation: true,
    ),
  );

  Future<PermissionState> requestAccess() =>
      PhotoManager.requestPermissionExtend(requestOption: _permission);

  Future<PermissionState> currentAccess() =>
      PhotoManager.getPermissionState(requestOption: _permission);

  Future<void> openSettings() => PhotoManager.openSetting();

  /// Lists every photo on the phone (dates only; nothing is read).
  Future<List<DeviceAsset>> scan() async {
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.image,
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

  Future<UploadSource?> sourceFor(String assetId) async {
    final asset = await AssetEntity.fromId(assetId);
    if (asset == null) return null;
    final latLng = await asset.latlngAsync();
    final created = asset.createDateTime;
    double? coordinate(double? v) => v == null || v == 0 ? null : v;
    return UploadSource(
      name: await asset.titleAsync,
      assetId: asset.id,
      read: () async {
        final bytes = await asset.originBytes;
        if (bytes == null) {
          throw const FormatException(
            'This photo is not on the phone (it may be in iCloud only).',
          );
        }
        return bytes;
      },
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

  Future<void> saveToPhone(Uint8List bytes, String filename) async {
    await PhotoManager.editor.saveImage(bytes, filename: filename);
  }
}
