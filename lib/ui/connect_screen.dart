import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../app/credentials.dart';
import '../data/bucket_layout.dart';
import '../s3/s3_client.dart';

/// Result of a successful connection check.
class ConnectResult {
  final StoredAccount account;

  /// True if this bucket already holds a Happy Drive library.
  final bool hasLibrary;
  const ConnectResult(this.account, this.hasLibrary);
}

class ConnectScreen extends StatefulWidget {
  final void Function(ConnectResult result) onConnected;
  final BucketClientFactory clientFactory;
  final StoredAccount? previous;

  const ConnectScreen({
    super.key,
    required this.onConnected,
    this.clientFactory = defaultBucketClient,
    this.previous,
  });

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _form = GlobalKey<FormState>();
  late final _username = TextEditingController(
    text: widget.previous?.namespace,
  );
  late final _accessKey = TextEditingController(
    text: widget.previous?.accessKeyId,
  );
  final _secret = TextEditingController();
  late final _bucket = TextEditingController(
    text: widget.previous?.bucket ?? 'happy-drive',
  );
  bool _busy = false, _obscure = true, _advanced = false;
  String? _error;

  /// Set when the bucket turns out to be public, until the user fixes it.
  StoredAccount? _publicBucket;

  @override
  void dispose() {
    for (final c in [_username, _accessKey, _secret, _bucket]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _connect() async {
    if (!_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    final account = StoredAccount(
      namespace: _username.text.trim(),
      bucket: _bucket.text.trim(),
      accessKeyId: _accessKey.text.trim(),
      secretAccessKey: _secret.text.trim(),
    );
    setState(() {
      _busy = true;
      _error = null;
      _publicBucket = null;
    });
    final client = widget.clientFactory(account);
    try {
      if (!await client.bucketExists()) {
        await client.createBucket();
      }
      if (await client.isPubliclyListable()) {
        setState(() => _publicBucket = account);
        return;
      }
      final hasLibrary = await client.headObject(BucketLayout.keys) != null;
      if (mounted) widget.onConnected(ConnectResult(account, hasLibrary));
    } on S3Exception catch (e) {
      setState(
        () => _error = e.isNotFound
            ? 'No bucket named "${account.bucket}" and it could not be created. '
                  'Check the username matches the account the keys belong to.'
            : e.friendly,
      );
    } on SocketException {
      setState(() => _error = 'No internet connection.');
    } on http.ClientException {
      setState(
        () => _error = 'Could not reach Hugging Face. Check your connection.',
      );
    } on ArgumentError catch (e) {
      setState(() => _error = '${e.message}');
    } catch (e) {
      setState(() => _error = 'Something went wrong: $e');
    } finally {
      client.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showHelp() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => const _HelpSheet(),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Form(
              key: _form,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Icon(
                      Icons.wb_sunny_rounded,
                      size: 36,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Happy Drive',
                    style: theme.textTheme.headlineLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Your photos, backed up to your own private Hugging Face storage. '
                    'Encrypted on this phone before they leave it.',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 32),
                  TextFormField(
                    controller: _username,
                    enabled: !_busy,
                    autocorrect: false,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Hugging Face username',
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                    validator: (v) =>
                        RegExp(
                          r'^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$',
                        ).hasMatch(v?.trim() ?? '')
                        ? null
                        : 'Enter your username, e.g. reuben',
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _accessKey,
                    enabled: !_busy,
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Access key',
                      hintText: 'HFAK…',
                      prefixIcon: Icon(Icons.key_outlined),
                    ),
                    validator: (v) => (v?.trim().length ?? 0) >= 8
                        ? null
                        : 'Paste the access key (starts with HFAK)',
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _secret,
                    enabled: !_busy,
                    obscureText: _obscure,
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => _connect(),
                    decoration: InputDecoration(
                      labelText: 'Secret',
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        tooltip: _obscure ? 'Show secret' : 'Hide secret',
                        icon: Icon(
                          _obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                    validator: (v) => (v?.trim().length ?? 0) >= 8
                        ? null
                        : 'Paste the secret shown with the key',
                  ),
                  if (_advanced) ...[
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _bucket,
                      enabled: !_busy,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'Bucket name',
                        prefixIcon: Icon(Icons.inventory_2_outlined),
                        helperText: 'Created for you if it doesn\'t exist',
                      ),
                      validator: (v) =>
                          RegExp(
                            r'^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$',
                          ).hasMatch(v?.trim() ?? '')
                          ? null
                          : 'Letters, numbers, dots, dashes',
                    ),
                  ],
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() => _advanced = !_advanced),
                      child: Text(_advanced ? 'Hide options' : 'More options'),
                    ),
                  ),
                  if (_error != null)
                    _Banner(
                      icon: Icons.error_outline,
                      color: theme.colorScheme.error,
                      text: _error!,
                    ),
                  if (_publicBucket != null)
                    _Banner(
                      icon: Icons.public,
                      color: theme.colorScheme.error,
                      text:
                          'The bucket "${_publicBucket!.bucket}" is public. Your photos would be encrypted, '
                          'but please make it private first: open huggingface.co/buckets/'
                          '${_publicBucket!.namespace}/${_publicBucket!.bucket} → Settings → Private, then tap Connect again.',
                    ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: _busy ? null : _connect,
                    child: _busy
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2.5),
                          )
                        : const Text('Connect'),
                  ),
                  const SizedBox(height: 12),
                  Center(
                    child: TextButton.icon(
                      onPressed: _showHelp,
                      icon: const Icon(Icons.help_outline),
                      label: const Text('Where do I get these?'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Your keys stay in this phone\'s secure storage and are only ever sent to Hugging Face.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;
  const _Banner({required this.icon, required this.color, required this.text});

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(top: 8),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: color),
        const SizedBox(width: 12),
        Expanded(child: Semantics(liveRegion: true, child: Text(text))),
      ],
    ),
  );
}

class _HelpSheet extends StatelessWidget {
  const _HelpSheet();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget step(int n, String title, String body) => Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 14,
            child: Text('$n', style: const TextStyle(fontSize: 13)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Getting your keys', style: theme.textTheme.titleLarge),
            const SizedBox(height: 20),
            step(
              1,
              'Open your token settings',
              'Sign in at huggingface.co and go to Settings → Access Tokens.',
            ),
            step(
              2,
              'Create a Write token',
              'Tap "Create new token", choose Write, and give it a name like "Happy Drive".',
            ),
            step(
              3,
              'Generate S3 credentials',
              'In the token list, open that token\'s menu (⋯) and choose "Generate S3 credentials".',
            ),
            step(
              4,
              'Copy both values',
              'Copy the access key (starts with HFAK) and the secret. The secret is only shown once.',
            ),
            step(
              5,
              'Username',
              'Your username is the name in your profile URL: huggingface.co/<username>.',
            ),
            const SizedBox(height: 4),
            Text(
              'A free account includes 100 GB of private storage. Happy Drive creates a private bucket called '
              '"happy-drive" for you.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
