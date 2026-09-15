import 'dart:async';
import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:math';

import '../crypto/vault.dart';
import '../s3/s3_client.dart';
import 'catalogue.dart';

/// Keeps a [Catalogue] in sync with the bucket.
///
/// Layout:
/// * `v1/j/<13-digit ms>-<random>`: one encrypted batch of ops per change.
/// * `v1/index/<10-digit seq>`: encrypted snapshot, plus the list of journal
///   keys already folded into it.
///
/// Every object is created with `If-None-Match: *`. Two devices compacting at
/// once can't both write the same snapshot number, so the loser reloads.
class RemoteCatalogue {
  static const journalPrefix = 'v1/j/';
  static const indexPrefix = 'v1/index/';

  final BucketClient bucket;
  final Vault vault;
  final DateTime Function() clock;
  final Random _random;

  Catalogue state = Catalogue();
  int snapshotSeq = 0;

  /// Journal keys reflected in [state], via the snapshot or applied directly.
  final Set<String> _applied = {};

  /// Journal keys contained in the current snapshot.
  Set<String> _folded = {};

  Future<void> _tail = Future.value();

  RemoteCatalogue(
    this.bucket,
    this.vault, {
    DateTime Function()? clock,
    Random? random,
  }) : clock = clock ?? DateTime.now,
       _random = random ?? Random.secure();

  /// Journal entries applied but not yet folded into a snapshot.
  int get pendingJournal => _applied.where((k) => !_folded.contains(k)).length;

  /// Loads everything from the bucket. Returns ids that changed.
  Future<Set<String>> load() => _locked(_load);

  /// Picks up other devices' changes. With nothing new this costs two
  /// listings and no downloads. Returns ids that changed.
  Future<Set<String>> refresh() => _locked(() async {
    final snapshots = await bucket.listObjects(prefix: indexPrefix);
    final newest = snapshots.isEmpty
        ? 0
        : snapshots.map((o) => _seqOf(o.key)).reduce(max);
    if (newest > snapshotSeq) return _load();

    final journal = await bucket.listObjects(prefix: journalPrefix);
    final unseen = [
      for (final o in journal)
        if (!_applied.contains(o.key)) o.key,
    ];
    if (unseen.isEmpty) return <String>{};
    final changed = state.applyAll(await _readJournal(unseen));
    _applied.addAll(unseen);
    return changed;
  });

  /// Writes [ops] to the bucket, then applies them locally.
  Future<Set<String>> commit(List<CatalogueOp> ops) => _locked(() async {
    if (ops.isEmpty) return <String>{};
    final ms = clock().toUtc().millisecondsSinceEpoch.toString().padLeft(
      13,
      '0',
    );
    for (var attempt = 0; ; attempt++) {
      final key = '$journalPrefix$ms-${_randomHex(8)}';
      try {
        await _write(key, {
          'ops': [for (final op in ops) op.toJson()],
        });
        _applied.add(key);
        return state.applyAll(ops);
      } on S3Exception catch (e) {
        // Random-suffix collision: pick another name.
        if (!e.isPreconditionFailed || attempt >= 3) rethrow;
      }
    }
  });

  /// Folds the journal into a new snapshot once it gets long. Safe to run on
  /// several devices at once. Returns true if this device wrote the snapshot.
  Future<bool> compactIfNeeded({int threshold = 200}) => _locked(() async {
    if (pendingJournal < threshold) return false;
    // Fold only entries that still exist, so keys an earlier compaction
    // deleted drop out and the folded list doesn't grow forever.
    final listing = await bucket.listObjects(prefix: journalPrefix);
    final folded = {
      for (final o in listing)
        if (_applied.contains(o.key)) o.key,
    };
    final seq = snapshotSeq + 1;
    try {
      await _write(_indexKey(seq), {
        'seq': seq,
        'catalogue': state.toJson(),
        'folded': folded.toList()..sort(),
        'createdAt': clock().toUtc().toIso8601String(),
      });
    } on S3Exception catch (e) {
      if (!e.isPreconditionFailed) rethrow;
      await _load(); // Another device compacted first.
      return false;
    }
    final previous = snapshotSeq;
    snapshotSeq = seq;
    _folded = folded;
    // Best-effort cleanup. Anything left behind is harmless: folded journal
    // keys are skipped, and only the newest snapshot is ever read.
    await _parallel([
      ...folded,
      if (previous > 0) _indexKey(previous),
    ], (k) => bucket.deleteObject(k).catchError((_) {}));
    return true;
  });

  // -------------------------------------------------------------- plumbing

  Future<Set<String>> _load() async {
    final before = state;
    for (var attempt = 0; ; attempt++) {
      try {
        await _loadOnce();
        return _diff(before, state);
      } on S3Exception catch (e) {
        // A compaction elsewhere deleted something mid-load: start over.
        if (!e.isNotFound || attempt >= 2) rethrow;
      }
    }
  }

  Future<void> _loadOnce() async {
    final snapshots = await bucket.listObjects(prefix: indexPrefix);
    var fresh = Catalogue();
    var seq = 0;
    var folded = <String>{};
    if (snapshots.isNotEmpty) {
      final latest = snapshots
          .map((o) => o.key)
          .reduce((a, b) => _seqOf(a) >= _seqOf(b) ? a : b);
      final json = await _read(latest);
      seq = json['seq'] as int;
      fresh = Catalogue.fromJson(json['catalogue'] as Map<String, dynamic>);
      folded = (json['folded'] as List).cast<String>().toSet();
    }
    final journal = await bucket.listObjects(prefix: journalPrefix);
    final unseen = [
      for (final o in journal)
        if (!folded.contains(o.key)) o.key,
    ];
    fresh.applyAll(await _readJournal(unseen));

    state = fresh;
    snapshotSeq = seq;
    _folded = folded;
    _applied
      ..clear()
      ..addAll(folded)
      ..addAll(unseen);
  }

  Future<List<CatalogueOp>> _readJournal(List<String> keys) async {
    final ops = <CatalogueOp>[];
    await _parallel(keys, (k) async {
      final json = await _read(k);
      for (final op in json['ops'] as List) {
        ops.add(CatalogueOp.fromJson((op as Map).cast<String, dynamic>()));
      }
    });
    return ops;
  }

  Future<Map<String, dynamic>> _read(String key) async {
    final sealed = await bucket.getObject(key);
    final clear = await vault.open(sealed, context: key);
    return jsonDecode(utf8.decode(gzip.decode(clear))) as Map<String, dynamic>;
  }

  Future<void> _write(String key, Map<String, dynamic> json) async {
    final clear = gzip.encode(utf8.encode(jsonEncode(json)));
    final sealed = await vault.seal(clear, context: key);
    await bucket.putObject(key, sealed, ifNoneMatch: '*');
  }

  /// Runs [action] after every earlier call has finished, so a commit can't
  /// interleave with a compaction or reload.
  Future<T> _locked<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }

  static String _indexKey(int seq) =>
      '$indexPrefix${seq.toString().padLeft(10, '0')}';

  static int _seqOf(String key) =>
      int.tryParse(key.substring(indexPrefix.length)) ?? 0;

  String _randomHex(int bytes) => List.generate(
    bytes,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  static Future<void> _parallel(
    List<String> items,
    Future<void> Function(String) run, {
    int concurrency = 8,
  }) async {
    var next = 0;
    Future<void> worker() async {
      while (next < items.length) {
        await run(items[next++]);
      }
    }

    await Future.wait([
      for (var i = 0; i < min(concurrency, items.length); i++) worker(),
    ]);
  }

  static Set<String> _diff(Catalogue a, Catalogue b) => {
    for (final id in {...a.records.keys, ...b.records.keys})
      if (jsonEncode(a.records[id]?.toJson()) !=
          jsonEncode(b.records[id]?.toJson()))
        id,
  };
}
