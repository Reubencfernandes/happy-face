import 'dart:io';

import 'package:flutter/services.dart';

import 'credentials.dart';

enum SaveResult { saved, cancelled, unavailable }

/// The phone's password manager, for keeping the library passphrase
/// somewhere the person won't lose it.
///
/// Only Android for now, through Credential Manager (Google Password
/// Manager, or whichever provider the phone uses). iOS would need the app
/// tied to a website with Associated Domains before it offers to save.
abstract class PasswordManager {
  const PasswordManager();

  bool get available;

  /// Offers to save [passphrase] under the library's `namespace/bucket`, so
  /// two libraries don't overwrite each other.
  Future<SaveResult> save(StoredAccount account, String passphrase);

  /// A passphrase saved for this library, if the person picks one.
  Future<String?> load(StoredAccount account);
}

class ChannelPasswordManager extends PasswordManager {
  const ChannelPasswordManager();

  static const _channel = MethodChannel('happy_drive/passwords');

  @override
  bool get available => Platform.isAndroid;

  @override
  Future<SaveResult> save(StoredAccount account, String passphrase) async {
    if (!available) return SaveResult.unavailable;
    try {
      final result = await _channel.invokeMethod<String>('save', {
        'id': account.id,
        'password': passphrase,
      });
      return SaveResult.values.asNameMap()[result] ?? SaveResult.unavailable;
    } on PlatformException {
      return SaveResult.unavailable;
    } on MissingPluginException {
      return SaveResult.unavailable;
    }
  }

  @override
  Future<String?> load(StoredAccount account) async {
    if (!available) return null;
    try {
      final saved = await _channel.invokeMapMethod<String, String>('load');
      if (saved == null || saved['id'] != account.id) return null;
      return saved['password'];
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
