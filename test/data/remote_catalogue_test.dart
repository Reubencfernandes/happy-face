import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:happy_drive/crypto/vault.dart';
import 'package:happy_drive/data/catalogue.dart';
import 'package:happy_drive/data/remote_catalogue.dart';

import '../support/fake_bucket.dart';
import 'catalogue_test.dart' show photo;

void main() {
  late FakeBucket bucket;
  late Vault vault;
  var tick = 0;
  RemoteCatalogue device() => RemoteCatalogue(
    bucket.client(),
    vault,
    clock: () => DateTime.utc(2026).add(Duration(seconds: tick++)),
  );

  setUp(() async {
    bucket = FakeBucket(pageSize: 7);
    vault = await Vault.fromMasterKey(List.filled(32, 3));
  });

  String stateOf(RemoteCatalogue c) => jsonEncode(c.state.toJson());

  test('a change on one device shows up on another', () async {
    final phone = device();
    await phone.load();
    await phone.commit([PutOp(photo('a', name: 'secret-name.jpg'), 1)]);

    final tablet = device();
    expect(await tablet.load(), {'a'});
    expect(tablet.state.records['a']!.name, 'secret-name.jpg');

    await phone.commit([
      PatchOp('a', {'caption': 'dog'}, 2),
    ]);
    expect(await tablet.refresh(), {'a'});
    expect(tablet.state.records['a']!.caption, 'dog');
    expect(await tablet.refresh(), isEmpty);
  });

  test('nothing readable is stored in the bucket', () async {
    final phone = device();
    await phone.commit([
      PutOp(photo('a', name: 'passport-scan.jpg'), 1),
      PatchOp('a', {'place': 'Panaji', 'caption': 'my passport'}, 2),
    ]);
    for (final entry in bucket.objects.entries) {
      final text = latin1.decode(entry.value);
      for (final secret in ['passport', 'Panaji', 'image/jpeg']) {
        expect(text, isNot(contains(secret)), reason: entry.key);
      }
    }
  });

  test('concurrent edits from two devices converge', () async {
    final a = device(), b = device();
    await a.load();
    await b.load();
    await a.commit([PutOp(photo('x'), 1)]);
    await b.commit([PutOp(photo('y'), 2)]);
    await a.commit([
      PatchOp('y', {'caption': 'from a'}, 3),
    ]); // a hasn't seen y yet
    await a.refresh();
    await b.refresh();
    // a applied the patch before it knew y; a reload re-derives the truth.
    await a.load();
    expect(stateOf(a), stateOf(b));
    expect(a.state.records['y']!.caption, 'from a');
  });

  test(
    'compaction folds the journal and a new device reads the snapshot',
    () async {
      final phone = device();
      for (var i = 0; i < 12; i++) {
        await phone.commit([PutOp(photo('p$i', takenAt: i), i + 1)]);
      }
      expect(await phone.compactIfNeeded(threshold: 10), isTrue);
      expect(phone.pendingJournal, 0);
      expect(bucket.objects.keys.where((k) => k.startsWith('v1/j/')), isEmpty);
      expect(bucket.objects.keys.where((k) => k.startsWith('v1/index/')), [
        'v1/index/0000000001',
      ]);

      await phone.commit([DeleteOp('p0', 100)]);
      final fresh = device();
      await fresh.load();
      expect(fresh.snapshotSeq, 1);
      expect(fresh.state.records, hasLength(11));
      expect(stateOf(fresh), stateOf(phone));
      expect(await phone.compactIfNeeded(threshold: 10), isFalse);
    },
  );

  test('two devices compacting at once: one wins, the other reloads', () async {
    final a = device(), b = device();
    for (var i = 0; i < 5; i++) {
      await a.commit([PutOp(photo('a$i'), i + 1)]);
    }
    await b.load();
    await b.commit([PutOp(photo('b0'), 50)]);
    await a.refresh();

    expect(await a.compactIfNeeded(threshold: 3), isTrue);
    // b still thinks snapshot 0 is current; its write of snapshot 1 must fail.
    expect(await b.compactIfNeeded(threshold: 3), isFalse);
    expect(b.snapshotSeq, 1);
    expect(stateOf(b), stateOf(a));
    expect(b.state.records.keys, containsAll(['a0', 'a4', 'b0']));
  });

  test('a journal entry written during compaction is not lost', () async {
    final a = device(), b = device();
    for (var i = 0; i < 4; i++) {
      await a.commit([PutOp(photo('a$i'), i + 1)]);
    }
    await b.load();
    // b writes after a last refreshed, so a does not fold it.
    await b.commit([PutOp(photo('late'), 99)]);
    expect(await a.compactIfNeeded(threshold: 3), isTrue);
    expect(
      bucket.objects.keys.where((k) => k.startsWith('v1/j/')),
      hasLength(1),
    );

    final fresh = device();
    await fresh.load();
    expect(fresh.state.records.keys, contains('late'));
  });

  test('refresh with no changes downloads nothing', () async {
    final phone = device();
    await phone.commit([PutOp(photo('a'), 1)]);
    bucket.log.clear();
    await phone.refresh();
    expect(bucket.count('GET'), 2); // two listings, zero object downloads
    expect(bucket.log.every((l) => l == 'GET '), isTrue);
  });
}
