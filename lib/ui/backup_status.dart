import 'package:flutter/material.dart';

import '../app/session.dart';
import '../data/local_db.dart';
import '../media/image_type.dart';
import '../sync/uploader.dart';
import 'format.dart';
import 'theme.dart';

/// A live line under the gallery title while a backup runs: how far along it
/// is, what is going up at this second, and a way into the detail.
///
/// A backup used to be a 4px bar that moved every fifth photo. One large
/// video could take minutes without a single pixel changing, which looks
/// exactly like a frozen app.
class BackupStatusBar extends StatelessWidget {
  final Session session;
  const BackupStatusBar({super.key, required this.session});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final upload = session.upload;
    if (upload == null || upload.done) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Material(
        color: inkSurface,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => showBackupSheet(context, session),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 11, 8, 11),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        headline(upload),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      'Details',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: accent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Icon(
                      Icons.chevron_right_rounded,
                      size: 18,
                      color: accent,
                    ),
                  ],
                ),
                if (detail(upload) case final detail?
                    when detail.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Text(
                      detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: inkMuted,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: _Bar(
                    // Getting photos ready has no measure, so it says so
                    // rather than drawing a bar stuck at zero.
                    value: upload.stage == BackupStage.preparing
                        ? null
                        : upload.fraction,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The one line that has to carry the whole state.
  static String headline(UploadProgress upload) => switch (upload.stage) {
    BackupStage.preparing => 'Getting your photos ready…',
    BackupStage.stopping => switch (upload.working.length) {
      0 => 'Stopping…',
      1 => 'Stopping — finishing 1 file',
      final n => 'Stopping — finishing $n files',
    },
    _ =>
      'Backing up ${upload.settled + 1} of ${upload.total}'
          ' · ${((upload.fraction ?? 0) * 100).round()}%',
  };

  /// The quieter second line: pace, and a name only when there is one file
  /// to name. Naming one of four workers means naming whichever happens to
  /// be slowest, which is what made a busy backup look stuck.
  static String? detail(UploadProgress upload) {
    if (upload.stage == BackupStage.preparing) return null;
    final rate = upload.bytesPerSecond;
    final left = upload.timeLeft;
    final files = upload.working.length;
    return [
      if (upload.current case final name?)
        name
      else if (files > 1)
        '$files files at once',
      if (rate != null) transferRate(rate),
      if (left != null && upload.stage != BackupStage.stopping) timeLeft(left),
    ].join(' · ');
  }
}

/// The whole picture of a running backup, kept up to date while it's open.
Future<void> showBackupSheet(BuildContext context, Session session) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        maxWidth: 560,
      ),
      builder: (context) => ListenableBuilder(
        listenable: session,
        builder: (context, _) => _BackupSheet(session: session),
      ),
    );

class _BackupSheet extends StatelessWidget {
  final Session session;
  const _BackupSheet({required this.session});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final upload = session.upload;
    final running = upload != null && !upload.done;
    final recent = session.recentResults;
    final failed = [
      for (final r in recent)
        if (r.outcome == UploadOutcome.failed) r,
    ];

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        shrinkWrap: true,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  upload == null
                      ? 'Backup'
                      : !running
                      ? (upload.stopped ? 'Backup stopped' : 'Backup finished')
                      : switch (upload.stage) {
                          BackupStage.preparing => 'Getting ready',
                          BackupStage.stopping => 'Stopping',
                          _ => 'Backing up',
                        },
                  style: theme.textTheme.titleLarge,
                ),
              ),
              if (running)
                TextButton.icon(
                  onPressed: session.stopping ? null : session.cancelUpload,
                  icon: session.stopping
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.stop_rounded, size: 18),
                  label: Text(session.stopping ? 'Stopping' : 'Stop'),
                ),
            ],
          ),
          if (upload == null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Nothing is backing up right now.',
                style: theme.textTheme.bodyMedium?.copyWith(color: inkMuted),
              ),
            )
          else ...[
            const SizedBox(height: 14),
            _Bar(
              value: upload.stage == BackupStage.preparing
                  ? null
                  : upload.fraction,
              height: 8,
            ),
            const SizedBox(height: 10),
            Text(
              [
                '${upload.settled} of ${upload.total} done',
                if (upload.bytesDone > 0) fileSize(upload.bytesDone),
                if (upload.bytesPerSecond case final r?) transferRate(r),
                if (running)
                  if (upload.timeLeft case final t?) timeLeft(t),
              ].join(' · '),
              style: theme.textTheme.bodySmall?.copyWith(color: inkMuted),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                _Tally(
                  label: 'Backed up',
                  value: upload.uploaded,
                  icon: Icons.cloud_done_outlined,
                ),
                _Tally(
                  label: 'Already safe',
                  value: upload.skipped,
                  icon: Icons.done_all_rounded,
                ),
                _Tally(
                  label: 'Failed',
                  value: upload.failed,
                  icon: Icons.error_outline,
                  tint: upload.failed > 0 ? theme.colorScheme.error : null,
                ),
                _Tally(
                  label: 'Left',
                  value: upload.remaining,
                  icon: Icons.schedule_rounded,
                ),
              ],
            ),
            if (upload.active.isNotEmpty) ...[
              const SizedBox(height: 22),
              _SectionTitle('Going up now'),
              for (final a in upload.active) _ActiveRow(active: a),
            ],
          ],
          if (failed.isNotEmpty) ...[
            const SizedBox(height: 22),
            _SectionTitle('Didn\'t work'),
            for (final r in failed.take(12))
              _ResultRow(result: r, showReason: true),
          ],
          if (recent.isNotEmpty) ...[
            const SizedBox(height: 22),
            _SectionTitle('Just finished'),
            for (final r in recent.take(20)) _ResultRow(result: r),
          ],
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(color: inkMuted),
    ),
  );
}

/// One of the four counts across the top of the sheet.
class _Tally extends StatelessWidget {
  final String label;
  final int value;
  final IconData icon;
  final Color? tint;

  const _Tally({
    required this.label,
    required this.value,
    required this.icon,
    this.tint,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = tint ?? inkText;
    return Expanded(
      child: Column(
        children: [
          Icon(icon, size: 18, color: tint ?? inkMuted),
          const SizedBox(height: 6),
          Text(
            '$value',
            style: theme.textTheme.titleMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            label,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: inkMuted,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

/// A file being worked on, with its own bar. Four of these are on screen at
/// once, one per uploader worker.
class _ActiveRow extends StatelessWidget {
  final ActiveUpload active;
  const _ActiveRow({required this.active});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(_icon(active.name), size: 18, color: inkMuted),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  active.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 4),
                _Bar(value: active.fraction),
                const SizedBox(height: 4),
                Text(
                  active.phase == UploadPhase.uploading && active.bytesTotal > 0
                      ? '${active.label} · '
                            '${bytesOf(active.bytesSent, active.bytesTotal)}'
                      : active.label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: inkMuted,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A file that has finished, with what became of it.
class _ResultRow extends StatelessWidget {
  final UploadResult result;
  final bool showReason;
  const _ResultRow({required this.result, this.showReason = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, tint, note) = switch (result.outcome) {
      UploadOutcome.uploaded => (
        Icons.cloud_done_outlined,
        theme.colorScheme.primary,
        'Backed up',
      ),
      UploadOutcome.alreadyBackedUp => (
        Icons.done_rounded,
        inkMuted,
        'Already backed up',
      ),
      UploadOutcome.duplicate => (
        Icons.copy_all_outlined,
        inkMuted,
        'Already in your storage',
      ),
      UploadOutcome.failed => (
        Icons.error_outline,
        theme.colorScheme.error,
        result.error ?? 'Failed',
      ),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 17, color: tint),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  result.source.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
                Text(
                  note,
                  maxLines: showReason ? 3 : 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: result.outcome == UploadOutcome.failed
                        ? theme.colorScheme.error
                        : inkMuted,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The app's progress bar: rounded, thin, and happy to be indeterminate.
class _Bar extends StatelessWidget {
  final double? value;
  final double height;
  const _Bar({required this.value, this.height = 4});

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(height),
    child: LinearProgressIndicator(
      value: value,
      minHeight: height,
      backgroundColor: Theme.of(
        context,
      ).colorScheme.outlineVariant.withValues(alpha: 0.6),
    ),
  );
}

IconData _icon(String name) => switch (mediaKindOf(mimeForName(name))) {
  MediaKind.video => Icons.movie_outlined,
  MediaKind.file => Icons.description_outlined,
  MediaKind.image => Icons.image_outlined,
};
