import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import 'catalogue.dart';

enum BackupState {
  /// On this phone and in the bucket.
  backedUp,

  /// On this phone only.
  localOnly,

  /// In the bucket only (another device, or deleted from this phone).
  cloudOnly,
}

enum TimelineSort { taken, uploaded }

enum TimelineFilter { all, backedUp, localOnly, cloudOnly }

/// One cell in the timeline: a cloud photo, a phone photo, or both.
class TimelineItem {
  final String? photoId;
  final String? assetId;
  final DateTime takenAt;
  final int? tzOffsetMinutes;
  final BackupState state;
  const TimelineItem({
    required this.photoId,
    required this.assetId,
    required this.takenAt,
    required this.tzOffsetMinutes,
    required this.state,
  });

  DateTime get localTakenAt =>
      takenAt.add(Duration(minutes: tzOffsetMinutes ?? 0));

  String get key => photoId ?? 'asset:$assetId';
}

/// A photo in the phone's gallery, as last seen by the backup scanner.
class DeviceAsset {
  final String assetId;
  final DateTime takenAt;
  final int? tzOffsetMinutes;
  final DateTime modifiedAt;
  const DeviceAsset({
    required this.assetId,
    required this.takenAt,
    required this.modifiedAt,
    this.tzOffsetMinutes,
  });
}

class PlaceGroup {
  final String country;
  final String place;
  final int count;
  final String coverPhotoId;
  const PlaceGroup(this.country, this.place, this.count, this.coverPhotoId);
}

class BackupStats {
  final int onDevice;
  final int backedUp;
  final int inCloud;
  const BackupStats(this.onDevice, this.backedUp, this.inCloud);
  int get pending => onDevice - backedUp;
}

enum JobKind { place, weather, caption }

class Job {
  final String photoId;
  final JobKind kind;
  final int attempts;
  const Job(this.photoId, this.kind, this.attempts);
}

/// On-device database: a queryable mirror of the catalogue, the phone's
/// backup state, the enrichment job queue and settings.
class LocalDb {
  final Database db;

  LocalDb._(this.db) {
    // The background backup task may hold the database briefly.
    db.execute('PRAGMA busy_timeout = 5000');
    _migrate();
  }

  factory LocalDb.open(String path) => LocalDb._(sqlite3.open(path));
  factory LocalDb.inMemory() => LocalDb._(sqlite3.openInMemory());

  void close() => db.close();

  void _migrate() {
    final version = db.select('PRAGMA user_version').first.values.first as int;
    if (version >= 1) return;
    db.execute('''
      PRAGMA journal_mode = WAL;
      CREATE TABLE photos (
        id TEXT PRIMARY KEY,
        taken_at INTEGER NOT NULL,
        tz INTEGER,
        uploaded_at INTEGER NOT NULL,
        country TEXT,
        place TEXT,
        json TEXT NOT NULL
      );
      CREATE INDEX photos_taken ON photos(taken_at);
      CREATE INDEX photos_uploaded ON photos(uploaded_at);
      CREATE INDEX photos_place ON photos(country, place);
      CREATE VIRTUAL TABLE photos_fts USING fts5(
        id UNINDEXED, name, caption, tags, place, weather, date,
        tokenize = 'unicode61 remove_diacritics 2'
      );
      CREATE TABLE device_assets (
        asset_id TEXT PRIMARY KEY,
        taken_at INTEGER NOT NULL,
        tz INTEGER,
        modified_at INTEGER NOT NULL,
        photo_id TEXT,
        uploaded_modified_at INTEGER,
        last_error TEXT
      );
      CREATE INDEX device_assets_photo ON device_assets(photo_id);
      CREATE TABLE jobs (
        photo_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        not_before INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (photo_id, kind)
      );
      CREATE TABLE kv (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      PRAGMA user_version = 1;
    ''');
  }

  T _tx<T>(T Function() body) {
    db.execute('BEGIN');
    try {
      final result = body();
      db.execute('COMMIT');
      return result;
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  // ------------------------------------------------------------- catalogue

  /// Mirrors [changed] ids from [catalogue] into the database.
  void syncFrom(Catalogue catalogue, Iterable<String> changed) => _tx(() {
    for (final id in changed) {
      final rec = catalogue.records[id];
      if (rec == null) {
        _deletePhoto(id);
      } else {
        _upsertPhoto(rec);
      }
    }
  });

  /// Replaces the whole mirror, e.g. after signing in on a new phone.
  void replaceAll(Catalogue catalogue) => _tx(() {
    db.execute('DELETE FROM photos; DELETE FROM photos_fts;');
    catalogue.records.values.forEach(_upsertPhoto);
  });

  void _upsertPhoto(PhotoRecord r) {
    db.execute(
      'INSERT OR REPLACE INTO photos (id, taken_at, tz, uploaded_at, country, place, json) '
      'VALUES (?, ?, ?, ?, ?, ?, ?)',
      [
        r.id,
        r.takenAt.millisecondsSinceEpoch,
        r.tzOffsetMinutes,
        r.uploadedAt.millisecondsSinceEpoch,
        r.country,
        r.place,
        jsonEncode(r.toJson()),
      ],
    );
    db.execute('DELETE FROM photos_fts WHERE id = ?', [r.id]);
    final local = r.localTakenAt;
    db.execute(
      'INSERT INTO photos_fts (id, name, caption, tags, place, weather, date) '
      'VALUES (?, ?, ?, ?, ?, ?, ?)',
      [
        r.id,
        r.name,
        r.caption ?? '',
        r.tags.join(' '),
        [r.place, r.country].whereType<String>().join(' '),
        (r.weather?['summary'] as String?) ?? '',
        '${local.year} ${_months[local.month - 1]} '
            '${_months[local.month - 1].substring(0, 3)} ${_weekdays[local.weekday - 1]}',
      ],
    );
  }

  void _deletePhoto(String id) {
    db.execute('DELETE FROM photos WHERE id = ?', [id]);
    db.execute('DELETE FROM photos_fts WHERE id = ?', [id]);
  }

  PhotoRecord? photo(String id) {
    final rows = db.select('SELECT json FROM photos WHERE id = ?', [id]);
    return rows.isEmpty ? null : _record(rows.first);
  }

  bool hasPhoto(String id) =>
      db.select('SELECT 1 FROM photos WHERE id = ?', [id]).isNotEmpty;

  Set<String> allPhotoIds() => {
    for (final r in db.select('SELECT id FROM photos')) r['id'] as String,
  };

  int get photoCount =>
      db.select('SELECT COUNT(*) AS n FROM photos').first['n'] as int;

  static PhotoRecord _record(Row row) => PhotoRecord.fromJson(
    jsonDecode(row['json'] as String) as Map<String, dynamic>,
  );

  // -------------------------------------------------------------- timeline

  /// Phone and cloud photos merged into one list, newest first by default.
  List<TimelineItem> timeline({
    int limit = 200,
    int offset = 0,
    TimelineSort sort = TimelineSort.taken,
    bool descending = true,
    TimelineFilter filter = TimelineFilter.all,
    DateTime? from,
    DateTime? to,
    String? country,
    String? place,
  }) {
    // Sorting by upload date only makes sense for photos in the cloud.
    final cloudSort = sort == TimelineSort.uploaded
        ? 'p.uploaded_at'
        : 'p.taken_at';
    final parts = <String>[];
    final args = <Object?>[];

    String range(String column) {
      final c = <String>[];
      if (from != null) {
        c.add('$column >= ?');
        args.add(from.millisecondsSinceEpoch);
      }
      if (to != null) {
        c.add('$column < ?');
        args.add(to.millisecondsSinceEpoch);
      }
      return c.isEmpty ? '' : ' AND ${c.join(' AND ')}';
    }

    String placeFilter() {
      final c = <String>[];
      if (country != null) {
        c.add('p.country = ?');
        args.add(country);
      }
      if (place != null) {
        c.add('p.place = ?');
        args.add(place);
      }
      return c.isEmpty ? '' : ' AND ${c.join(' AND ')}';
    }

    if (filter != TimelineFilter.localOnly) {
      final stateFilter = switch (filter) {
        TimelineFilter.backedUp => ' AND d.asset_id IS NOT NULL',
        TimelineFilter.cloudOnly => ' AND d.asset_id IS NULL',
        _ => '',
      };
      parts.add(
        'SELECT p.id AS photo_id, MIN(d.asset_id) AS asset_id, p.taken_at AS taken_at, '
        'p.tz AS tz, $cloudSort AS sort_key, '
        "CASE WHEN MIN(d.asset_id) IS NULL THEN 'cloud' ELSE 'synced' END AS state "
        'FROM photos p LEFT JOIN device_assets d ON d.photo_id = p.id '
        'WHERE 1=1${range('p.taken_at')}${placeFilter()} '
        'GROUP BY p.id HAVING 1=1${stateFilter.replaceAll('d.asset_id', 'MIN(d.asset_id)')}',
      );
    }
    final placeRequested = country != null || place != null;
    if ((filter == TimelineFilter.all || filter == TimelineFilter.localOnly) &&
        !placeRequested &&
        sort == TimelineSort.taken) {
      parts.add(
        "SELECT NULL AS photo_id, d.asset_id AS asset_id, d.taken_at AS taken_at, d.tz AS tz, "
        "d.taken_at AS sort_key, 'local' AS state FROM device_assets d "
        'WHERE (d.photo_id IS NULL OR d.photo_id NOT IN (SELECT id FROM photos))'
        '${range('d.taken_at')}',
      );
    }
    if (parts.isEmpty) return const [];
    final order = descending ? 'DESC' : 'ASC';
    final rows = db.select(
      '${parts.join(' UNION ALL ')} ORDER BY sort_key $order, taken_at $order, '
      'photo_id, asset_id LIMIT ? OFFSET ?',
      [...args, limit, offset],
    );
    return [
      for (final r in rows)
        TimelineItem(
          photoId: r['photo_id'] as String?,
          assetId: r['asset_id'] as String?,
          takenAt: DateTime.fromMillisecondsSinceEpoch(
            r['taken_at'] as int,
            isUtc: true,
          ),
          tzOffsetMinutes: r['tz'] as int?,
          state: switch (r['state']) {
            'synced' => BackupState.backedUp,
            'cloud' => BackupState.cloudOnly,
            _ => BackupState.localOnly,
          },
        ),
    ];
  }

  // ---------------------------------------------------------------- search

  /// Full-text search over name, caption, tags, place, weather and date.
  /// Every word must match (prefix match), e.g. `beach 2025` or `rain goa`.
  List<PhotoRecord> search(String query, {int limit = 300}) {
    final words = RegExp(r'[\p{L}\p{N}]+', unicode: true)
        .allMatches(query)
        .map((m) => '"${m.group(0)!.replaceAll('"', '')}"*')
        .toList();
    if (words.isEmpty) return const [];
    final rows = db.select(
      'SELECT p.json FROM photos_fts f JOIN photos p ON p.id = f.id '
      'WHERE photos_fts MATCH ? ORDER BY p.taken_at DESC LIMIT ?',
      [words.join(' AND '), limit],
    );
    return rows.map(_record).toList();
  }

  List<PlaceGroup> places() {
    final rows = db.select('''
      SELECT country, place, COUNT(*) AS n,
        (SELECT id FROM photos q WHERE q.country IS p.country AND q.place IS p.place
         ORDER BY q.taken_at DESC LIMIT 1) AS cover
      FROM photos p WHERE place IS NOT NULL
      GROUP BY country, place ORDER BY country, n DESC
    ''');
    return [
      for (final r in rows)
        PlaceGroup(
          r['country'] as String? ?? '',
          r['place'] as String,
          r['n'] as int,
          r['cover'] as String,
        ),
    ];
  }

  // ---------------------------------------------------------- device assets

  /// Records what the gallery scan found. Keeps upload state for assets that
  /// haven't been edited since they were backed up.
  void upsertDeviceAssets(Iterable<DeviceAsset> assets) => _tx(() {
    final stmt = db.prepare(
      'INSERT INTO device_assets (asset_id, taken_at, tz, modified_at) VALUES (?, ?, ?, ?) '
      'ON CONFLICT(asset_id) DO UPDATE SET taken_at = excluded.taken_at, '
      'tz = excluded.tz, modified_at = excluded.modified_at',
    );
    try {
      for (final a in assets) {
        stmt.execute([
          a.assetId,
          a.takenAt.millisecondsSinceEpoch,
          a.tzOffsetMinutes,
          a.modifiedAt.millisecondsSinceEpoch,
        ]);
      }
    } finally {
      stmt.close();
    }
  });

  /// Forgets gallery photos that are no longer on the phone.
  void removeDeviceAssetsExcept(Set<String> present) => _tx(() {
    final rows = db.select('SELECT asset_id FROM device_assets');
    for (final r in rows) {
      final id = r['asset_id'] as String;
      if (!present.contains(id)) {
        db.execute('DELETE FROM device_assets WHERE asset_id = ?', [id]);
      }
    }
  });

  /// The photo id this asset was backed up as, unless it was edited since.
  String? uploadedPhotoFor(String assetId) {
    final rows = db.select(
      'SELECT photo_id FROM device_assets WHERE asset_id = ? '
      'AND photo_id IS NOT NULL AND uploaded_modified_at = modified_at',
      [assetId],
    );
    return rows.isEmpty ? null : rows.first['photo_id'] as String;
  }

  void markAssetUploaded(String assetId, String photoId) => db.execute(
    'UPDATE device_assets SET photo_id = ?, uploaded_modified_at = modified_at, '
    'last_error = NULL WHERE asset_id = ?',
    [photoId, assetId],
  );

  void markAssetFailed(String assetId, String error) => db.execute(
    'UPDATE device_assets SET last_error = ? WHERE asset_id = ?',
    [error, assetId],
  );

  /// Gallery assets that still need uploading, newest first.
  List<String> pendingAssets({int limit = 1000}) => [
    for (final r in db.select(
      'SELECT asset_id FROM device_assets WHERE photo_id IS NULL '
      'OR uploaded_modified_at IS NOT modified_at ORDER BY taken_at DESC LIMIT ?',
      [limit],
    ))
      r['asset_id'] as String,
  ];

  BackupStats backupStats() {
    final r = db.select('''
      SELECT (SELECT COUNT(*) FROM device_assets) AS device,
             (SELECT COUNT(*) FROM device_assets d JOIN photos p ON p.id = d.photo_id
               WHERE d.uploaded_modified_at = d.modified_at) AS backed,
             (SELECT COUNT(*) FROM photos) AS cloud
    ''').first;
    return BackupStats(
      r['device'] as int,
      r['backed'] as int,
      r['cloud'] as int,
    );
  }

  // ------------------------------------------------------------------ jobs

  void enqueueJob(
    String photoId,
    JobKind kind, {
    DateTime? notBefore,
  }) => db.execute(
    'INSERT OR IGNORE INTO jobs (photo_id, kind, not_before) VALUES (?, ?, ?)',
    [photoId, kind.name, notBefore?.millisecondsSinceEpoch ?? 0],
  );

  List<Job> dueJobs(JobKind kind, DateTime now, {int limit = 20}) => [
    for (final r in db.select(
      'SELECT j.photo_id, j.attempts FROM jobs j JOIN photos p ON p.id = j.photo_id '
      'WHERE j.kind = ? AND j.not_before <= ? ORDER BY p.taken_at DESC LIMIT ?',
      [kind.name, now.millisecondsSinceEpoch, limit],
    ))
      Job(r['photo_id'] as String, kind, r['attempts'] as int),
  ];

  int jobCount(JobKind kind) =>
      db.select('SELECT COUNT(*) AS n FROM jobs WHERE kind = ?', [
            kind.name,
          ]).first['n']
          as int;

  void completeJob(String photoId, JobKind kind) => db.execute(
    'DELETE FROM jobs WHERE photo_id = ? AND kind = ?',
    [photoId, kind.name],
  );

  void retryJobLater(String photoId, JobKind kind, DateTime notBefore) =>
      db.execute(
        'UPDATE jobs SET attempts = attempts + 1, not_before = ? '
        'WHERE photo_id = ? AND kind = ?',
        [notBefore.millisecondsSinceEpoch, photoId, kind.name],
      );

  // -------------------------------------------------------------- settings

  String? getSetting(String key) {
    final rows = db.select('SELECT value FROM kv WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  void setSetting(String key, String? value) => value == null
      ? db.execute('DELETE FROM kv WHERE key = ?', [key])
      : db.execute('INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)', [
          key,
          value,
        ]);

  static const _months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  static const _weekdays = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
}
