import 'package:flutter_test/flutter_test.dart';
import 'package:happy_drive/data/catalogue.dart';
import 'package:happy_drive/data/local_db.dart';

PhotoRecord rec(
  String id,
  DateTime taken, {
  DateTime? uploaded,
  String? place,
  String? country,
  Map<String, dynamic>? weather,
  int? tz,
  String name = 'IMG.jpg',
  String mime = 'image/jpeg',
}) => PhotoRecord(
  id: id,
  name: name,
  mime: mime,
  size: 1,
  takenAt: taken,
  uploadedAt: uploaded ?? DateTime.utc(2026, 9, 1),
  place: place,
  country: country,
  weather: weather,
  tzOffsetMinutes: tz,
);

void main() {
  late LocalDb db;
  late Catalogue cat;

  void put(PhotoRecord r) {
    cat.records[r.id] = r;
    db.syncFrom(cat, [r.id]);
  }

  setUp(() {
    db = LocalDb.inMemory();
    cat = Catalogue();
  });
  tearDown(() => db.close());

  test('the timeline says which items are videos or files', () {
    put(rec('a-photo', DateTime.utc(2025, 1, 3)));
    put(
      rec(
        'a-video',
        DateTime.utc(2025, 1, 2),
        name: 'trip.mp4',
        mime: 'video/mp4',
      ),
    );
    put(
      rec(
        'a-file',
        DateTime.utc(2025, 1, 1),
        name: 'tickets.pdf',
        mime: 'application/pdf',
      ),
    );
    db.upsertDeviceAssets([
      DeviceAsset(
        assetId: 'phone-video',
        takenAt: DateTime.utc(2025, 1, 4),
        modifiedAt: DateTime.utc(2025, 1, 4),
        isVideo: true,
      ),
      DeviceAsset(
        assetId: 'phone-photo',
        takenAt: DateTime.utc(2025, 1, 5),
        modifiedAt: DateTime.utc(2025, 1, 5),
      ),
    ]);

    final kinds = {for (final i in db.timeline()) i.key: i.kind};
    expect(kinds['a-photo'], MediaKind.image);
    expect(kinds['a-video'], MediaKind.video);
    expect(kinds['a-file'], MediaKind.file);
    // Videos on the phone are known before anything is uploaded.
    expect(kinds['asset:phone-video'], MediaKind.video);
    expect(kinds['asset:phone-photo'], MediaKind.image);
  });

  test('timeline merges phone and cloud photos, newest first', () {
    put(rec('cloud-old', DateTime.utc(2024, 1, 1)));
    put(rec('synced', DateTime.utc(2025, 6, 1)));
    db.upsertDeviceAssets([
      DeviceAsset(
        assetId: 'a-synced',
        takenAt: DateTime.utc(2025, 6, 1),
        modifiedAt: DateTime.utc(2025, 6, 1),
      ),
      DeviceAsset(
        assetId: 'a-new',
        takenAt: DateTime.utc(2026, 9, 14),
        modifiedAt: DateTime.utc(2026, 9, 14),
      ),
    ]);
    db.markAssetUploaded('a-synced', 'synced');

    final items = db.timeline();
    expect(items.map((i) => i.key), ['asset:a-new', 'synced', 'cloud-old']);
    expect(items.map((i) => i.state), [
      BackupState.localOnly,
      BackupState.backedUp,
      BackupState.cloudOnly,
    ]);
    expect(items[1].assetId, 'a-synced');

    expect(db.timeline(descending: false).first.key, 'cloud-old');
    expect(db.timeline(filter: TimelineFilter.localOnly).map((i) => i.key), [
      'asset:a-new',
    ]);
    expect(db.timeline(filter: TimelineFilter.cloudOnly).map((i) => i.key), [
      'cloud-old',
    ]);
    expect(db.timeline(filter: TimelineFilter.backedUp).map((i) => i.key), [
      'synced',
    ]);
    expect(db.timeline(limit: 1, offset: 1).single.key, 'synced');
  });

  test('sort by upload date and filter by date range', () {
    put(rec('a', DateTime.utc(2020), uploaded: DateTime.utc(2026, 9, 10)));
    put(rec('b', DateTime.utc(2025), uploaded: DateTime.utc(2026, 9, 1)));
    expect(db.timeline(sort: TimelineSort.uploaded).map((i) => i.key), [
      'a',
      'b',
    ]);
    expect(db.timeline().map((i) => i.key), ['b', 'a']);
    expect(
      db
          .timeline(from: DateTime.utc(2024), to: DateTime.utc(2026))
          .map((i) => i.key),
      ['b'],
    );
  });

  test('deleted cloud photos disappear; the phone copy becomes local-only', () {
    put(rec('x', DateTime.utc(2025)));
    db.upsertDeviceAssets([
      DeviceAsset(
        assetId: 'ax',
        takenAt: DateTime.utc(2025),
        modifiedAt: DateTime.utc(2025),
      ),
    ]);
    db.markAssetUploaded('ax', 'x');
    cat.records.remove('x');
    db.syncFrom(cat, ['x']);
    expect(db.photo('x'), isNull);
    expect(db.timeline().single.state, BackupState.localOnly);
  });

  test('search matches names, places, weather and dates by prefix', () {
    put(
      rec(
        'beach',
        DateTime.utc(2025, 12, 25, 10),
        place: 'Panaji',
        country: 'India',
        weather: {'summary': 'Clear sky'},
        name: 'sandcastle.jpg',
      ),
    );
    put(
      rec(
        'snow',
        DateTime.utc(2024, 1, 5),
        place: 'Manali',
        country: 'India',
        weather: {'summary': 'Heavy snow'},
        name: 'trip_manali.jpg',
      ),
    );

    List<String> ids(String q) => db.search(q).map((r) => r.id).toList();
    expect(ids('sandcas'), ['beach']);
    expect(ids('clear sky'), ['beach']);
    expect(ids('snow'), ['snow']);
    expect(ids('panaji 2025'), ['beach']);
    expect(ids('panaji 2024'), isEmpty);
    expect(ids('india'), ['beach', 'snow']);
    expect(ids('december'), ['beach']);
    expect(ids('dec'), ['beach']);
    expect(ids('manali'), ['snow']);
    expect(ids('"; DROP TABLE photos; --'), isEmpty);
    expect(db.photoCount, 2);
  });

  test('day grouping uses the photo time zone', () {
    // 20:00 UTC on 31 Dec is 01:30 on 1 Jan in India.
    put(rec('nye', DateTime.utc(2025, 12, 31, 20), tz: 330));
    final item = db.timeline().single;
    expect(item.localTakenAt.year, 2026);
    expect(db.search('2026').single.id, 'nye');
  });

  test('places groups photos with a newest cover', () {
    put(rec('p1', DateTime.utc(2025), place: 'Panaji', country: 'India'));
    put(rec('p2', DateTime.utc(2026), place: 'Panaji', country: 'India'));
    put(rec('p3', DateTime.utc(2026), place: 'Lisbon', country: 'Portugal'));
    put(rec('p4', DateTime.utc(2026)));
    final groups = db.places();
    expect(
      groups.map((g) => '${g.country}/${g.place}/${g.count}/${g.coverPhotoId}'),
      ['India/Panaji/2/p2', 'Portugal/Lisbon/1/p3'],
    );
    expect(db.timeline(country: 'India').map((i) => i.key), ['p2', 'p1']);
  });

  test('backup tracking notices edited photos and removed ones', () {
    put(rec('x', DateTime.utc(2025)));
    db.upsertDeviceAssets([
      DeviceAsset(
        assetId: 'a1',
        takenAt: DateTime.utc(2025),
        modifiedAt: DateTime.utc(2025),
      ),
      DeviceAsset(
        assetId: 'a2',
        takenAt: DateTime.utc(2026),
        modifiedAt: DateTime.utc(2026),
      ),
    ]);
    db.markAssetUploaded('a1', 'x');
    expect(db.uploadedPhotoFor('a1'), 'x');
    expect(db.pendingAssets(), ['a2']);
    expect(db.backupStats().pending, 1);

    // The user edits a1 on the phone: it needs uploading again.
    db.upsertDeviceAssets([
      DeviceAsset(
        assetId: 'a1',
        takenAt: DateTime.utc(2025),
        modifiedAt: DateTime.utc(2026, 2),
      ),
    ]);
    expect(db.uploadedPhotoFor('a1'), isNull);
    expect(db.pendingAssets(), ['a2', 'a1']);

    db.removeDeviceAssetsExcept({'a1'});
    expect(db.pendingAssets(), ['a1']);
  });

  test('job queue with retry delays', () {
    put(rec('x', DateTime.utc(2025)));
    put(rec('y', DateTime.utc(2026)));
    final now = DateTime.utc(2026, 9, 15);
    db.enqueueJob('x', JobKind.place);
    db.enqueueJob('y', JobKind.place);
    db.enqueueJob('y', JobKind.place); // duplicates are ignored
    db.enqueueJob(
      'x',
      JobKind.weather,
      notBefore: now.add(const Duration(days: 5)),
    );

    expect(db.dueJobs(JobKind.place, now).map((j) => j.photoId), ['y', 'x']);
    expect(db.dueJobs(JobKind.weather, now), isEmpty);
    db.retryJobLater('y', JobKind.place, now.add(const Duration(hours: 1)));
    expect(db.dueJobs(JobKind.place, now).map((j) => j.photoId), ['x']);
    db.completeJob('x', JobKind.place);
    expect(db.jobCount(JobKind.place), 1);
    expect(
      db
          .dueJobs(JobKind.place, now.add(const Duration(hours: 2)))
          .single
          .attempts,
      1,
    );
  });

  test('settings', () {
    expect(db.getSetting('compression'), isNull);
    db.setSetting('compression', 'high');
    expect(db.getSetting('compression'), 'high');
    db.setSetting('compression', null);
    expect(db.getSetting('compression'), isNull);
  });
}
