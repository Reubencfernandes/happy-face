import 'dart:convert';
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
      return fromMasterKey(master);
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
    final box = await _aes.encrypt(
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
  String photoIdFor(List<int> plaintext) {
    final digest = hash.sha256.convert(plaintext).bytes;
    final mac = hash.Hmac(hash.sha256, _dedupeKey).convert(digest).bytes;
    return mac.take(16).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

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
