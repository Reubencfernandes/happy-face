import 'dart:io';

import 'package:flutter/material.dart';

import '../app/credentials.dart';
import '../data/bucket_eraser.dart';
import '../data/storage_usage.dart';
import '../s3/s3_client.dart';
import 'format.dart';
import 'theme.dart';

typedef BucketEraser =
    Future<void> Function(
      BucketClient client, {
      void Function(int done, int total)? onProgress,
    });

Future<void> _eraseBucket(
  BucketClient client, {
  void Function(int done, int total)? onProgress,
}) => eraseBucket(client, onProgress: onProgress);

/// Every bucket in the account, with a way to delete the ones Happy Drive
/// isn't using. The bucket this phone backs up to can't be deleted here.
///
/// Pops `true` when something was deleted, so Settings measures again.
class BucketsScreen extends StatefulWidget {
  final StoredAccount account;
  final StorageUsage usage;
  final BucketClientFactory clientFactory;
  final BucketEraser erase;

  const BucketsScreen({
    super.key,
    required this.account,
    required this.usage,
    this.clientFactory = defaultBucketClient,
    this.erase = _eraseBucket,
  });

  @override
  State<BucketsScreen> createState() => _BucketsScreenState();
}

class _BucketsScreenState extends State<BucketsScreen> {
  late final _buckets = [...widget.usage.buckets];

  /// Buckets a failed delete left partly emptied: their sizes are stale.
  final _partly = <String>{};
  bool _changed = false;

  Future<void> _delete(BucketUsage bucket) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => _ConfirmDelete(bucket: bucket),
    );
    if (ok != true || !mounted) return;

    final progress = ValueNotifier<(int, int)>((0, bucket.objects));
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: _Deleting(name: bucket.name, progress: progress),
      ),
    );
    final client = widget.clientFactory(
      StoredAccount(
        namespace: widget.account.namespace,
        bucket: bucket.name,
        accessKeyId: widget.account.accessKeyId,
        secretAccessKey: widget.account.secretAccessKey,
      ),
    );
    String? failure;
    try {
      await widget.erase(
        client,
        onProgress: (done, total) => progress.value = (done, total),
      );
    } on S3Exception catch (e) {
      failure = e.isAuth
          ? 'These keys can\'t delete buckets. Use keys made from a Write '
                'token.'
          : 'Hugging Face wouldn\'t delete ${bucket.name} (${e.friendly}) '
                'You can delete it on huggingface.co.';
    } on SocketException {
      failure = 'No internet connection.';
    } catch (e) {
      failure = 'Could not delete ${bucket.name}: $e';
    } finally {
      client.close();
    }
    if (!mounted) return;
    Navigator.of(context).pop();
    final gone = progress.value.$1 > 0;
    progress.dispose();
    _changed = _changed || failure == null || gone;
    setState(() {
      if (failure == null) {
        _buckets.removeWhere((b) => b.name == bucket.name);
      } else if (gone) {
        _partly.add(bucket.name);
      }
    });
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            failure == null
                ? 'Deleted ${bucket.name}'
                : gone
                ? '$failure Some of its files are already gone.'
                : failure,
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: inkMuted);
    return PopScope<bool>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Buckets')),
        body: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Text(
                'Everything in your Hugging Face account under '
                '${widget.account.namespace}. Deleting a bucket removes '
                'every file in it for good.',
                style: muted,
              ),
            ),
            for (final bucket in _buckets)
              _BucketRow(
                bucket: bucket,
                partly: _partly.contains(bucket.name),
                onDelete: bucket.connected || bucket.error != null
                    ? null
                    : () => _delete(bucket),
              ),
            if (widget.usage.onlyConnected)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Text(
                  'Hugging Face doesn\'t list your other buckets to this app, '
                  'so there are none to delete here. You can delete them on '
                  'huggingface.co.',
                  style: muted,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _BucketRow extends StatelessWidget {
  final BucketUsage bucket;
  final bool partly;
  final VoidCallback? onDelete;

  const _BucketRow({
    required this.bucket,
    required this.partly,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final library = (bucket.bytes[UsageKind.catalogue] ?? 0) > 0;
    final details = [
      if (bucket.connected) 'This phone\'s library',
      if (!bucket.connected && library) 'Happy Drive library',
      if (bucket.error != null)
        bucket.error!
      else if (partly)
        'Partly deleted'
      else ...[
        '${bucket.objects}${bucket.partial ? '+' : ''} '
            '${bucket.objects == 1 ? 'file' : 'files'}',
        storageSize(bucket.total),
      ],
    ];
    return ListTile(
      leading: Icon(
        bucket.connected ? Icons.cloud_done_outlined : Icons.cloud_outlined,
        color: bucket.connected ? accent : inkMuted,
      ),
      title: Text(bucket.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        details.join(' · '),
        style: theme.textTheme.bodySmall?.copyWith(color: inkMuted),
      ),
      trailing: onDelete == null
          ? null
          : IconButton(
              tooltip: 'Delete ${bucket.name}',
              icon: Icon(
                Icons.delete_outline_rounded,
                color: theme.colorScheme.error,
              ),
              onPressed: onDelete,
            ),
    );
  }
}

/// Asks for the bucket's name to be typed, so a slip of the thumb can't
/// delete the wrong one.
class _ConfirmDelete extends StatefulWidget {
  final BucketUsage bucket;
  const _ConfirmDelete({required this.bucket});

  @override
  State<_ConfirmDelete> createState() => _ConfirmDeleteState();
}

class _ConfirmDeleteState extends State<_ConfirmDelete> {
  final _typed = TextEditingController();

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final b = widget.bucket;
    final library = (b.bytes[UsageKind.catalogue] ?? 0) > 0;
    final matches = _typed.text.trim() == b.name;
    return AlertDialog(
      title: Text('Delete ${b.name}?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            b.objects == 0
                ? 'This bucket is empty. It will be removed from your Hugging '
                      'Face account.'
                : 'This permanently deletes ${b.objects}'
                      '${b.partial ? '+' : ''} '
                      '${b.objects == 1 ? 'file' : 'files'} '
                      '(${storageSize(b.total)}). This can\'t be undone.',
          ),
          if (library) ...[
            const SizedBox(height: 8),
            Text(
              'It holds a Happy Drive library, so any photos backed up to it '
              'will be gone.',
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ],
          const SizedBox(height: 16),
          Text('Type ${b.name} to confirm.', style: theme.textTheme.bodySmall),
          const SizedBox(height: 6),
          TextField(
            controller: _typed,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(hintText: b.name),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: theme.colorScheme.error,
            foregroundColor: theme.colorScheme.onError,
          ),
          onPressed: matches ? () => Navigator.pop(context, true) : null,
          child: const Text('Delete'),
        ),
      ],
    );
  }
}

class _Deleting extends StatelessWidget {
  final String name;
  final ValueNotifier<(int, int)> progress;
  const _Deleting({required this.name, required this.progress});

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Deleting $name'),
    content: ValueListenableBuilder<(int, int)>(
      valueListenable: progress,
      builder: (context, value, _) {
        final (done, total) = value;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LinearProgressIndicator(value: total == 0 ? null : done / total),
            const SizedBox(height: 12),
            Text(
              total == 0
                  ? 'Removing the bucket…'
                  : done < total
                  ? 'Deleting $done of $total files…'
                  : 'Removing the bucket…',
            ),
          ],
        );
      },
    ),
  );
}
