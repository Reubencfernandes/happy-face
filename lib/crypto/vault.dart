import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

class WrongPassphraseException implements Exception {
  @override
  String toString() => 'That passphrase does not unlock this library.';
}

class TamperedDataException implements Exception {
  final String context;
  TamperedDataException(this.context);
  @override
  String toString() => 'Encrypted data failed verification ($context).';
}

/// Argon2id cost. Defaults follow the OWASP recommendation (19 MiB, 2 passes),
/// which the pure-Dart implementation handles on mid-range phones.
class KdfParams {
  final int memoryKiB;
  final int iterations;
  final int parallelism;
  const KdfParams({
    this.memoryKiB = 19456,
    this.iterations = 2,
    this.parallelism = 1,
  });

  Map<String, Object> toJson() => {
    'alg': 'argon2id',
    'memoryKiB': memoryKiB,
    'iterations': iterations,
    'parallelism': parallelism,
  };

  factory KdfParams.fromJson(Map<String, dynamic> j) {
    if (j['alg'] != 'argon2id') throw const FormatException('Unknown KDF');
    return KdfParams(
      memoryKiB: j['memoryKiB'] as int,
      iterations: j['iterations'] as int,
      parallelism: j['parallelism'] as int,
    );
  }
}

/// Holds the library master key and everything derived from it.
///
/// Blob format: `[version=1][12-byte nonce][ciphertext][16-byte GCM tag]`.
/// Every blob is bound to a context string (normally its object key) as
/// associated data, so a thumbnail can't be swapped in for an original.
class Vault {
  static const _version = 1;

  /// Bytes [seal] adds: a version byte, the nonce and the tag.
  static const sealOverhead = 1 + _nonceLength + _macLength;
  static const _nonceLength = 12;
  static const _macLength = 16;
  static final _aes = AesGcm.with256bits();

  final SecretKey _master;
  final SecretKey _contentKey;
  final List<int> _dedupeKey;

  Vault._(this._master, this._contentKey, this._dedupeKey);

  static Future<Vault> fromMasterKey(List<int> masterBytes) async {
    if (masterBytes.length != 32) {
      throw ArgumentError('Master key must be 32 bytes');
    }
    final master = SecretKey(List.unmodifiable(masterBytes));
    // Pure-Dart HKDF on purpose. With no salt, HKDF-extract keys its HMAC with
    // an empty string, and cryptography_flutter hands that to Android's
    // SecretKeySpec, which rejects empty keys. There is nothing to gain from
    // the native path anyway: the input is 32 bytes.
    Future<SecretKey> derive(String label) => DartHkdf(
      hmac: const DartHmac(DartSha256()),
      outputLength: 32,
    ).deriveKey(secretKey: master, info: utf8.encode('happydrive:$label'));
    final content = await derive('content');
    final dedupe = await (await derive('dedupe')).extractBytes();
    return Vault._(master, content, dedupe);
  }

  /// Creates a brand-new library key protected by [passphrase].
  /// Returns the vault and the JSON envelope to store at `v1/keys`.
  static Future<(Vault, Uint8List)> create(
    String passphrase, {
    KdfParams params = const KdfParams(),
  }) async {
    final masterBytes = await (await _aes.newSecretKey()).extractBytes();
    return (
      await fromMasterKey(masterBytes),
      await _wrap(masterBytes, passphrase, params),
    );
  }

  /// Opens the envelope stored at `v1/keys`.
  static Future<Vault> unlock(
    List<int> envelopeBytes,
    String passphrase,
  ) async {
    final Map<String, dynamic> env;
    try {
      env = jsonDecode(utf8.decode(envelopeBytes)) as Map<String, dynamic>;
    } on FormatException {
      throw const FormatException('The key file in this bucket is damaged.');
    }
    if (env['format'] != 'happydrive-keys' || env['version'] != _version) {
      throw const FormatException(
        'This bucket was made by an unsupported version.',
      );
    }
    final kdf = env['kdf'] as Map<String, dynamic>;
    final wrap = env['wrap'] as Map<String, dynamic>;
    final kek = await _deriveKek(
      passphrase,
      base64Decode(kdf['salt'] as String),
      KdfParams.fromJson(kdf),
    );
    final sealed = base64Decode(wrap['ciphertext'] as String);
    try {
      final master = await _aes.decrypt(
        SecretBox(
          sealed.sublist(0, sealed.length - _macLength),
          nonce: base64Decode(wrap['nonce'] as String),
          mac: Mac(sealed.sublist(sealed.length - _macLength)),
        ),
        secretKey: kek,
        aad: utf8.encode('happydrive:keys'),
      );
      return await fromMasterKey(master);
    } on SecretBoxAuthenticationError {
      throw WrongPassphraseException();
    }
  }

  /// Re-protects the same master key with a new passphrase.
  Future<Uint8List> rewrap(
    String newPassphrase, {
    KdfParams params = const KdfParams(),
  }) async => _wrap(await _master.extractBytes(), newPassphrase, params);

  static Future<Uint8List> _wrap(
    List<int> masterBytes,
    String passphrase,
    KdfParams params,
  ) async {
    final salt = SecretKeyData.random(length: 16).bytes;
    final kek = await _deriveKek(passphrase, salt, params);
    final box = await _aes.encrypt(
      masterBytes,
      secretKey: kek,
      aad: utf8.encode('happydrive:keys'),
    );
    final envelope = {
      'format': 'happydrive-keys',
      'version': _version,
      'kdf': {...params.toJson(), 'salt': base64Encode(salt)},
      'wrap': {
        'alg': 'aes-256-gcm',
        'nonce': base64Encode(box.nonce),
        'ciphertext': base64Encode([...box.cipherText, ...box.mac.bytes]),
      },
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(envelope)));
  }

  /// Raw master key, for caching in the device keychain so the passphrase
  /// isn't needed on every launch.
  Future<List<int>> exportMasterKey() => _master.extractBytes();

  Future<Uint8List> seal(List<int> plaintext, {required String context}) async {
    final box = plaintext.length >= _encryptElsewhereAbove
        ? await _encryptElsewhere(plaintext, context)
        : await _aes.encrypt(
            plaintext,
            secretKey: _contentKey,
            aad: utf8.encode(context),
          );
    final out = BytesBuilder(copy: false)
      ..addByte(_version)
      ..add(box.nonce)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    return out.takeBytes();
  }

  /// Encrypts a big file on a worker isolate.
  ///
  /// cryptography_flutter hands work to the platform only up to a cap — 20 MB
  /// on Android, 100 MB on iOS — and above it the whole chain falls through
  /// to pure-Dart AES-GCM run *inline on the calling isolate*. So a single
  /// large video would encrypt on the isolate that draws the gallery, which
  /// is what made a backup look frozen. Off here it is pure Dart too, but it
  /// is not in the way.
  Future<SecretBox> _encryptElsewhere(
    List<int> plaintext,
    String context,
  ) async {
    final key = await _contentKey.extractBytes();
    final transfer = TransferableTypedData.fromList([
      plaintext is Uint8List ? plaintext : Uint8List.fromList(plaintext),
    ]);
    final aad = utf8.encode(context);
    final parts = await Isolate.run(() async {
      final box = await DartAesGcm.with256bits().encrypt(
        transfer.materialize().asUint8List(),
        secretKey: SecretKey(key),
        aad: aad,
      );
      return (box.nonce, box.cipherText, box.mac.bytes);
    });
    return SecretBox(parts.$2, nonce: parts.$1, mac: Mac(parts.$3));
  }

  /// Payloads at or above this are encrypted on a worker isolate. Chosen to
  /// sit under the platform cap, so everything below still takes the fast
  /// native path on the calling isolate.
  static const _encryptElsewhereAbove = 16 * 1024 * 1024;

  Future<Uint8List> open(List<int> blob, {required String context}) async {
    if (blob.length < 1 + _nonceLength + _macLength || blob[0] != _version) {
      throw TamperedDataException(context);
    }
    final bytes = blob is Uint8List ? blob : Uint8List.fromList(blob);
    try {
      final clear = await _aes.decrypt(
        SecretBox(
          Uint8List.sublistView(
            bytes,
            1 + _nonceLength,
            bytes.length - _macLength,
          ),
          nonce: Uint8List.sublistView(bytes, 1, 1 + _nonceLength),
          mac: Mac(Uint8List.sublistView(bytes, bytes.length - _macLength)),
        ),
        secretKey: _contentKey,
        aad: utf8.encode(context),
      );
      return clear is Uint8List ? clear : Uint8List.fromList(clear);
    } on SecretBoxAuthenticationError {
      throw TamperedDataException(context);
    }
  }

  /// Stable, secret-keyed photo id: the same bytes always get the same id,
  /// but nobody without the master key can compute or compare ids.
  String photoIdFor(List<int> plaintext) =>
      _idFromDigest(hash.sha256.convert(plaintext).bytes);

  /// The same id, with the expensive half computed somewhere else.
  ///
  /// SHA-256 over a whole file is pure Dart, so on a large video it holds
  /// its isolate for a noticeable stretch — long enough to freeze the
  /// gallery if that isolate is the one drawing it. Only the 32-byte digest
  /// comes back; the keyed step stays here, so the dedupe key never leaves
  /// this isolate.
  Future<String> photoIdForAsync(Uint8List plaintext) async {
    if (plaintext.length < _hashElsewhereAbove) return photoIdFor(plaintext);
    // Copied into native memory rather than onto the other isolate's heap,
    // and handed over without a second copy.
    final transfer = TransferableTypedData.fromList([plaintext]);
    final digest = await Isolate.run(
      () => hash.sha256.convert(transfer.materialize().asUint8List()).bytes,
    );
    return _idFromDigest(digest);
  }

  /// The same id for a file on disk, read a megabyte at a time on another
  /// isolate, so a multi-gigabyte video is never in memory at once.
  Future<String> photoIdForFile(String path) async {
    final digest = await Isolate.run(() {
      final out = _DigestSink();
      final input = hash.sha256.startChunkedConversion(out);
      final file = File(path).openSync();
      try {
        final buffer = Uint8List(1 << 20);
        while (true) {
          final n = file.readIntoSync(buffer);
          if (n <= 0) break;
          input.add(Uint8List.sublistView(buffer, 0, n));
        }
      } finally {
        file.closeSync();
      }
      input.close();
      return out.value!.bytes;
    });
    return _idFromDigest(digest);
  }

  /// The same id computed from pieces handed over one after another, for a
  /// large file that only exists in memory.
  String photoIdForChunks(Iterable<List<int>> chunks) {
    final out = _DigestSink();
    final input = hash.sha256.startChunkedConversion(out);
    for (final c in chunks) {
      input.add(c);
    }
    input.close();
    return _idFromDigest(out.value!.bytes);
  }

  String _idFromDigest(List<int> digest) {
    final mac = hash.Hmac(hash.sha256, _dedupeKey).convert(digest).bytes;
    return mac.take(16).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Below this, starting an isolate costs more than the hash it saves.
  static const _hashElsewhereAbove = 512 * 1024;

  static Future<SecretKey> _deriveKek(
    String passphrase,
    List<int> salt,
    KdfParams p,
  ) async {
    // Argon2id is deliberately slow; keep it off the UI isolate.
    final bytes = await Isolate.run(() async {
      final key = await Argon2id(
        parallelism: p.parallelism,
        memory: p.memoryKiB,
        iterations: p.iterations,
        hashLength: 32,
      ).deriveKey(secretKey: SecretKey(utf8.encode(passphrase)), nonce: salt);
      return key.extractBytes();
    });
    return SecretKey(bytes);
  }
}

/// Catches the one digest a chunked SHA-256 produces.
class _DigestSink implements Sink<hash.Digest> {
  hash.Digest? value;
  @override
  void add(hash.Digest data) => value = data;
  @override
  void close() {}
}
