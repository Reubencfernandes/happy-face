import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../app/credentials.dart';
import '../data/bucket_layout.dart';
import '../data/bucket_name.dart';
import '../s3/s3_client.dart';
import 'auth_page.dart';
import 'theme.dart';

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
  // A new library gets its own name, so a second one never collides with
  // the first and nobody has to invent one.
  late final _bucket = TextEditingController(
    text: widget.previous?.bucket ?? generateBucketName(),
  );
  bool _busy = false, _obscure = true;

  /// The bucket name is chosen for you; this opens the field to change it.
  bool _advanced = false;
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
      if (await client.isPubliclyExposed(probeKey: BucketLayout.keys)) {
        setState(() => _publicBucket = account);
        return;
      }
      final hasLibrary = await client.headObject(BucketLayout.keys) != null;
      if (!mounted) return;
      // This page sits on top of the app's main screen when it was reached
      // from the welcome screen, so step back before handing over.
      final connected = widget.onConnected;
      final navigator = Navigator.of(context);
      if (navigator.canPop()) navigator.pop();
      connected(ConnectResult(account, hasLibrary));
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
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * 0.9,
      maxWidth: 560,
    ),
    builder: (context) => const _HelpSheet(),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Form(
      key: _form,
      child: AuthPage(
        title: 'Let\'s get\nStarted',
        subtitle:
            'Happy Drive keeps your photos in a private Hugging Face bucket '
            'that belongs to you. It needs three things to reach it.',
        onBack: _busy ? null : () => Navigator.of(context).maybePop(),
        children: [
          TextFormField(
            controller: _username,
            enabled: !_busy,
            autocorrect: false,
            textInputAction: TextInputAction.next,
            decoration: authField(
              hint: 'Hugging Face username',
              icon: Icons.person_outline,
            ),
            validator: (v) =>
                RegExp(
                  r'^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$',
                ).hasMatch(v?.trim() ?? '')
                ? null
                : 'Enter your username, e.g. reuben',
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _accessKey,
            enabled: !_busy,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.next,
            decoration: authField(hint: 'Access key', icon: Icons.key_outlined),
            validator: (v) => (v?.trim().length ?? 0) >= 8
                ? null
                : 'Paste the access key (starts with HFAK)',
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _secret,
            enabled: !_busy,
            obscureText: _obscure,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => _connect(),
            decoration: authField(
              hint: 'Secret',
              icon: Icons.lock_outline,
              suffix: IconButton(
                tooltip: _obscure ? 'Show secret' : 'Hide secret',
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
            validator: (v) => (v?.trim().length ?? 0) >= 8
                ? null
                : 'Paste the secret shown with the key',
          ),
          if (_advanced) ...[
            const SizedBox(height: 12),
            TextFormField(
              controller: _bucket,
              enabled: !_busy,
              autocorrect: false,
              decoration: authField(
                hint: 'Bucket name',
                icon: Icons.inventory_2_outlined,
                helper: 'Created for you if it doesn\'t exist yet',
                suffix: IconButton(
                  tooltip: 'Suggest another name',
                  iconSize: 19,
                  color: inkMuted,
                  icon: const Icon(Icons.casino_outlined),
                  onPressed: _busy
                      ? null
                      : () =>
                            setState(() => _bucket.text = generateBucketName()),
                ),
              ),
              validator: (v) =>
                  RegExp(
                    r'^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$',
                  ).hasMatch(v?.trim() ?? '')
                  ? null
                  : 'Letters, numbers, dots, dashes',
            ),
          ],
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: InkWell(
              onTap: _busy ? null : _showHelp,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  'Where do I get these?',
                  style: theme.textTheme.bodySmall?.copyWith(color: inkMuted),
                ),
              ),
            ),
          ),
          if (_error != null)
            AuthBanner(icon: Icons.error_outline, text: _error!),
          if (_publicBucket != null)
            AuthBanner(
              icon: Icons.public,
              text:
                  'The bucket "${_publicBucket!.bucket}" is public. Your photos would be encrypted, '
                  'but please make it private first: open huggingface.co/buckets/'
                  '${_publicBucket!.namespace}/${_publicBucket!.bucket} → Settings → Private, then tap Connect again.',
            ),
          const SizedBox(height: 14),
          AuthButton(label: 'Connect', busy: _busy, onPressed: _connect),
          const SizedBox(height: 16),
          // The bucket is made for you, so this says which one — and lets
          // anyone with a library already point at theirs.
          AuthFootnote(
            text: _advanced
                ? 'Happy Drive will use this bucket.'
                : 'New private bucket: "${_bucket.text}".',
            action: _advanced ? 'Hide' : 'Change',
            onTap: _busy ? null : () => setState(() => _advanced = !_advanced),
          ),
          const SizedBox(height: 14),
          Text(
            'Your keys stay in this phone\'s secure storage and are only ever '
            'sent to Hugging Face.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: inkMuted.withValues(alpha: 0.7),
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _HelpSheet extends StatelessWidget {
  const _HelpSheet();

  static const _tokensUrl = 'https://huggingface.co/settings/tokens';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // A screenshot of huggingface.co, shown at its own scale where it is
    // small so it stays crisp.
    Widget shot(String name, {double? maxWidth}) => Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth ?? double.infinity),
          child: Container(
            clipBehavior: Clip.antiAlias,
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Image.asset('assets/help/$name', fit: BoxFit.contain),
          ),
        ),
      ),
    );

    Widget step(
      int n,
      String title,
      String body, {
      List<Widget> extra = const [],
    }) => Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
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
          ...extra,
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
            const SizedBox(height: 6),
            Text(
              'Happy Drive signs in with S3 credentials generated from a '
              'Hugging Face access token. It takes about a minute.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            step(
              1,
              'Open Access Tokens',
              'On huggingface.co, click your profile picture (top right) and '
                  'choose "Access Tokens".',
              extra: [
                shot('1_access_tokens.png', maxWidth: 190),
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.copy_all_outlined, size: 18),
                    label: const Text('Copy the link'),
                    onPressed: () async {
                      await Clipboard.setData(
                        const ClipboardData(text: _tokensUrl),
                      );
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Link copied: $_tokensUrl'),
                          ),
                        );
                      }
                    },
                  ),
                ),
              ],
            ),
            step(
              2,
              'Create a token, if you have none',
              'Click "Create new token" and give it Write access. An existing '
                  'token with write access works too.',
            ),
            step(
              3,
              'Generate S3 credentials',
              'On the token\'s row, open the ⋯ menu and choose '
                  '"Generate S3 credentials".',
              extra: [shot('2_generate_s3.png')],
            ),
            step(
              4,
              'Copy both values',
              'AWS_ACCESS_KEY_ID goes in "Access key" (it starts with HFAK) '
                  'and AWS_SECRET_ACCESS_KEY goes in "Secret". The secret is '
                  'shown only once, so copy it now.',
              extra: [shot('3_copy_values.png')],
            ),
            step(
              5,
              'Your username',
              'The name in your profile address: huggingface.co/<username>.',
            ),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.lock_outline,
                    size: 20,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Happy Drive makes the bucket for you, with a name of '
                      'its own. If you would rather make it yourself, use '
                      'huggingface.co/new-bucket with Private ticked — Happy '
                      'Drive refuses to use a public bucket.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
