import 'dart:io';

import 'package:flutter/material.dart';

import '../app/credentials.dart';
import '../app/password_manager.dart';
import '../crypto/vault.dart';
import '../data/bucket_layout.dart';
import '../s3/s3_client.dart';
import 'auth_page.dart';
import 'theme.dart';

class PassphraseScreen extends StatefulWidget {
  final StoredAccount account;

  /// True to unlock an existing library, false to create one.
  final bool hasLibrary;
  final void Function(Vault vault) onUnlocked;
  final VoidCallback onBack;
  final BucketClientFactory clientFactory;
  final KdfParams kdfParams;
  final PasswordManager passwords;

  const PassphraseScreen({
    super.key,
    required this.account,
    required this.hasLibrary,
    required this.onUnlocked,
    required this.onBack,
    this.clientFactory = defaultBucketClient,
    this.kdfParams = const KdfParams(),
    this.passwords = const ChannelPasswordManager(),
  });

  @override
  State<PassphraseScreen> createState() => _PassphraseScreenState();
}

class _PassphraseScreenState extends State<PassphraseScreen> {
  final _form = GlobalKey<FormState>();
  final _pass = TextEditingController();
  final _confirm = TextEditingController();
  late bool _unlock = widget.hasLibrary;
  bool _busy = false, _obscure = true, _understood = false;

  /// The passphrase last saved to the password manager, so the button can
  /// say it's done until the passphrase is changed.
  String? _saved;
  String? _error;

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final passphrase = _pass.text;
    final result = await widget.passwords.save(widget.account, passphrase);
    if (!mounted) return;
    switch (result) {
      case SaveResult.saved:
        setState(() => _saved = passphrase);
      case SaveResult.cancelled:
        break;
      case SaveResult.unavailable:
        setState(
          () => _error =
              'Couldn\'t reach a password manager on this phone. Write the '
              'passphrase down instead.',
        );
    }
  }

  Future<void> _useSaved() async {
    final passphrase = await widget.passwords.load(widget.account);
    if (!mounted) return;
    if (passphrase == null) {
      setState(
        () =>
            _error = 'No saved passphrase for ${widget.account.id} was picked.',
      );
      return;
    }
    _pass.text = passphrase;
    await _submit();
  }

  @override
  void dispose() {
    _pass.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    if (!_unlock && !_understood) {
      setState(
        () => _error =
            'Please confirm you understand the passphrase can\'t be recovered.',
      );
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    final client = widget.clientFactory(widget.account);
    try {
      final Vault vault;
      if (_unlock) {
        final envelope = await client.getObject(BucketLayout.keys);
        vault = await Vault.unlock(envelope, _pass.text);
      } else {
        final (created, envelope) = await Vault.create(
          _pass.text,
          params: widget.kdfParams,
        );
        try {
          await client.putObject(
            BucketLayout.keys,
            envelope,
            contentType: 'application/json',
            ifNoneMatch: '*',
          );
        } on S3Exception catch (e) {
          if (!e.isPreconditionFailed) rethrow;
          // Another device set up this library a moment ago.
          setState(() {
            _unlock = true;
            _error =
                'This library was just set up from another device. Enter that passphrase.';
          });
          return;
        }
        vault = created;
      }
      if (mounted) widget.onUnlocked(vault);
    } on WrongPassphraseException {
      setState(() => _error = 'That passphrase doesn\'t unlock this library.');
    } on S3Exception catch (e) {
      setState(() => _error = e.friendly);
    } on SocketException {
      setState(() => _error = 'No internet connection.');
    } on FormatException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Something went wrong: $e');
    } finally {
      client.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Form(
      key: _form,
      child: AuthPage(
        title: _unlock ? 'Hey,\nWelcome\nBack' : 'Create\nYour passphrase',
        subtitle: _unlock
            ? 'Enter the passphrase you chose when you set up Happy Drive '
                  'for ${widget.account.namespace}.'
            : 'Every photo is locked with this passphrase before it leaves '
                  'your phone. Not even Hugging Face can see them.',
        onBack: _busy ? null : widget.onBack,
        children: [
          TextFormField(
            controller: _pass,
            enabled: !_busy,
            obscureText: _obscure,
            autocorrect: false,
            enableSuggestions: false,
            autofocus: true,
            textInputAction: _unlock
                ? TextInputAction.done
                : TextInputAction.next,
            onFieldSubmitted: (_) => _unlock ? _submit() : null,
            onChanged: (_) => setState(() {}),
            decoration: authField(
              hint: 'Passphrase',
              icon: Icons.lock_outline,
              helper: _unlock ? null : _strengthHint(_pass.text),
              suffix: IconButton(
                tooltip: _obscure ? 'Show passphrase' : 'Hide passphrase',
                iconSize: 19,
                color: inkMuted,
                icon: Icon(
                  _obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
            validator: (v) {
              if (v == null || v.isEmpty) return 'Enter a passphrase';
              if (!_unlock && v.length < 10) {
                return 'Use at least 10 characters. A short sentence works well.';
              }
              return null;
            },
          ),
          if (!_unlock) ...[
            const SizedBox(height: 12),
            TextFormField(
              controller: _confirm,
              enabled: !_busy,
              obscureText: _obscure,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.done,
              decoration: authField(
                hint: 'Type it again',
                icon: Icons.lock_outline,
              ),
              validator: (v) =>
                  v == _pass.text ? null : 'The passphrases don\'t match',
            ),
            if (widget.passwords.available) ...[
              const SizedBox(height: 12),
              _saved != null && _saved == _pass.text
                  ? Row(
                      children: [
                        Icon(
                          Icons.check_circle_rounded,
                          size: 20,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text('Saved to Google Password Manager'),
                        ),
                      ],
                    )
                  : OutlinedButton.icon(
                      onPressed: _busy ? null : _save,
                      icon: const Icon(Icons.key_rounded),
                      label: const Text('Save to Google Password Manager'),
                    ),
            ],
            const SizedBox(height: 18),
            Material(
              // A Material (not a decorated box) so the checkbox's ink
              // ripple stays visible.
              color: theme.colorScheme.error.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(14),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.warning_amber_rounded,
                          size: 20,
                          color: theme.colorScheme.error,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'There is no "forgot passphrase"',
                            style: theme.textTheme.titleSmall,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'If you forget it, your backed-up photos can never be '
                      'opened again, by you, by us, or by Hugging Face. Write '
                      'it down somewhere safe.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: inkMuted,
                        height: 1.4,
                      ),
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _understood,
                      onChanged: _busy
                          ? null
                          : (v) => setState(() => _understood = v ?? false),
                      title: Text(
                        'I understand and have saved my passphrase',
                        style: theme.textTheme.bodyMedium,
                      ),
                      controlAffinity: ListTileControlAffinity.leading,
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (_error != null)
            AuthBanner(icon: Icons.error_outline, text: _error!),
          const SizedBox(height: 22),
          AuthButton(
            label: _unlock ? 'Unlock' : 'Create library',
            busy: _busy,
            busyLabel: _unlock ? 'Unlocking…' : 'Securing your library…',
            onPressed: _submit,
          ),
          if (_unlock && widget.passwords.available) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _busy ? null : _useSaved,
              icon: const Icon(Icons.key_rounded),
              label: const Text('Use saved passphrase'),
            ),
          ],
        ],
      ),
    );
  }

  static String? _strengthHint(String p) {
    if (p.isEmpty) {
      return 'Tip: a few unrelated words, like "mango kite river 42"';
    }
    final kinds = [
      RegExp(r'[a-z]'),
      RegExp(r'[A-Z]'),
      RegExp(r'[0-9]'),
      RegExp(r'[^A-Za-z0-9]'),
    ].where((r) => r.hasMatch(p)).length;
    final score = p.length + kinds * 3;
    if (score < 16) return 'Weak';
    if (score < 24) return 'Okay';
    return 'Strong';
  }
}
