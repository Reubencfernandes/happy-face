import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:happy_drive/crypto/vault.dart';

// Cheap parameters so the suite stays fast; production uses KdfParams().
const fast = KdfParams(memoryKiB: 256, iterations: 1, parallelism: 1);

void main() {
  test('create, then unlock on another device with the passphrase', () async {
    final (vault, envelope) = await Vault.create('correct horse', params: fast);
    final other = await Vault.unlock(envelope, 'correct horse');
    expect(await other.exportMasterKey(), await vault.exportMasterKey());

    final sealed = await vault.seal(
      utf8.encode('photo bytes'),
      context: 'v1/o/ab/cd',
    );
    expect(
      utf8.decode(await other.open(sealed, context: 'v1/o/ab/cd')),
      'photo bytes',
    );
  });

  test('envelope contains no key material in the clear', () async {
    final (vault, envelope) = await Vault.create('pw', params: fast);
    final master = base64Encode(await vault.exportMasterKey());
    expect(utf8.decode(envelope), isNot(contains(master)));
    expect(jsonDecode(utf8.decode(envelope))['kdf']['alg'], 'argon2id');
  });

  test('wrong passphrase is reported as such', () async {
    final (_, envelope) = await Vault.create('right', params: fast);
    await expectLater(
      Vault.unlock(envelope, 'wrong'),
      throwsA(isA<WrongPassphraseException>()),
    );
  });

  test(
    'rewrap changes the passphrase but keeps the same library key',
    () async {
      final (vault, _) = await Vault.create('old', params: fast);
      final envelope = await vault.rewrap('new', params: fast);
      final reopened = await Vault.unlock(envelope, 'new');
      expect(await reopened.exportMasterKey(), await vault.exportMasterKey());
      await expectLater(
        Vault.unlock(envelope, 'old'),
        throwsA(isA<WrongPassphraseException>()),
      );
    },
  );

  test('seal is randomized and output is not the plaintext', () async {
    final vault = await Vault.fromMasterKey(List.filled(32, 7));
    final data = Uint8List.fromList(List.generate(1000, (i) => i % 256));
    final a = await vault.seal(data, context: 'k');
    final b = await vault.seal(data, context: 'k');
    expect(a, isNot(equals(b)));
    expect(a.length, data.length + 1 + 12 + 16);
  });

  test('tampering, truncation and context swaps are all rejected', () async {
    final vault = await Vault.fromMasterKey(List.filled(32, 1));
    final sealed = await vault.seal(
      utf8.encode('secret'),
      context: 'v1/o/ab/cd',
    );

    final flipped = Uint8List.fromList(sealed)..[20] ^= 1;
    await expectLater(
      vault.open(flipped, context: 'v1/o/ab/cd'),
      throwsA(isA<TamperedDataException>()),
    );
    await expectLater(
      vault.open(sealed.sublist(0, 10), context: 'v1/o/ab/cd'),
      throwsA(isA<TamperedDataException>()),
    );
    await expectLater(
      vault.open(sealed, context: 'v1/t/ab/cd'),
      throwsA(isA<TamperedDataException>()),
    );

    final otherKey = await Vault.fromMasterKey(List.filled(32, 2));
    await expectLater(
      otherKey.open(sealed, context: 'v1/o/ab/cd'),
      throwsA(isA<TamperedDataException>()),
    );
  });

  test(
    'photo ids are deterministic per library and differ across libraries',
    () async {
      final a = await Vault.fromMasterKey(List.filled(32, 1));
      final b = await Vault.fromMasterKey(List.filled(32, 2));
      final photo = utf8.encode('same photo');
      expect(a.photoIdFor(photo), a.photoIdFor(photo));
      expect(a.photoIdFor(photo), hasLength(32));
      expect(a.photoIdFor(photo), matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(a.photoIdFor(photo), isNot(b.photoIdFor(photo)));
      expect(
        a.photoIdFor(photo),
        isNot(a.photoIdFor(utf8.encode('other photo'))),
      );
    },
  );

  // Pins the key derivation itself. Derived keys must never drift with the
  // cryptography backend in use, or every library already in a bucket becomes
  // unreadable; this caught the Android-only empty-HMAC-key crash indirectly.
  test('subkeys derived from a master key are stable across releases', () async {
    final vault = await Vault.fromMasterKey(List.generate(32, (i) => i));
    final plaintext = utf8.encode('happy drive vector');

    expect(vault.photoIdFor(plaintext), '259703ff7bea199be78fd1ca2f604e4b');
    expect(
      utf8.decode(
        await vault.open(
          base64Decode(
            'Abbpp7JdFDkGxwJPpl2ABCo0ekb0XyK6JZgVAT88DzbFffDJT+NNNhrdT0Uv85w=',
          ),
          context: 'v1/o/ab/cd',
        ),
      ),
      'happy drive vector',
    );
  });

  test('default parameters meet the OWASP Argon2id baseline', () {
    const p = KdfParams();
    expect(p.memoryKiB, greaterThanOrEqualTo(19456));
    expect(p.iterations, greaterThanOrEqualTo(2));
  });

  test('a big payload still round-trips when sealed off-isolate', () async {
    final vault = await Vault.fromMasterKey(List.filled(32, 11));
    final big = Uint8List(17 * 1024 * 1024);
    for (var i = 0; i < big.length; i += 4096) {
      big[i] = i % 251;
    }
    final sealed = await vault.seal(big, context: 'v1/o/ab/big');
    final back = await vault.open(sealed, context: 'v1/o/ab/big');
    expect(back.length, big.length);
    expect(back[0], big[0]);
    expect(back[4096], big[4096]);
    expect(back[big.length - 1], big[big.length - 1]);
    // Bound to its name, still.
    await expectLater(
      vault.open(sealed, context: 'v1/o/ab/other'),
      throwsA(isA<TamperedDataException>()),
    );
    // And the async id matches the sync one.
    expect(await vault.photoIdForAsync(big), vault.photoIdFor(big));
  });
}
