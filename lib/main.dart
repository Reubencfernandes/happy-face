import 'dart:io';

import 'package:flutter/material.dart';

import 'app/credentials.dart';
import 'app/paths.dart';
import 'app/session.dart';
import 'crypto/vault.dart';
import 'media/gallery.dart';
import 'sync/background.dart';
import 'ui/connect_screen.dart';
import 'ui/home_screen.dart';
import 'ui/passphrase_screen.dart';
import 'ui/theme.dart';

void main() {
  // cryptography_flutter registers itself, routing AES-GCM through the
  // platform's native crypto, which is much faster on phones.
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HappyDriveApp());
}

class HappyDriveApp extends StatefulWidget {
  final CredentialStore credentials;
  final Future<Directory> Function() dataDir;
  final BucketClientFactory clientFactory;
  final Gallery gallery;
  final KdfParams kdfParams;

  const HappyDriveApp({
    super.key,
    this.credentials = const CredentialStore(),
    this.dataDir = appDataDir,
    this.clientFactory = defaultBucketClient,
    this.gallery = const Gallery(),
    this.kdfParams = const KdfParams(),
  });

  @override
  State<HappyDriveApp> createState() => _HappyDriveAppState();
}

enum _Stage { starting, connect, passphrase, opening, home }

class _HappyDriveAppState extends State<HappyDriveApp> {
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  var _stage = _Stage.starting;
  StoredAccount? _account;
  bool _hasLibrary = false;
  Session? _session;

  CredentialStore get _store => widget.credentials;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  @override
  void dispose() {
    _session?.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    try {
      final account = await _store.readAccount();
      if (account == null) return _go(_Stage.connect);
      _account = account;
      final key = await _store.readMasterKey(account);
      if (key == null) {
        _hasLibrary = true;
        return _go(_Stage.passphrase);
      }
      await _open(await Vault.fromMasterKey(key));
    } catch (_) {
      _go(_Stage.connect);
      _toast('Couldn\'t restore your sign-in. Please connect again.');
    }
  }

  void _go(_Stage stage) {
    if (mounted) setState(() => _stage = stage);
  }

  void _toast(String text) => WidgetsBinding.instance.addPostFrameCallback(
    (_) => _messenger.currentState?.showSnackBar(SnackBar(content: Text(text))),
  );

  Future<void> _connected(ConnectResult result) async {
    await _store.saveAccount(result.account);
    _account = result.account;
    _hasLibrary = result.hasLibrary;
    _go(_Stage.passphrase);
  }

  Future<void> _unlocked(Vault vault) async {
    await _store.saveMasterKey(_account!, await vault.exportMasterKey());
    try {
      await _open(vault);
    } catch (e) {
      _go(_Stage.passphrase);
      _toast('Couldn\'t open the library on this phone: $e');
    }
  }

  Future<void> _open(Vault vault) async {
    _go(_Stage.opening);
    final session = await Session.open(
      account: _account!,
      vault: vault,
      dataDir: await widget.dataDir(),
      credentials: _store,
      clientFactory: widget.clientFactory,
      gallery: widget.gallery,
    );
    _session?.dispose();
    _session = session;
    _go(_Stage.home);
  }

  Future<void> _signOut() async {
    final session = _session;
    _session = null;
    _go(_Stage.connect);
    if (session != null) {
      await session.photos.clearCache();
      session.dispose();
    }
    await BackgroundBackup.configure(
      enabled: false,
      wifiOnly: true,
    ).catchError((_) {});
    await _store.forgetEverything();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Happy Drive',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: _messenger,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      home: AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        child: switch (_stage) {
          _Stage.starting || _Stage.opening => Scaffold(
            key: ValueKey(_stage),
            body: const Center(child: CircularProgressIndicator()),
          ),
          _Stage.connect => ConnectScreen(
            key: const ValueKey('connect'),
            previous: _account,
            clientFactory: widget.clientFactory,
            onConnected: _connected,
          ),
          _Stage.passphrase => PassphraseScreen(
            key: const ValueKey('passphrase'),
            account: _account!,
            hasLibrary: _hasLibrary,
            clientFactory: widget.clientFactory,
            kdfParams: widget.kdfParams,
            onUnlocked: _unlocked,
            onBack: () => _go(_Stage.connect),
          ),
          _Stage.home => HomeScreen(
            key: const ValueKey('home'),
            session: _session!,
            onSignOut: _signOut,
          ),
        },
      ),
    );
  }
}
