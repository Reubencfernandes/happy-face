/// The library catalogue: one record per photo, changed only through ops so
/// that several devices can edit it and still converge.
library;

class PhotoRecord {
  final String id;
  final String name;
  final String mime;

  /// Size in bytes of the stored (possibly compressed) original, unencrypted.
  final int size;
  final int? width;
  final int? height;

  /// When the photo was taken, in UTC.
  final DateTime takenAt;

  /// The camera's UTC offset in minutes, so day headers match local time.
  final int? tzOffsetMinutes;
  final DateTime uploadedAt;

  /// `original`, `high` or `balanced`.
  final String compression;
  final double? lat;
  final double? lng;

  /// Enrichment filled in after upload.
  final String? place;
  final String? country;
  final Map<String, dynamic>? weather;

  const PhotoRecord({
    required this.id,
    required this.name,
    required this.mime,
    required this.size,
    required this.takenAt,
    required this.uploadedAt,
    this.width,
    this.height,
    this.tzOffsetMinutes,
    this.compression = 'original',
    this.lat,
    this.lng,
    this.place,
    this.country,
    this.weather,
  });

  bool get hasLocation => lat != null && lng != null;

  /// Taken-at time in the photo's own time zone (falls back to UTC).
  DateTime get localTakenAt =>
      takenAt.add(Duration(minutes: tzOffsetMinutes ?? 0));

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'mime': mime,
    'size': size,
    'takenAt': takenAt.millisecondsSinceEpoch,
    'uploadedAt': uploadedAt.millisecondsSinceEpoch,
    'w': ?width,
    'h': ?height,
    'tz': ?tzOffsetMinutes,
    'comp': compression,
    'lat': ?lat,
    'lng': ?lng,
    'place': ?place,
    'country': ?country,
    'weather': ?weather,
  };

  factory PhotoRecord.fromJson(Map<String, dynamic> j) => PhotoRecord(
    id: j['id'] as String,
    name: j['name'] as String,
    mime: j['mime'] as String,
    size: j['size'] as int,
    takenAt: DateTime.fromMillisecondsSinceEpoch(
      j['takenAt'] as int,
      isUtc: true,
    ),
    uploadedAt: DateTime.fromMillisecondsSinceEpoch(
      j['uploadedAt'] as int,
      isUtc: true,
    ),
    width: j['w'] as int?,
    height: j['h'] as int?,
    tzOffsetMinutes: j['tz'] as int?,
    compression: j['comp'] as String? ?? 'original',
    lat: (j['lat'] as num?)?.toDouble(),
    lng: (j['lng'] as num?)?.toDouble(),
    place: j['place'] as String?,
    country: j['country'] as String?,
    weather: (j['weather'] as Map?)?.cast<String, dynamic>(),
  );

  /// Applies a patch: present keys overwrite, `null` values clear the field.
  /// Identity fields (`id`) cannot be patched.
  PhotoRecord patched(Map<String, dynamic> fields) {
    final j = toJson()..addAll(fields);
    j['id'] = id;
    j.removeWhere((_, v) => v == null);
    return PhotoRecord.fromJson(j);
  }
}

sealed class CatalogueOp {
  final String id;

  /// Milliseconds since epoch on the device that made the change.
  final int at;
  const CatalogueOp(this.id, this.at);

  Map<String, dynamic> toJson();

  static CatalogueOp fromJson(Map<String, dynamic> j) => switch (j['op']) {
    'put' => PutOp(
      PhotoRecord.fromJson((j['rec'] as Map).cast<String, dynamic>()),
      j['at'] as int,
    ),
    'patch' => PatchOp(
      j['id'] as String,
      (j['fields'] as Map).cast<String, dynamic>(),
      j['at'] as int,
    ),
    'del' => DeleteOp(j['id'] as String, j['at'] as int),
    _ => throw FormatException('Unknown catalogue op ${j['op']}'),
  };
}

class PutOp extends CatalogueOp {
  final PhotoRecord record;
  PutOp(this.record, int at) : super(record.id, at);
  @override
  Map<String, dynamic> toJson() => {
    'op': 'put',
    'at': at,
    'rec': record.toJson(),
  };
}

class PatchOp extends CatalogueOp {
  final Map<String, dynamic> fields;
  const PatchOp(super.id, this.fields, super.at);
  @override
  Map<String, dynamic> toJson() => {
    'op': 'patch',
    'at': at,
    'id': id,
    'fields': fields,
  };
}

class DeleteOp extends CatalogueOp {
  const DeleteOp(super.id, super.at);
  @override
  Map<String, dynamic> toJson() => {'op': 'del', 'at': at, 'id': id};
}

/// In-memory catalogue state plus the merge rules.
class Catalogue {
  final Map<String, PhotoRecord> records;

  /// Deleted id → time of deletion. Stops a stale `put` from resurrecting a
  /// photo that another device deleted later.
  final Map<String, int> tombstones;

  Catalogue({Map<String, PhotoRecord>? records, Map<String, int>? tombstones})
    : records = records ?? {},
      tombstones = tombstones ?? {};

  /// Applies [op] and returns true if anything changed.
  bool apply(CatalogueOp op) {
    switch (op) {
      case PutOp(:final record):
        if ((tombstones[op.id] ?? -1) >= op.at) return false;
        tombstones.remove(op.id);
        final existing = records[op.id];
        // Same bytes uploaded again: keep enrichment the library already has.
        records[op.id] = existing == null
            ? record
            : existing.patched(
                record.toJson()..removeWhere((k, _) => _enrichment.contains(k)),
              );
        return true;
      case PatchOp(:final fields):
        final existing = records[op.id];
        if (existing == null) return false;
        records[op.id] = existing.patched(fields);
        return true;
      case DeleteOp():
        final removed = records.remove(op.id) != null;
        final previous = tombstones[op.id] ?? -1;
        if (op.at > previous) tombstones[op.id] = op.at;
        return removed;
    }
  }

  static const _enrichment = {'place', 'country', 'weather'};

  /// Applies ops in a deterministic order, so every device reaches the same
  /// state from the same set of ops. Returns the ids that changed.
  Set<String> applyAll(Iterable<CatalogueOp> ops) {
    final sorted = ops.toList()..sort((a, b) => a.at.compareTo(b.at));
    return {
      for (final op in sorted)
        if (apply(op)) op.id,
    };
  }

  /// Sorted by id, so equal catalogues serialize to identical bytes.
  Map<String, dynamic> toJson() => {
    'records': [
      for (final id in records.keys.toList()..sort()) records[id]!.toJson(),
    ],
    'tombstones': {
      for (final id in tombstones.keys.toList()..sort()) id: tombstones[id],
    },
  };

  factory Catalogue.fromJson(Map<String, dynamic> j) => Catalogue(
    records: {
      for (final r in (j['records'] as List? ?? const []))
        (r as Map)['id'] as String: PhotoRecord.fromJson(
          r.cast<String, dynamic>(),
        ),
    },
    tombstones: (j['tombstones'] as Map? ?? const {}).cast<String, int>(),
  );
}
