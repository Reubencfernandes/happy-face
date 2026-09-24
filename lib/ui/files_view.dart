import 'package:flutter/material.dart';

import '../app/session.dart';
import '../data/local_db.dart';
import 'format.dart';
import 'photo_viewer.dart';
import 'theme.dart';

/// The Files tab: PDFs and sound, which are documents rather than
/// pictures, so they get a list with names and sizes instead of a grid.
class FilesView extends StatefulWidget {
  final Session session;
  final FileShelf shelf;
  final ValueChanged<FileShelf> onShelf;

  /// Picks files of the current kind and backs them up.
  final VoidCallback onAdd;

  const FilesView({
    super.key,
    required this.session,
    required this.shelf,
    required this.onShelf,
    required this.onAdd,
  });

  @override
  State<FilesView> createState() => _FilesViewState();
}

class _FilesViewState extends State<FilesView> {
  var _files = <FileShelf, List<ShelvedFile>>{};
  int _revision = -1;

  @override
  void initState() {
    super.initState();
    widget.session.coarse.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    widget.session.coarse.removeListener(_reload);
    super.dispose();
  }

  void _reload() {
    if (widget.session.revision == _revision) return;
    setState(() {
      _revision = widget.session.revision;
      _files = {
        for (final shelf in FileShelf.values)
          shelf: widget.session.db.files(shelf),
      };
    });
  }

  void _open(List<ShelvedFile> files, int index) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => PhotoViewer(
        session: widget.session,
        items: [for (final f in files) f.item],
        initialIndex: index,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final shelf = widget.shelf;
    final files = _files[shelf] ?? const [];
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: SizedBox(
            width: double.infinity,
            child: SegmentedButton<FileShelf>(
              showSelectedIcon: false,
              segments: [
                for (final s in FileShelf.values)
                  ButtonSegment(
                    value: s,
                    icon: Icon(_icon(s), size: 18),
                    label: Text(
                      '${_label(s)}  ${_files[s]?.length ?? 0}',
                      maxLines: 1,
                    ),
                  ),
              ],
              selected: {shelf},
              onSelectionChanged: (s) => widget.onShelf(s.first),
            ),
          ),
        ),
        Expanded(
          child: files.isEmpty
              ? _Empty(shelf: shelf, onAdd: widget.onAdd)
              : ListView.builder(
                  // Clear of the floating bar at the bottom.
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 112),
                  itemCount: files.length + 1,
                  itemBuilder: (context, i) => i == 0
                      ? _Summary(files: files, shelf: shelf)
                      : _FileRow(
                          file: files[i - 1],
                          onTap: () => _open(files, i - 1),
                        ),
                ),
        ),
      ],
    );
  }
}

IconData _icon(FileShelf shelf) => switch (shelf) {
  FileShelf.pdfs => Icons.picture_as_pdf_outlined,
  FileShelf.audio => Icons.graphic_eq_rounded,
};

String _label(FileShelf shelf) => switch (shelf) {
  FileShelf.pdfs => 'PDFs',
  FileShelf.audio => 'Audio',
};

/// How many, and how much room they take up.
class _Summary extends StatelessWidget {
  final List<ShelvedFile> files;
  final FileShelf shelf;
  const _Summary({required this.files, required this.shelf});

  @override
  Widget build(BuildContext context) {
    final total = files.fold(0, (sum, f) => sum + f.record.size);
    final noun = switch ((shelf, files.length)) {
      (FileShelf.pdfs, 1) => 'PDF',
      (FileShelf.pdfs, _) => 'PDFs',
      (FileShelf.audio, 1) => 'audio file',
      (FileShelf.audio, _) => 'audio files',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Text(
        '${files.length} $noun · ${fileSize(total)} in storage',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: inkMuted),
      ),
    );
  }
}

class _FileRow extends StatelessWidget {
  final ShelvedFile file;
  final VoidCallback onTap;
  const _FileRow({required this.file, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = file.record;
    final isPdf = r.mime == 'application/pdf';
    return ListTile(
      onTap: onTap,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      leading: Container(
        width: 44,
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: (isPdf ? glowEmber : accent).withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(
          isPdf ? Icons.picture_as_pdf_outlined : Icons.graphic_eq_rounded,
          color: isPdf ? glowEmber : accent,
        ),
      ),
      title: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          fileSize(r.size),
          dayLabel(r.uploadedAt.toLocal()),
          if (r.compression != 'original')
            '${r.compression[0].toUpperCase()}${r.compression.substring(1)}',
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(color: inkMuted),
      ),
      trailing: Icon(
        file.item.state == BackupState.backedUp
            ? Icons.cloud_done_outlined
            : Icons.cloud_outlined,
        size: 18,
        color: inkMuted,
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  final FileShelf shelf;
  final VoidCallback onAdd;
  const _Empty({required this.shelf, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pdfs = shelf == FileShelf.pdfs;
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 32, 32, 112),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_icon(shelf), size: 64, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text(
              pdfs ? 'No PDFs yet' : 'No audio yet',
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              pdfs
                  ? 'Documents, scans and tickets, encrypted like your '
                        'photos. Pictures inside can be compressed; the text '
                        'never is.'
                  : 'Voice notes, recordings and songs, encrypted like your '
                        'photos, and compressed to AAC if you like.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: inkMuted),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add_rounded),
              label: Text(pdfs ? 'Add PDFs' : 'Add audio'),
            ),
          ],
        ),
      ),
    );
  }
}
