import 'package:flutter/material.dart';

import '../app/session.dart';
import '../data/local_db.dart';
import 'theme.dart';

/// Where a delete should reach.
enum DeleteFrom {
  /// The backup in the bucket; the phone's copy stays.
  drive,

  /// The phone's copy; the backup stays.
  phone,

  /// Both.
  both,
}

/// Asks where [items] should be deleted from, offering only what applies:
/// a photo that was never backed up can't be deleted from the drive.
Future<DeleteFrom?> askWhereToDelete(
  BuildContext context,
  Iterable<TimelineItem> items,
) {
  final list = items.toList();
  final inDrive = list.where((i) => i.photoId != null).length;
  final onPhone = list.where((i) => i.assetId != null).length;
  final onlyInDrive = list
      .where((i) => i.state == BackupState.cloudOnly)
      .length;
  final onlyOnPhone = list
      .where((i) => i.state == BackupState.localOnly)
      .length;
  return showModalBottomSheet<DeleteFrom>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _DeleteSheet(
      count: list.length,
      inDrive: inDrive,
      onPhone: onPhone,
      onlyInDrive: onlyInDrive,
      onlyOnPhone: onlyOnPhone,
    ),
  );
}

/// What a delete actually removed. The phone asks before deleting from its
/// library, so this can be less than was asked for.
class DeleteOutcome {
  /// Backups removed from the bucket, by photo id.
  final Set<String> fromDrive;

  /// Copies removed from the phone, by asset id.
  final Set<String> fromPhone;

  const DeleteOutcome(this.fromDrive, this.fromPhone);

  bool get nothing => fromDrive.isEmpty && fromPhone.isEmpty;

  String get message {
    String n(int count) => count == 1 ? '1 item' : '$count items';
    return switch ((fromDrive.length, fromPhone.length)) {
      (0, 0) => 'Nothing was deleted',
      (final d, 0) => 'Deleted ${n(d)} from Happy Drive',
      (0, final p) => 'Deleted ${n(p)} from this phone',
      (final d, final p) when d == p => 'Deleted ${n(d)} everywhere',
      (final d, final p) =>
        'Deleted ${n(d)} from Happy Drive and ${n(p)} from this phone',
    };
  }

  /// What [item] is now: null when it's gone from both places.
  TimelineItem? apply(TimelineItem item) {
    final photoId = fromDrive.contains(item.photoId) ? null : item.photoId;
    final assetId = fromPhone.contains(item.assetId) ? null : item.assetId;
    if (photoId == null && assetId == null) return null;
    return TimelineItem(
      photoId: photoId,
      assetId: assetId,
      takenAt: item.takenAt,
      tzOffsetMinutes: item.tzOffsetMinutes,
      mime: item.mime,
      state: photoId == null
          ? BackupState.localOnly
          : assetId == null
          ? BackupState.cloudOnly
          : item.state,
    );
  }
}

/// Deletes [items] from where [from] says.
///
/// For [DeleteFrom.both] the phone goes first: if the person declines the
/// phone's own confirmation for some of them, their backups are kept too,
/// rather than leaving a photo deleted from one place they meant to keep.
Future<DeleteOutcome> deleteItems(
  Session session,
  Iterable<TimelineItem> items,
  DeleteFrom from,
) async {
  final list = items.toList();
  var fromPhone = <String>{};
  if (from != DeleteFrom.drive) {
    fromPhone = await session.deleteFromPhone({
      for (final i in list)
        if (i.assetId != null) i.assetId!,
    });
  }
  final fromDrive = <String>{
    if (from != DeleteFrom.phone)
      for (final i in list)
        if (i.photoId != null &&
            (from == DeleteFrom.drive ||
                i.assetId == null ||
                fromPhone.contains(i.assetId)))
          i.photoId!,
  };
  await session.deletePhotos(fromDrive);
  return DeleteOutcome(fromDrive, fromPhone);
}

class _DeleteSheet extends StatelessWidget {
  final int count, inDrive, onPhone, onlyInDrive, onlyOnPhone;

  const _DeleteSheet({
    required this.count,
    required this.inDrive,
    required this.onPhone,
    required this.onlyInDrive,
    required this.onlyOnPhone,
  });

  String _items(int n) => n == 1 ? '1 item' : '$n items';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final error = theme.colorScheme.error;

    String only(int n, String where) => switch (n) {
      0 => '',
      _ when n == count && count == 1 =>
        'It\'s only $where, so it will be gone for good.',
      _ when n == count =>
        'They\'re only $where, so they\'ll be gone for good.',
      _ => '$n of these are only $where and will be gone for good.',
    };
    String say(List<String> parts) =>
        parts.where((p) => p.isNotEmpty).join(' ');
    final one = count == 1;

    Widget option({
      required DeleteFrom value,
      required IconData icon,
      required String title,
      required String subtitle,
      required bool enabled,
    }) => ListTile(
      enabled: enabled,
      leading: Icon(icon, color: enabled ? error : null),
      title: Text(title),
      subtitle: Text(
        subtitle,
        style: theme.textTheme.bodySmall?.copyWith(color: inkMuted),
      ),
      onTap: () => Navigator.pop(context, value),
    );

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                count == 1 ? 'Delete this?' : 'Delete ${_items(count)}?',
                style: theme.textTheme.titleLarge,
              ),
            ),
            option(
              value: DeleteFrom.drive,
              icon: Icons.cloud_off_outlined,
              title: 'Delete from Happy Drive',
              subtitle: inDrive == 0
                  ? 'Nothing here is backed up yet.'
                  : say([
                      if (inDrive > onlyInDrive)
                        one
                            ? 'The copy on this phone stays.'
                            : 'Copies on this phone stay.',
                      only(onlyInDrive, 'in Happy Drive'),
                    ]),
              enabled: inDrive > 0,
            ),
            option(
              value: DeleteFrom.phone,
              icon: Icons.phone_iphone_rounded,
              title: 'Delete from this phone',
              subtitle: onPhone == 0
                  ? 'Nothing here is on this phone.'
                  : say([
                      if (onPhone > onlyOnPhone)
                        one
                            ? 'The backup in Happy Drive stays, so it frees '
                                  'space here.'
                            : 'Backups in Happy Drive stay, so it frees '
                                  'space here.',
                      only(onlyOnPhone, 'on this phone'),
                    ]),
              enabled: onPhone > 0,
            ),
            option(
              value: DeleteFrom.both,
              icon: Icons.delete_forever_outlined,
              title: 'Delete everywhere',
              subtitle:
                  'From Happy Drive and this phone. This can\'t be undone.',
              enabled: inDrive > 0 && onPhone > 0,
            ),
            ListTile(
              leading: const Icon(Icons.close_rounded),
              title: const Text('Cancel'),
              onTap: () => Navigator.pop(context),
            ),
          ],
        ),
      ),
    );
  }
}
