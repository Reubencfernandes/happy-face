import 'package:flutter/material.dart';

import '../app/session.dart';
import '../data/local_db.dart';
import '../media/compress.dart';
import '../sync/background.dart';

class SettingsScreen extends StatefulWidget {
  final Session session;
  final VoidCallback onSignOut;
  const SettingsScreen({
    super.key,
    required this.session,
    required this.onSignOut,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Session get _session => widget.session;
  Settings get _settings => _session.settings;
  String? _hfToken;

  @override
  void initState() {
    super.initState();
    _session.credentials.readHfToken().then((t) {
      if (mounted) setState(() => _hfToken = t);
    });
  }

  void _update(void Function() change) {
    setState(change);
    _session.settingsChanged();
  }

  Future<void> _reschedule() => BackgroundBackup.configure(
    enabled: _settings.autoBackup,
    wifiOnly: _settings.wifiOnly,
  ).catchError((_) {});

  Future<bool> _confirm(String title, String body, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _toggleAi(bool on) async {
    if (on) {
      final ok = await _confirm(
        'Turn on AI descriptions?',
        'To describe a photo, a small copy of it (about 512 pixels) is sent unencrypted to an AI '
            'service through Hugging Face. This is the one exception to "only you can see your photos". '
            'Descriptions are then stored encrypted.\n\n'
            'It uses your Hugging Face credits. Free accounts get about \$0.10 a month, enough for a '
            'small number of photos.',
        'Turn on',
      );
      if (!ok) return;
      if ((_hfToken ?? '').isEmpty) {
        final token = await _askToken();
        if (token == null) return;
      }
    }
    _update(() => _settings.aiCaptions = on);
  }

  Future<void> _toggleWeather(bool on) async {
    if (on) {
      final ok = await _confirm(
        'Show the weather for your photos?',
        'Happy Drive looks up past weather from Open-Meteo using each photo\'s date and a rough '
            'location (rounded to about 10 km). Nothing else is sent.',
        'Turn on',
      );
      if (!ok) return;
    }
    _update(() => _settings.weather = on);
  }

  Future<String?> _askToken() async {
    final controller = TextEditingController(text: _hfToken);
    final token = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Hugging Face token'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Create a fine-grained token at huggingface.co/settings/tokens with "Make calls to '
              'Inference Providers" permission.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autocorrect: false,
              enableSuggestions: false,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Token',
                hintText: 'hf_…',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (token == null) return null;
    if (!token.startsWith('hf_')) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'That doesn\'t look like a Hugging Face token (hf_…)',
            ),
          ),
        );
      }
      return null;
    }
    await _session.credentials.saveHfToken(token);
    if (mounted) setState(() => _hfToken = token);
    return token;
  }

  Future<void> _editModel() async {
    final controller = TextEditingController(text: _settings.aiModel);
    final model = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('AI model'),
        content: TextField(
          controller: controller,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'Model id',
            helperText: 'Any vision model on Hugging Face Inference Providers',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, Settings.defaultAiModel),
            child: const Text('Reset'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (model != null) _update(() => _settings.aiModel = model);
  }

  Future<void> _signOut() async {
    final ok = await _confirm(
      'Sign out of this phone?',
      'Your photos stay safe in your storage. You\'ll need your keys and passphrase to sign back in.',
      'Sign out',
    );
    if (!ok || !mounted) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
    widget.onSignOut();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stats = _session.db.backupStats();
    Widget header(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 4),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          header('Account'),
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: Text(_session.account.namespace),
            subtitle: Text(
              'Bucket: ${_session.account.bucket} · private, encrypted',
            ),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: Text('${stats.inCloud} photos in storage'),
            subtitle: Text(
              '${stats.backedUp} of ${stats.onDevice} on this phone backed up',
            ),
          ),
          header('Backup'),
          ListTile(
            leading: const Icon(Icons.high_quality_outlined),
            title: const Text('Default upload quality'),
            subtitle: Text(
              '${_settings.compression.label}: ${_settings.compression.description}',
            ),
            onTap: () async {
              final picked = await showDialog<Compression>(
                context: context,
                builder: (context) => SimpleDialog(
                  title: const Text('Upload quality'),
                  children: [
                    for (final c in Compression.values)
                      SimpleDialogOption(
                        onPressed: () => Navigator.pop(context, c),
                        child: ListTile(
                          title: Text(c.label),
                          subtitle: Text(c.description),
                          trailing: c == _settings.compression
                              ? const Icon(Icons.check)
                              : null,
                        ),
                      ),
                  ],
                ),
              );
              if (picked != null) _update(() => _settings.compression = picked);
            },
          ),
          SwitchListTile(
            secondary: const Icon(Icons.cloud_sync_outlined),
            title: const Text('Back up new photos automatically'),
            subtitle: const Text(
              'Whenever you open the app. On Android it also runs in the background; '
              'iPhone decides when background work is allowed, so opening the app is the reliable way.',
            ),
            value: _settings.autoBackup,
            onChanged: (v) {
              _update(() => _settings.autoBackup = v);
              _reschedule();
            },
          ),
          SwitchListTile(
            secondary: const Icon(Icons.wifi),
            title: const Text('Background backup on Wi-Fi only'),
            value: _settings.wifiOnly,
            onChanged: _settings.autoBackup
                ? (v) {
                    _update(() => _settings.wifiOnly = v);
                    _reschedule();
                  }
                : null,
          ),
          header('Extras'),
          SwitchListTile(
            secondary: const Icon(Icons.wb_cloudy_outlined),
            title: const Text('Weather'),
            subtitle: const Text('Show the weather when each photo was taken'),
            value: _settings.weather,
            onChanged: _toggleWeather,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.auto_awesome_outlined),
            title: const Text('AI descriptions'),
            subtitle: const Text(
              'Describe photos so you can search what\'s in them',
            ),
            value: _settings.aiCaptions,
            onChanged: _toggleAi,
          ),
          if (_settings.aiCaptions) ...[
            ListTile(
              contentPadding: const EdgeInsets.only(left: 72, right: 16),
              title: const Text('Hugging Face token'),
              subtitle: Text(
                (_hfToken ?? '').isEmpty
                    ? 'Not set'
                    : 'hf_••••${_hfToken!.substring(_hfToken!.length - 4)}',
              ),
              onTap: _askToken,
            ),
            ListTile(
              contentPadding: const EdgeInsets.only(left: 72, right: 16),
              title: const Text('Model'),
              subtitle: Text(_settings.aiModel),
              onTap: _editModel,
            ),
            ListTile(
              contentPadding: const EdgeInsets.only(left: 72, right: 16),
              title: const Text('Daily limit'),
              subtitle: Text('Up to ${_settings.aiDailyLimit} photos a day'),
              trailing: SizedBox(
                width: 160,
                child: Slider(
                  value: _settings.aiDailyLimit.toDouble().clamp(10, 500),
                  min: 10,
                  max: 500,
                  divisions: 49,
                  label: '${_settings.aiDailyLimit}',
                  onChanged: (v) =>
                      _update(() => _settings.aiDailyLimit = v.round()),
                ),
              ),
            ),
            SwitchListTile(
              contentPadding: const EdgeInsets.only(left: 72, right: 16),
              title: const Text('Describe older photos too'),
              subtitle: Text(
                '${_session.db.jobCount(JobKind.caption)} photos waiting',
              ),
              value: _settings.aiWholeLibrary,
              onChanged: (v) => _update(() => _settings.aiWholeLibrary = v),
            ),
          ],
          header('This phone'),
          ListTile(
            leading: const Icon(Icons.cleaning_services_outlined),
            title: const Text('Clear thumbnail cache'),
            subtitle: const Text(
              'Frees space on this phone. Photos re-download as you scroll.',
            ),
            onTap: () async {
              await _session.photos.clearCache();
              if (context.mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('Cache cleared')));
              }
            },
          ),
          ListTile(
            leading: Icon(Icons.logout, color: theme.colorScheme.error),
            title: Text(
              'Sign out',
              style: TextStyle(color: theme.colorScheme.error),
            ),
            onTap: _signOut,
          ),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              'Happy Drive · photos are encrypted on this phone\n'
              'Place names from GeoNames (CC BY 4.0) · '
              'Weather data by Open-Meteo.com (CC BY 4.0)',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}
