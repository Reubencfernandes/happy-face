import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../s3/s3_client.dart';
import '../s3/sigv4.dart';

typedef BucketClientFactory = BucketClient Function(StoredAccount account);

BucketClient defaultBucketClient(StoredAccount a) => BucketClient(
  namespace: a.namespace,
  bucket: a.bucket,
  credentials: a.credentials,
);

class StoredAccount {
  final String namespace;
  final String bucket;
  final String accessKeyId;
  final String secretAccessKey;
  const StoredAccount({
    required this.namespace,
    required this.bucket,
    required this.accessKeyId,
    required this.secretAccessKey,
  });

  S3Credentials get credentials => S3Credentials(accessKeyId, secretAccessKey);
  String get id => '$namespace/$bucket';

  Map<String, String> toJson() => {
    'namespace': namespace,
    'bucket': bucket,
    'accessKeyId': accessKeyId,
    'secretAccessKey': secretAccessKey,
  };

  factory StoredAccount.fromJson(Map<String, dynamic> j) => StoredAccount(
    namespace: j['namespace'] as String,
    bucket: j['bucket'] as String,
    accessKeyId: j['accessKeyId'] as String,
    secretAccessKey: j['secretAccessKey'] as String,
  );
}

/// Secrets kept in the iOS Keychain / Android Keystore-backed storage.
/// Nothing here is ever uploaded.
class CredentialStore {
  final FlutterSecureStorage _storage;
  const CredentialStore([this._storage = const FlutterSecureStorage()]);

  static const _account = 'account';
  String _masterKey(StoredAccount a) => 'master_key:${a.id}';

  Future<StoredAccount?> readAccount() async {
    final raw = await _storage.read(key: _account);
    if (raw == null) return null;
    try {
      return StoredAccount.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on FormatException {
      return null;
    }
  }

  Future<void> saveAccount(StoredAccount account) =>
      _storage.write(key: _account, value: jsonEncode(account.toJson()));

  Future<List<int>?> readMasterKey(StoredAccount account) async {
    final raw = await _storage.read(key: _masterKey(account));
    return raw == null ? null : base64Decode(raw);
  }

  Future<void> saveMasterKey(StoredAccount account, List<int> key) =>
      _storage.write(key: _masterKey(account), value: base64Encode(key));

  Future<void> forgetMasterKey(StoredAccount account) =>
      _storage.delete(key: _masterKey(account));

  Future<void> forgetEverything() => _storage.deleteAll();
}
