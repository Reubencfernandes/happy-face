import 'package:exif/exif.dart';

/// What we learn about a photo from its own bytes.
class PhotoMetadata {
  /// UTC instant the photo was taken, if the file records it.
  final DateTime? takenAt;

  /// UTC offset of the camera, in minutes.
  final int? tzOffsetMinutes;
  final double? lat;
  final double? lng;
  final int? width;
  final int? height;

  const PhotoMetadata({
    this.takenAt,
    this.tzOffsetMinutes,
    this.lat,
    this.lng,
    this.width,
    this.height,
  });

  static const empty = PhotoMetadata();

  /// Prefers values from this instance, filling gaps from [other].
  PhotoMetadata orElse(PhotoMetadata other) => PhotoMetadata(
    takenAt: takenAt ?? other.takenAt,
    tzOffsetMinutes: takenAt != null ? tzOffsetMinutes : other.tzOffsetMinutes,
    lat: lat ?? other.lat,
    lng: lng ?? other.lng,
    width: width ?? other.width,
    height: height ?? other.height,
  );
}

/// Returns the phone's UTC offset (minutes) at a given local wall-clock time.
typedef ZoneGuess = int Function(DateTime wallClock);

int deviceZoneGuess(DateTime wall) => DateTime(
  wall.year,
  wall.month,
  wall.day,
  wall.hour,
  wall.minute,
  wall.second,
).timeZoneOffset.inMinutes;

/// Reads date, time zone, GPS and size from a photo's EXIF block.
/// Never throws: unreadable metadata just yields [PhotoMetadata.empty].
Future<PhotoMetadata> readPhotoMetadata(
  List<int> bytes, {
  ZoneGuess zoneGuess = deviceZoneGuess,
}) async {
  try {
    final tags = await readExifFromBytes(bytes, details: false);
    return metadataFromTags(tags, zoneGuess: zoneGuess);
  } catch (_) {
    return PhotoMetadata.empty;
  }
}

PhotoMetadata metadataFromTags(
  Map<String, IfdTag> tags, {
  ZoneGuess zoneGuess = deviceZoneGuess,
}) {
  String? text(String key) {
    final v = tags[key]?.printable.trim();
    return v == null || v.isEmpty ? null : v;
  }

  int? integer(String key) {
    final values = tags[key]?.values.toList();
    if (values == null || values.isEmpty) return null;
    final v = values.first;
    return v is int ? v : int.tryParse('$v');
  }

  final wall = parseExifDateTime(
    text('EXIF DateTimeOriginal') ??
        text('EXIF DateTimeDigitized') ??
        text('Image DateTime'),
  );
  var offset = parseExifOffset(
    text('EXIF OffsetTimeOriginal') ?? text('EXIF OffsetTime'),
  );
  DateTime? takenAt;
  if (wall != null) {
    offset ??= zoneGuess(wall);
    takenAt = wall.subtract(Duration(minutes: offset));
  }

  return PhotoMetadata(
    takenAt: takenAt,
    tzOffsetMinutes: wall == null ? null : offset,
    lat: gpsToDecimal(
      tags['GPS GPSLatitude']?.values.toList(),
      text('GPS GPSLatitudeRef'),
    ),
    lng: gpsToDecimal(
      tags['GPS GPSLongitude']?.values.toList(),
      text('GPS GPSLongitudeRef'),
    ),
    width: integer('EXIF ExifImageWidth') ?? integer('Image ImageWidth'),
    height: integer('EXIF ExifImageLength') ?? integer('Image ImageLength'),
  );
}

/// Parses EXIF `YYYY:MM:DD HH:MM:SS` as a wall-clock time, stored in a UTC
/// DateTime so the fields stay exactly as written.
DateTime? parseExifDateTime(String? value) {
  if (value == null) return null;
  final m = RegExp(
    r'^(\d{4})[:\-](\d{2})[:\-](\d{2})[ T](\d{2}):(\d{2}):(\d{2})',
  ).firstMatch(value);
  if (m == null) return null;
  final parts = [for (var i = 1; i <= 6; i++) int.parse(m.group(i)!)];
  if (parts[0] < 1900 || parts[1] == 0 || parts[2] == 0) return null;
  return DateTime.utc(
    parts[0],
    parts[1],
    parts[2],
    parts[3],
    parts[4],
    parts[5],
  );
}

/// Parses EXIF `+05:30` / `-08:00` into minutes.
int? parseExifOffset(String? value) {
  if (value == null) return null;
  final m = RegExp(r'^([+-])(\d{2}):?(\d{2})$').firstMatch(value.trim());
  if (m == null) return null;
  final minutes = int.parse(m.group(2)!) * 60 + int.parse(m.group(3)!);
  if (minutes > 14 * 60) return null;
  return m.group(1) == '-' ? -minutes : minutes;
}

/// Converts EXIF degrees/minutes/seconds rationals to signed decimal degrees.
double? gpsToDecimal(List<dynamic>? dms, String? ref) {
  if (dms == null || dms.length < 3 || ref == null) return null;
  double part(dynamic v) {
    if (v is Ratio)
      return v.denominator == 0 ? double.nan : v.numerator / v.denominator;
    if (v is num) return v.toDouble();
    return double.nan;
  }

  final value = part(dms[0]) + part(dms[1]) / 60 + part(dms[2]) / 3600;
  if (value.isNaN || value > 180) return null;
  final signed = (ref.startsWith('S') || ref.startsWith('W')) ? -value : value;
  // 0,0 is what broken cameras write when they have no fix.
  if (signed == 0) return null;
  return double.parse(signed.toStringAsFixed(6));
}
