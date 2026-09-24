import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../app/device.dart';
import '../app/password_manager.dart';
import '../app/session.dart';
import '../crypto/vault.dart';
import '../data/bucket_layout.dart';
import '../data/hf_profile.dart';
import '../data/storage_usage.dart';
import '../s3/s3_client.dart';
import '../sync/background.dart';
import 'buckets_screen.dart';
import 'compression_sheet.dart';
import 'format.dart';
import 'skeleton.dart';
import 'usage_bar.dart';

/// What the last visibility check found. Buckets can be flipped to public on
/// huggingface.co long after setup, so the tile reports what is true now
/// rather than repeating the promise made at connect time.
enum _Visibility { checking, private, public, unknown }

class SettingsScreen extends StatefulWidget {
  final Session session;
  final VoidCallback onSignOut;
  final PasswordManager passwords;
  const SettingsScreen({
    super.key,
    required this.session,
    required this.onSignOut,
    this.passwords = const ChannelPasswordManager(),
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Session get _session => widget.session;
  Settings get _settings => _session.settings;

  _Visibility _visibility = _Visibility.checking;
  HfProfile? _profile;

  /// The picture itself, kept with the profile so the face survives a
  /// restart and shows up offline.
  Uint8List? _avatar;
  StorageUsage? _usage;
  String? _usageError;
  bool _measuring = true;

  /// The phone's own storage, and Happy Drive's share of it.
  DeviceStorage? _device;
  AppStorage? _app;

  /// Where the last profile lookup is remembered between runs, so the face
  /// is there immediately and offline.
  static const _profileKey = 'hfProfile';
  static const _avatarKey = 'hfAvatar';
  static const _avatarUrlKey = 'hfAvatarFrom';

  @override
  void initState() {
    super.initState();
    _profile = _cachedProfile();
    _avatar = _cachedAvatar();
    _checkVisibility();
    _loadProfile();
    _measure();
    _measurePhone();
  }

  Future<void> _measurePhone() async {
    final device = await deviceStorage();
    AppStorage? app;
    try {
      app = await appStorage();
    } catch (_) {
      app = null;
    }
    if (mounted) {
      setState(() {
        _device = device;
        _app = app;
      });
    }
  }

  HfProfile? _cachedProfile() {
    final raw = _session.db.getSetting(_profileKey);
    if (raw == null) return null;
    try {
      final profile = HfProfile.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      // A different account signed in since: ignore the old face.
      return profile.username == _session.account.namespace ? profile : null;
    } catch (_) {
      return null;
    }
  }

  /// Looks the profile up again and says what came back, so "where is my
  /// picture?" has an answer inside the app.
  Uint8List? _cachedAvatar() {
    final raw = _session.db.getSetting(_avatarKey);
    if (raw == null) return null;
    try {
      return base64Decode(raw);
    } catch (_) {
      return null;
    }
  }

  /// Downloads the picture when it is new to this phone, and remembers it.
  Future<bool> _loadAvatar(String? url) async {
    if (url == null) return false;
    if (_avatar != null && _session.db.getSetting(_avatarUrlKey) == url) {
      return true;
    }
    final bytes = await fetchHfAvatar(url);
    if (bytes == null) return false;
    if (!mounted) return true;
    _session.db.setSetting(_avatarKey, base64Encode(bytes));
    _session.db.setSetting(_avatarUrlKey, url);
    setState(() => _avatar = bytes);
    return true;
  }

  Future<void> _loadProfile({bool tell = false}) async {
    final profile = await fetchHfProfile(_session.account.namespace);
    if (!mounted) return;
    var gotPicture = false;
    if (profile != null) {
      _session.db.setSetting(_profileKey, jsonEncode(profile.toJson()));
      setState(() => _profile = profile);
      gotPicture = await _loadAvatar(profile.avatarUrl);
    }
    if (!tell || !mounted) return;
    final message = switch (profile) {
      null =>
        'Couldn\'t read @${_session.account.namespace} on huggingface.co. '
            'Check the username and your connection.',
      _ when profile.avatarUrl == null =>
        'That Hugging Face account has no profile picture, so your initials '
            'stand in. Add one on huggingface.co/settings/profile.',
      _ when !gotPicture =>
        'Found @${profile.username}, but the picture itself wouldn\'t '
            'download. Your initials stand in for now.',
      _ => 'Profile updated.',
    };
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _checkVisibility() async {
    _Visibility result;
    try {
      result =
          await _session.bucket.isPubliclyExposed(probeKey: BucketLayout.keys)
          ? _Visibility.public
          : _Visibility.private;
    } catch (_) {
      // Offline, or Hugging Face is unreachable. Say so rather than claim
      // the bucket is private on the strength of a failed request.
      result = _Visibility.unknown;
    }
    if (mounted) setState(() => _visibility = result);
  }

  Future<void> _measure() async {
    setState(() {
      _measuring = true;
      _usageError = null;
    });
    try {
      final usage = await measureStorage(
        account: _session.account,
        connected: _session.bucket,
      );
      if (mounted) setState(() => _usage = usage);
    } on SocketException {
      _failed('No internet connection, so your storage can\'t be measured.');
    } on TimeoutException {
      _failed('Hugging Face took too long to answer. Try again in a moment.');
    } on S3Exception catch (e) {
      _failed(e.friendly);
    } catch (e) {
      _failed('Could not measure your storage: $e');
    } finally {
      if (mounted) setState(() => _measuring = false);
    }
  }

  void _failed(String reason) {
    if (mounted) setState(() => _usageError = reason);
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

  Future<void> _pickDefaultQuality() async {
    final picked = await pickCompression(
      context,
      initial: _settings.compression,
      purpose: CompressionPurpose.setDefault,
    );
    if (picked != null) _update(() => _settings.compression = picked.level);
  }

  Future<void> _manageBuckets() async {
    final usage = _usage;
    if (usage == null) return;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => BucketsScreen(account: _session.account, usage: usage),
      ),
    );
    if (changed == true && mounted) _measure();
  }

  /// Asks for the passphrase, checks it really opens this library so a typo
  /// is never what gets kept, and hands it to the password manager.
  Future<void> _savePassphrase() async {
    final passphrase = await showDialog<String>(
      context: context,
      builder: (_) => _PassphrasePrompt(
        check: (text) async {
          await Vault.unlock(
            await _session.bucket.getObject(BucketLayout.keys),
            text,
          );
        },
      ),
    );
    if (passphrase == null || !mounted) return;
    final result = await widget.passwords.save(_session.account, passphrase);
    if (!mounted) return;
    final message = switch (result) {
      SaveResult.saved => 'Passphrase saved to Google Password Manager',
      SaveResult.cancelled => null,
      SaveResult.unavailable =>
        'Couldn\'t reach a password manager on this phone.',
    };
    if (message == null) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
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
          _ProfileCard(
            profile: _profile,
            avatar: _avatar,
            namespace: _session.account.namespace,
            bucket: _session.account.bucket,
            visibility: _visibility,
            onTapAvatar: () => _loadProfile(tell: true),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Row(
              children: [
                _Stat(
                  value: '${stats.inCloud}',
                  label: 'In storage',
                  icon: Icons.cloud_done_outlined,
                ),
                const SizedBox(width: 10),
                _Stat(
                  value: '${stats.onDevice}',
                  label: 'On this phone',
                  icon: Icons.photo_library_outlined,
                ),
                const SizedBox(width: 10),
                _Stat(
                  value: '${stats.pending}',
                  label: 'Waiting',
                  icon: Icons.cloud_upload_outlined,
                  highlight: stats.pending > 0,
                ),
              ],
            ),
          ),
          header('Storage'),
          _StorageCard(
            usage: _usage,
            profile: _profile,
            measuring: _measuring,
            error: _usageError,
            onRefresh: _measuring ? null : _measure,
          ),
          ListTile(
            leading: const Icon(Icons.inventory_2_outlined),
            title: const Text('Manage buckets'),
            subtitle: Text(
              _usage == null
                  ? 'Available once your storage has been measured'
                  : 'Delete buckets you no longer need',
            ),
            enabled: _usage != null,
            onTap: _manageBuckets,
          ),
          header('Phone storage'),
          _PhoneStorageCard(device: _device, app: _app),
          header('Backup'),
          ListTile(
            leading: const Icon(Icons.high_quality_outlined),
            title: const Text('Default upload quality'),
            subtitle: Text(
              '${_settings.compression.label}: ${_settings.compression.description}',
            ),
            onTap: _pickDefaultQuality,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.tune),
            title: const Text('Ask before every backup'),
            subtitle: const Text(
              'Pick the quality photo by photo. Off means the default above '
              'is used without asking.',
            ),
            value: _settings.askQuality,
            onChanged: (v) => _update(() => _settings.askQuality = v),
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
          header('This phone'),
          ListTile(
            leading: const Icon(Icons.cleaning_services_outlined),
            title: const Text('Clear thumbnail cache'),
            subtitle: const Text(
              'Frees space on this phone. Photos re-download as you scroll.',
            ),
            onTap: () async {
              await _session.photos.clearCache();
              unawaited(_measurePhone());
              if (context.mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('Cache cleared')));
              }
            },
          ),
          if (widget.passwords.available)
            ListTile(
              leading: const Icon(Icons.key_rounded),
              title: const Text('Save passphrase'),
              subtitle: const Text('Keep it in Google Password Manager'),
              onTap: _savePassphrase,
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
              'Profile name and picture from huggingface.co · '
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

/// Who is signed in: the Hugging Face picture and name, and which bucket the
/// photos land in.
class _ProfileCard extends StatelessWidget {
  final HfProfile? profile;
  final Uint8List? avatar;
  final String namespace;
  final String bucket;
  final _Visibility visibility;
  final VoidCallback onTapAvatar;

  const _ProfileCard({
    required this.profile,
    required this.avatar,
    required this.namespace,
    required this.bucket,
    required this.visibility,
    required this.onTapAvatar,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final public = visibility == _Visibility.public;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            button: true,
            label: 'Refresh your Hugging Face profile',
            child: InkWell(
              onTap: onTapAvatar,
              customBorder: const CircleBorder(),
              child: _Avatar(
                profile: profile,
                avatar: avatar,
                namespace: namespace,
                size: 64,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        profile?.displayName ?? namespace,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (profile?.isPro ?? false) ...[
                      const SizedBox(width: 8),
                      _Tag(
                        text: 'PRO',
                        color: theme.colorScheme.primary,
                        filled: true,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '@$namespace',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _Tag(
                      text: bucket,
                      icon: Icons.inventory_2_outlined,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    _Tag(
                      icon: switch (visibility) {
                        _Visibility.public => Icons.public,
                        _Visibility.private => Icons.lock_outline,
                        _ => Icons.hourglass_empty,
                      },
                      text: switch (visibility) {
                        _Visibility.checking => 'checking…',
                        _Visibility.private => 'Private, encrypted',
                        _Visibility.public => 'Public bucket',
                        _Visibility.unknown => 'Encrypted',
                      },
                      color: public
                          ? theme.colorScheme.error
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
                if (public) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Anyone can download this bucket. Make it private on '
                    'huggingface.co.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final HfProfile? profile;
  final Uint8List? avatar;
  final String namespace;
  final double size;

  const _Avatar({
    required this.profile,
    required this.avatar,
    required this.namespace,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final initials =
        profile?.initials ??
        (namespace.isEmpty ? '?' : namespace[0].toUpperCase());
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      color: theme.colorScheme.primaryContainer,
      child: Text(
        initials,
        style: theme.textTheme.titleLarge?.copyWith(
          color: theme.colorScheme.onPrimaryContainer,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
    final avatar = this.avatar;
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: avatar == null
          ? fallback
          : Image.memory(
              avatar,
              width: size,
              height: size,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              // Bytes that won't decode are no picture at all.
              errorBuilder: (context, error, stack) => fallback,
            ),
    );
  }
}

class _Tag extends StatelessWidget {
  final String text;
  final IconData? icon;
  final Color color;
  final bool filled;

  const _Tag({
    required this.text,
    required this.color,
    this.icon,
    this.filled = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = filled ? theme.colorScheme.onPrimary : color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: filled ? color : color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: ink),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: theme.textTheme.labelSmall?.copyWith(
              color: ink,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String value;
  final String label;
  final IconData icon;
  final bool highlight;

  const _Stat({
    required this.value,
    required this.label,
    required this.icon,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = highlight
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.45,
          ),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: tint),
            const SizedBox(height: 8),
            Text(
              value,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
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

/// The storage bar: how much each bucket in the account holds, then what
/// fills the bucket Happy Drive uses.
class _StorageCard extends StatelessWidget {
  final StorageUsage? usage;

  /// Says which allowance this account gets, when it is known.
  final HfProfile? profile;
  final bool measuring;
  final String? error;
  final VoidCallback? onRefresh;

  const _StorageCard({
    required this.usage,
    required this.profile,
    required this.measuring,
    required this.error,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final usage = this.usage;
    final error = this.error;
    final colors = usageColors();
    final neutral = mutedUsageColor(theme.colorScheme);

    // Each bucket keeps its slot colour; anything past the last slot is
    // pooled rather than given an invented hue.
    final buckets = usage?.buckets ?? const <BucketUsage>[];
    final named = buckets.take(usageColorSlots).toList();
    final pooled = buckets.skip(usageColorSlots).toList();
    final segments = <UsageSegment>[
      for (final (i, bucket) in named.indexed)
        UsageSegment(
          label: bucket.name,
          bytes: bucket.total,
          color: colors[i],
          note: bucket.connected ? 'this app' : null,
        ),
      if (pooled.isNotEmpty)
        UsageSegment(
          label: '${pooled.length} more buckets',
          bytes: pooled.fold(0, (sum, b) => sum + b.total),
          color: neutral,
        ),
    ];
    // Hugging Face counts a bucket against the account's private storage,
    // so the bar is a gauge when we know what that allowance is.
    final allowance = profile?.privateAllowance;
    final free = allowance == null
        ? 0
        : (allowance - (usage?.total ?? 0)).clamp(0, allowance);
    final connected = usage?.connected;
    final kinds = [
      for (final (i, entry) in (connected?.breakdown ?? const []).indexed)
        UsageSegment(
          label: entry.key.label,
          bytes: entry.value,
          color: i < usageColorSlots ? colors[i] : neutral,
        ),
    ];

    // Nothing measured yet: show the shape of what's coming rather than a
    // spinner. Measuring is one request per bucket, so this is a real wait,
    // and the card doesn't jump when the numbers land.
    if (usage == null && error == null) {
      return Container(
        margin: const EdgeInsets.fromLTRB(16, 4, 16, 0),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.45,
          ),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Skeleton(width: 190, height: 30, radius: 10),
            const SizedBox(height: 10),
            const Skeleton(widthFactor: 0.62, height: 13, delay: 0.08),
            const SizedBox(height: 18),
            const Skeleton(height: 14, radius: 7, delay: 0.16),
            const SizedBox(height: 16),
            for (final (i, w) in const [0.5, 0.42, 0.34].indexed) ...[
              Row(
                children: [
                  Skeleton(
                    width: 10,
                    height: 10,
                    radius: 5,
                    delay: 0.2 + i * 0.06,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Skeleton(
                      widthFactor: w,
                      height: 12,
                      delay: 0.24 + i * 0.06,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            Text('Adding up what each bucket holds…', style: muted),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.45,
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(
                    text: usage == null
                        ? 'Storage used'
                        : storageSize(usage.total),
                    children: [
                      if (usage != null && profile?.allowanceLabel != null)
                        TextSpan(
                          text: ' of ${profile!.allowanceLabel}',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Measure again',
                onPressed: onRefresh,
                // A re-measure keeps the numbers already on screen, so this
                // is the only hint that one is running.
                icon: measuring
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
              ),
            ],
          ),
          if (usage != null)
            Text(
              [
                if (profile?.allowanceLabel != null) profile!.planLabel,
                'across ${buckets.length} '
                    '${buckets.length == 1 ? 'bucket' : 'buckets'}',
                '${buckets.fold(0, (sum, b) => sum + b.objects)} files',
              ].join(' · '),
              style: muted,
            ),
          const SizedBox(height: 14),
          if (error != null) ...[
            Text(
              error,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: onRefresh,
                child: const Text('Try again'),
              ),
            ),
          ] else ...[
            UsageBar(segments: segments, total: allowance),
            const SizedBox(height: 12),
            for (final (i, bucket) in named.indexed)
              UsageLegendRow(
                segment: segments[i],
                total: usage?.total ?? 0,
                trailing: bucket.error != null
                    ? 'no access'
                    : bucket.partial
                    ? 'over ${storageSize(bucket.total)}'
                    : allowance != null
                    ? storageSize(bucket.total)
                    : null,
              ),
            if (pooled.isNotEmpty)
              UsageLegendRow(
                segment: segments.last,
                total: usage?.total ?? 0,
                trailing: allowance == null
                    ? null
                    : storageSize(segments.last.bytes),
              ),
            if (allowance != null && usage != null) ...[
              UsageLegendRow(
                segment: UsageSegment(
                  label: 'Free',
                  bytes: free,
                  color: theme.colorScheme.surfaceContainerHighest,
                ),
                total: allowance,
                trailing: storageSize(free),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Your ${profile!.allowanceLabel} of private storage covers '
                  'everything private in your Hugging Face account, not just '
                  'Happy Drive.',
                  style: muted,
                ),
              ),
            ],
            for (final bucket in buckets)
              if (bucket.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '${bucket.name}: ${bucket.error}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
            if (usage?.onlyConnected ?? false)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Hugging Face doesn\'t list your other buckets to this app, '
                  'so only this one is counted.',
                  style: muted,
                ),
              ),
            if (kinds.isNotEmpty) ...[
              const Divider(height: 28),
              Text(
                'Inside ${connected!.name}',
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 10),
              UsageBar(segments: kinds, height: 10),
              const SizedBox(height: 8),
              for (final segment in kinds)
                UsageLegendRow(
                  segment: segment,
                  total: connected.total,
                  dense: true,
                ),
            ],
          ],
        ],
      ),
    );
  }
}

/// Asks for the library passphrase and won't close on one that doesn't
/// unlock the library.
class _PassphrasePrompt extends StatefulWidget {
  final Future<void> Function(String passphrase) check;
  const _PassphrasePrompt({required this.check});

  @override
  State<_PassphrasePrompt> createState() => _PassphrasePromptState();
}

class _PassphrasePromptState extends State<_PassphrasePrompt> {
  final _text = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _text.text;
    if (text.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    try {
      await widget.check(text);
    } on WrongPassphraseException {
      error = 'That passphrase doesn\'t unlock this library.';
    } on S3Exception catch (e) {
      error = e.friendly;
    } on SocketException {
      error = 'No internet connection.';
    } catch (e) {
      error = 'Something went wrong: $e';
    }
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context, text);
      return;
    }
    setState(() {
      _busy = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Save your passphrase'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Enter it once more. It\'s checked against your library before '
          'it\'s saved, so a typo never is.',
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _text,
          enabled: !_busy,
          obscureText: true,
          autofocus: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            hintText: 'Passphrase',
            errorText: _error,
          ),
          onSubmitted: (_) => _submit(),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _busy ? null : _submit,
        child: Text(_busy ? 'Checking…' : 'Save'),
      ),
    ],
  );
}

/// How full the phone is, and how much of that is Happy Drive.
class _PhoneStorageCard extends StatelessWidget {
  final DeviceStorage? device;
  final AppStorage? app;
  const _PhoneStorageCard({required this.device, required this.app});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final device = this.device;
    final app = this.app;
    final colors = usageColors();
    final mine = app?.total ?? 0;
    final segments = [
      UsageSegment(label: 'Happy Drive', bytes: mine, color: colors.first),
      if (device != null)
        UsageSegment(
          label: 'Other apps and system',
          bytes: max(0, device.used - mine),
          color: theme.colorScheme.outline,
        ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (device == null && app == null)
            Text('Measuring this phone…', style: muted)
          else ...[
            if (device != null) ...[
              Text(
                '${storageSize(device.free)} free of '
                '${storageSize(device.total)}',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 10),
              UsageBar(segments: segments, total: device.total),
              const SizedBox(height: 12),
              for (final segment in segments)
                UsageLegendRow(
                  segment: segment,
                  total: device.total,
                  trailing: storageSize(segment.bytes),
                ),
              UsageLegendRow(
                segment: UsageSegment(
                  label: 'Free',
                  bytes: device.free,
                  color: theme.colorScheme.surfaceContainerHighest,
                ),
                total: device.total,
                trailing: storageSize(device.free),
              ),
            ] else
              Text('This phone doesn\'t say how full it is.', style: muted),
            if (app != null) ...[
              const Divider(height: 28),
              Text('Inside Happy Drive', style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              for (final (label, bytes, note) in [
                ('Library index', app.library, 'what\'s backed up, places'),
                ('Thumbnails', app.thumbnails, 'encrypted, for scrolling'),
                ('Temporary files', app.temporary, 'cleared by the phone'),
              ])
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text.rich(
                          TextSpan(
                            text: label,
                            children: [TextSpan(text: '  $note', style: muted)],
                          ),
                        ),
                      ),
                      Text(storageSize(bytes)),
                    ],
                  ),
                ),
              const SizedBox(height: 6),
              Text(
                'Your photos themselves are in your Hugging Face storage, not '
                'here. Clearing the thumbnail cache below frees the '
                'thumbnails.',
                style: muted,
              ),
            ],
          ],
        ],
      ),
    );
  }
}
