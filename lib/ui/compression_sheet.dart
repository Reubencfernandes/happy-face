import 'package:flutter/material.dart';

import '../app/session.dart';
import '../media/compress.dart';

/// Why the sheet is open: to pick the quality for photos going up now, or to
/// change the default used when Happy Drive doesn't ask.
enum CompressionPurpose { backup, setDefault }

/// What the sheet came back with.
class CompressionChoice {
  final Compression level;

  /// The user asked for this to become the default from now on.
  final bool remember;
  const CompressionChoice(this.level, {this.remember = false});
}

/// The quality for a backup the user just started.
///
/// Returns the saved default when they've turned asking off, otherwise what
/// they pick — or null if they back out, which cancels the backup.
Future<Compression?> chooseCompression(
  BuildContext context,
  Session session, {
  int count = 0,
}) async {
  final settings = session.settings;
  if (!settings.askQuality) return settings.compression;
  final choice = await pickCompression(
    context,
    initial: settings.compression,
    count: count,
  );
  if (choice == null) return null;
  if (choice.remember) {
    settings.compression = choice.level;
    session.settingsChanged();
  }
  return choice.level;
}

Future<CompressionChoice?> pickCompression(
  BuildContext context, {
  required Compression initial,
  CompressionPurpose purpose = CompressionPurpose.backup,
  int count = 0,
}) => showModalBottomSheet<CompressionChoice>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (context) =>
      _CompressionSheet(initial: initial, purpose: purpose, count: count),
);

class _CompressionSheet extends StatefulWidget {
  final Compression initial;
  final CompressionPurpose purpose;
  final int count;
  const _CompressionSheet({
    required this.initial,
    required this.purpose,
    required this.count,
  });

  @override
  State<_CompressionSheet> createState() => _CompressionSheetState();
}

class _CompressionSheetState extends State<_CompressionSheet> {
  late var _value = widget.initial;
  var _remember = false;

  static const _icons = {
    Compression.original: Icons.raw_on,
    Compression.high: Icons.high_quality_outlined,
    Compression.balanced: Icons.compress,
  };

  bool get _isDefault => widget.purpose == CompressionPurpose.setDefault;

  String get _title => switch ((_isDefault, widget.count)) {
    (true, _) => 'Default upload quality',
    (_, 0) => 'Upload quality',
    (_, 1) => 'Back up this photo',
    (_, final n) => 'Back up $n photos',
  };

  String get _subtitle => _isDefault
      ? 'Used whenever Happy Drive backs up without asking — including '
            'automatic backups.'
      : 'Choose how these are stored. Photos already in your storage are '
            'skipped either way.';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                child: Text(_title, style: theme.textTheme.titleLarge),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: Text(
                  _subtitle,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              RadioGroup<Compression>(
                groupValue: _value,
                onChanged: (v) => setState(() => _value = v ?? _value),
                child: Column(
                  children: [
                    for (final c in Compression.values)
                      RadioListTile<Compression>(
                        value: c,
                        secondary: Icon(_icons[c]),
                        title: Row(
                          children: [
                            Text(c.label),
                            if (!_isDefault && c == widget.initial) ...[
                              const SizedBox(width: 8),
                              Text(
                                'default',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                            ],
                          ],
                        ),
                        subtitle: Text(c.description),
                      ),
                  ],
                ),
              ),
              if (!_isDefault)
                CheckboxListTile(
                  value: _remember,
                  onChanged: (v) => setState(() => _remember = v ?? false),
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('Use this for future backups too'),
                  subtitle: const Text('Changes the default in Settings'),
                ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => Navigator.pop(
                  context,
                  CompressionChoice(_value, remember: _remember),
                ),
                child: Text(_isDefault ? 'Save' : 'Start backup'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
