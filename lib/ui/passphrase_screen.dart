import 'dart:io';

import 'package:flutter/material.dart';

import '../app/credentials.dart';
import '../crypto/vault.dart';
import '../data/bucket_layout.dart';
import '../s3/s3_client.dart';

class PassphraseScreen extends StatefulWidget {
  final StoredAccount account;

  /// True to unlock an existing library, false to create one.
  final bool hasLibrary;
  final void Function(Vault vault) onUnlocked;
  final VoidCallback onBack;
  final BucketClientFactory clientFactory;
  final KdfParams kdfParams;

  const PassphraseScreen({
    super.key,
    required this.account,
    required this.hasLibrary,
    required this.onUnlocked,
    required this.onBack,
    this.clientFactory = defaultBucketClient,
    this.kdfParams = const KdfParams(),
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
  String? _error;

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
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Back',
          icon: const Icon(Icons.arrow_back),
          onPressed: _busy ? null : widget.onBack,
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Form(
              key: _form,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
                children: [
                  Icon(
                    _unlock
                        ? Icons.lock_open_rounded
                        : Icons.shield_moon_outlined,
                    size: 48,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    _unlock ? 'Welcome back' : 'Create your passphrase',
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _unlock
                        ? 'Enter the passphrase you chose when you set up Happy Drive for ${widget.account.namespace}.'
                        : 'Every photo is locked with this passphrase before it leaves your phone. '
                              'Not even Hugging Face can see them.',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 28),
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
                    decoration: InputDecoration(
                      labelText: 'Passphrase',
                      prefixIcon: const Icon(Icons.password),
                      suffixIcon: IconButton(
                        tooltip: _obscure
                            ? 'Show passphrase'
                            : 'Hide passphrase',
                        icon: Icon(
                          _obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                      helperText: _unlock ? null : _strengthHint(_pass.text),
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
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _confirm,
                      enabled: !_busy,
                      obscureText: _obscure,
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.done,
                      decoration: const InputDecoration(
                        labelText: 'Type it again',
                        prefixIcon: Icon(Icons.password),
                      ),
                      validator: (v) => v == _pass.text
                          ? null
                          : 'The passphrases don\'t match',
                    ),
                    const SizedBox(height: 18),
                    Material(
                      // A Material (not a decorated box) so the checkbox's
                      // ink ripple stays visible.
                      color: theme.colorScheme.errorContainer.withValues(
                        alpha: 0.5,
                      ),
                      borderRadius: BorderRadius.circular(14),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.warning_amber_rounded,
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
                            const Text(
                              'If you forget it, your backed-up photos can never be opened again, by you, '
                              'by us, or by Hugging Face. Write it down somewhere safe.',
                            ),
                            CheckboxListTile(
                              contentPadding: EdgeInsets.zero,
                              value: _understood,
                              onChanged: _busy
                                  ? null
                                  : (v) => setState(
                                      () => _understood = v ?? false,
                                    ),
                              title: const Text(
                                'I understand and have saved my passphrase',
                              ),
                              controlAffinity: ListTileControlAffinity.leading,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 14),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        _error!,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ),
                  ],
                  const SizedBox(height: 22),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: _busy
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Flexible(
                                child: Text(
                                  _unlock
                                      ? 'Unlocking…'
                                      : 'Securing your library…',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          )
                        : Text(_unlock ? 'Unlock' : 'Create library'),
                  ),
                ],
              ),
            ),
          ),
        ),
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
