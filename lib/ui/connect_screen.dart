import 'dart:async';
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

/// Which bucket the library should live in: a fresh one, or one that is
/// already in the account. A second phone, or a reinstall, always wants the
/// second — and until now the screen only really offered the first.
enum BucketMode { create, existing }

/// A bucket found in the account, and whether Happy Drive has been here.
class _FoundBucket {
  final String name;
  final bool? hasLibrary;
  const _FoundBucket(this.name, this.hasLibrary);
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
  final _newBucket = TextEditingController(text: generateBucketName());

  /// Kept apart from the new-bucket name, so switching between the two
  /// doesn't throw away what was typed or found.
  late final _existingBucket = TextEditingController(
    text: widget.previous?.bucket,
  );

  /// Someone coming back already has a bucket; a new phone doesn't.
  late BucketMode _mode = widget.previous == null
      ? BucketMode.create
      : BucketMode.existing;

  bool _busy = false, _obscure = true, _browsing = false;
  String? _error;

  /// Set when the bucket turns out to be public, until the user fixes it.
  StoredAccount? _publicBucket;

  TextEditingController get _bucket =>
      _mode == BucketMode.create ? _newBucket : _existingBucket;

  @override
  void dispose() {
    for (final c in [
      _username,
      _accessKey,
      _secret,
      _newBucket,
      _existingBucket,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  /// The account the fields describe, for [bucket] or the chosen one.
  StoredAccount _accountFor([String? bucket]) => StoredAccount(
    namespace: _username.text.trim(),
    bucket: bucket ?? _bucket.text.trim(),
    accessKeyId: _accessKey.text.trim(),
    secretAccessKey: _secret.text.trim(),
  );

  Future<void> _connect() async {
    if (!_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    final account = _accountFor();
    final creating = _mode == BucketMode.create;
    setState(() {
      _busy = true;
      _error = null;
      _publicBucket = null;
    });
    final client = widget.clientFactory(account);
    try {
      final exists = await client.bucketExists();
      if (!exists && creating) {
        // A reinstall wipes this phone's memory of the library, so the
        // screen starts on "New bucket" — and tapping through it used to
        // leave people in an empty library, photos safe but out of sight.
        final libraries = await _librariesIn(client);
        if (!mounted) return;
        if (libraries.isNotEmpty) {
          final choice = await showDialog<String>(
            context: context,
            builder: (_) => _ExistingLibraries(names: libraries),
          );
          if (choice == null || !mounted) return;
          if (choice.isNotEmpty) {
            setState(() {
              _mode = BucketMode.existing;
              _existingBucket.text = choice;
            });
            // Once this attempt has let go of the form, open that one.
            unawaited(Future.microtask(_connect));
            return;
          }
        }
      }
      if (!exists && !creating) {
        // Don't quietly make a bucket the user meant to reuse: a typo would
        // leave them staring at an empty library wondering where it went.
        setState(
          () => _error =
              'There\'s no bucket named "${account.bucket}" in this account. '
              'Check the spelling, tap Browse to pick one, or switch to '
              '"New bucket" to make it.',
        );
        return;
      }
      if (!exists) await client.createBucket();
      final keys = await client.headObject(BucketLayout.keys);
      if (exists && creating && keys != null) {
        setState(
          () => _error =
              '"${account.bucket}" already holds a Happy Drive library. '
              'Switch to "My bucket" to open it, or pick another name.',
        );
        return;
      }
      if (await client.isPubliclyExposed(probeKey: BucketLayout.keys)) {
        setState(() => _publicBucket = account);
        return;
      }
      if (!mounted) return;
      // This page sits on top of the app's main screen when it was reached
      // from the welcome screen, so step back before handing over.
      final connected = widget.onConnected;
      final navigator = Navigator.of(context);
      if (navigator.canPop()) navigator.pop();
      connected(ConnectResult(account, keys != null));
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

  /// The buckets in this account that already hold a library. Empty when
  /// there are none, or when Hugging Face won't list them.
  Future<List<String>> _librariesIn(BucketClient client) async {
    final names = await client.listBuckets();
    if (names == null) return const [];
    return [
      for (final b in await _withLibraries(names))
        if (b.hasLibrary ?? false) b.name,
    ];
  }

  /// Lists the account's buckets and marks the ones Happy Drive knows.
  Future<void> _browse() async {
    if (_username.text.trim().isEmpty ||
        _accessKey.text.trim().length < 8 ||
        _secret.text.trim().length < 8) {
      setState(
        () => _error =
            'Fill in your username, access key and secret first — that\'s '
            'what listing your buckets needs.',
      );
      return;
    }
    setState(() {
      _browsing = true;
      _error = null;
    });
    // Any valid name will do: listing asks about the namespace, not a bucket.
    final client = widget.clientFactory(_accountFor(_newBucket.text.trim()));
    List<String>? names;
    try {
      names = await client.listBuckets();
    } catch (_) {
      names = null;
    } finally {
      client.close();
    }
    if (!mounted) return;
    if (names == null) {
      setState(() {
        _browsing = false;
        _error =
            'Hugging Face didn\'t list your buckets — it doesn\'t always. '
            'Type the bucket\'s name instead; you can see it at '
            'huggingface.co/settings/storage.';
      });
      return;
    }
    final found = await _withLibraries(names);
    if (!mounted) return;
    setState(() => _browsing = false);
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        maxWidth: 560,
      ),
      builder: (context) => _BucketSheet(buckets: found),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _mode = BucketMode.existing;
      _existingBucket.text = picked;
      _error = null;
    });
  }

  /// Asks each bucket whether it holds a library, a few at a time so a big
  /// account doesn't fire off fifty requests at once.
  Future<List<_FoundBucket>> _withLibraries(List<String> names) async {
    const atOnce = 6;
    const most = 24;
    final out = <_FoundBucket>[];
    final looked = names.take(most).toList();
    for (var i = 0; i < looked.length; i += atOnce) {
      final slice = looked.skip(i).take(atOnce);
      out.addAll(
        await Future.wait([
          for (final name in slice)
            () async {
              final client = widget.clientFactory(_accountFor(name));
              try {
                return _FoundBucket(
                  name,
                  await client.headObject(BucketLayout.keys) != null,
                );
              } catch (_) {
                // A bucket these keys can't read still belongs in the list.
                return _FoundBucket(name, null);
              } finally {
                client.close();
              }
            }(),
        ]),
      );
    }
    for (final name in names.skip(most)) {
      out.add(_FoundBucket(name, null));
    }
    // Libraries first: that's what someone browsing is looking for.
    out.sort((a, b) {
      final byLibrary = ((b.hasLibrary ?? false) ? 1 : 0).compareTo(
        (a.hasLibrary ?? false) ? 1 : 0,
      );
      return byLibrary != 0 ? byLibrary : a.name.compareTo(b.name);
    });
    return out;
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

  static final _namePattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final locked = _busy || _browsing;
    return Form(
      key: _form,
      child: AuthPage(
        title: 'Let\'s get\nStarted',
        onBack: locked ? null : () => Navigator.of(context).maybePop(),
        children: [
          // Most people arrive without keys, so the guide sits first, where
          // it can't be missed, rather than as small print under the form.
          // It stands in for a subtitle, so the form still fits a phone.
          _HelpCard(onTap: locked ? null : _showHelp),
          const SizedBox(height: 18),
          TextFormField(
            controller: _username,
            enabled: !locked,
            autocorrect: false,
            textInputAction: TextInputAction.next,
            decoration: authField(
              hint: 'Hugging Face username',
              icon: Icons.person_outline,
            ),
            validator: (v) => _namePattern.hasMatch(v?.trim() ?? '')
                ? null
                : 'Enter your username, e.g. reuben',
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _accessKey,
            enabled: !locked,
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
            enabled: !locked,
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
          const SizedBox(height: 22),
          Text(
            'Where the photos go',
            style: theme.textTheme.titleSmall?.copyWith(color: inkText),
          ),
          const SizedBox(height: 10),
          _ModeSwitch(
            mode: _mode,
            enabled: !locked,
            onChanged: (m) => setState(() {
              _mode = m;
              _error = null;
            }),
          ),
          const SizedBox(height: 12),
          if (_mode == BucketMode.create)
            TextFormField(
              key: const ValueKey('newBucket'),
              controller: _newBucket,
              enabled: !locked,
              autocorrect: false,
              decoration: authField(
                hint: 'Bucket name',
                icon: Icons.add_circle_outline,
                helper: 'A new private bucket, made in your account',
                suffix: IconButton(
                  tooltip: 'Suggest another name',
                  iconSize: 19,
                  color: inkMuted,
                  icon: const Icon(Icons.casino_outlined),
                  onPressed: locked
                      ? null
                      : () => setState(
                          () => _newBucket.text = generateBucketName(),
                        ),
                ),
              ),
              validator: (v) => _namePattern.hasMatch(v?.trim() ?? '')
                  ? null
                  : 'Letters, numbers, dots, dashes',
            )
          else ...[
            TextFormField(
              key: const ValueKey('existingBucket'),
              controller: _existingBucket,
              enabled: !locked,
              autocorrect: false,
              decoration: authField(
                hint: 'Bucket name',
                icon: Icons.inventory_2_outlined,
                helper: 'The bucket your library is already in',
              ),
              validator: (v) => _namePattern.hasMatch(v?.trim() ?? '')
                  ? null
                  : 'Enter the name of your bucket, or tap Browse',
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: locked ? null : _browse,
                icon: _browsing
                    ? const SizedBox(
                        width: 15,
                        height: 15,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.search, size: 18),
                label: Text(_browsing ? 'Looking…' : 'Browse my buckets'),
              ),
            ),
          ],
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
          AuthButton(
            label: 'Connect',
            busy: _busy,
            onPressed: _browsing ? null : _connect,
          ),
          const SizedBox(height: 18),
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

/// Two words, one lit: make a bucket, or point at one that exists.
class _ModeSwitch extends StatelessWidget {
  final BucketMode mode;
  final bool enabled;
  final ValueChanged<BucketMode> onChanged;

  const _ModeSwitch({
    required this.mode,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget half(BucketMode value, IconData icon, String label) {
      final on = value == mode;
      return Expanded(
        child: Semantics(
          button: true,
          selected: on,
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: enabled ? () => onChanged(value) : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(vertical: 11),
              decoration: BoxDecoration(
                color: on ? accent : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 17, color: on ? ink : inkMuted),
                  const SizedBox(width: 8),
                  // Large text settings make these words wider than their
                  // half; they shrink rather than spill.
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: on ? ink : inkMuted,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: inkSurface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          half(BucketMode.create, Icons.add_circle_outline, 'New bucket'),
          half(BucketMode.existing, Icons.inventory_2_outlined, 'My bucket'),
        ],
      ),
    );
  }
}

/// The buckets in the account, with the ones Happy Drive has used marked.
class _BucketSheet extends StatelessWidget {
  final List<_FoundBucket> buckets;
  const _BucketSheet({required this.buckets});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        shrinkWrap: true,
        children: [
          Text('Your buckets', style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            buckets.isEmpty
                ? 'This account has no buckets yet. Go back and make a new one.'
                : 'Pick the one your library is in.',
            style: theme.textTheme.bodyMedium?.copyWith(color: inkMuted),
          ),
          const SizedBox(height: 12),
          for (final b in buckets)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                b.hasLibrary == true
                    ? Icons.photo_library_outlined
                    : Icons.inventory_2_outlined,
                color: b.hasLibrary == true ? accent : inkMuted,
              ),
              title: Text(b.name),
              subtitle: Text(switch (b.hasLibrary) {
                true => 'Has a Happy Drive library',
                false => 'No library in here yet',
                null => 'Couldn\'t look inside this one',
              }),
              onTap: () => Navigator.pop(context, b.name),
            ),
        ],
      ),
    );
  }
}

/// The way into the key guide: a lit card at the top of the form.
class _HelpCard extends StatelessWidget {
  final VoidCallback? onTap;

  const _HelpCard({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: accent.withValues(alpha: 0.12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: accent.withValues(alpha: 0.45)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
          child: Row(
            children: [
              const Icon(Icons.vpn_key_outlined, color: accent, size: 24),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Where do I get these?',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: inkText,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'A one-minute guide, with pictures.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: inkMuted,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right_rounded, color: accent),
            ],
          ),
        ),
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
                      'Then choose the bucket. "New bucket" makes one for you '
                      'with a name of its own; "My bucket" opens a library '
                      'that is already there — tap Browse to see them. If you '
                      'would rather make the bucket yourself, use '
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

/// Asked before making a new bucket in an account that already has a
/// library. Pops the bucket to open, or '' to make a new one anyway.
class _ExistingLibraries extends StatelessWidget {
  final List<String> names;
  const _ExistingLibraries({required this.names});

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      names.length == 1
          ? 'You already have a library'
          : 'You already have ${names.length} libraries',
    ),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Your photos are still there. Open your library with the same '
          'passphrase to get them back on this phone.',
        ),
        const SizedBox(height: 12),
        for (final name in names)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.photo_library_outlined),
            title: Text(name),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.pop(context, name),
          ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context, ''),
        child: const Text('Start an empty one'),
      ),
    ],
  );
}
