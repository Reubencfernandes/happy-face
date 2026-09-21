import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// The public half of a Hugging Face profile: enough to show who is signed
/// in. Read from huggingface.co's public API with no token, so it works for
/// any username and reveals nothing about the bucket.
class HfProfile {
  final String username;
  final String? fullName;
  final String? avatarUrl;
  final bool isPro;

  /// An organisation's plan ("team", "enterprise"). Null for a person.
  final String? plan;

  /// How many buckets the profile says the account has, when it says.
  final int? buckets;

  const HfProfile({
    required this.username,
    this.fullName,
    this.avatarUrl,
    this.isPro = false,
    this.plan,
    this.buckets,
  });

  /// Hugging Face's published private-storage allowance for this kind of
  /// account, in bytes — what a bucket's contents count against.
  ///
  /// From huggingface.co/docs/hub/storage-limits, read 21 September 2026:
  /// a free account gets 100GB included and PRO gets 1TB. Organisations are
  /// "1TB per seat", which depends on billing we can't see, so they get
  /// null rather than a guess. Null means "show what is stored, promise
  /// nothing about what's left".
  int? get privateAllowance => switch (this) {
    _ when plan != null => null,
    _ when isPro => 1000000000000,
    _ => 100000000000,
  };

  /// How that allowance is written on the pricing page.
  String? get allowanceLabel => switch (privateAllowance) {
    1000000000000 => '1 TB',
    100000000000 => '100 GB',
    _ => null,
  };

  /// The plan the allowance comes from.
  String get planLabel => switch (this) {
    _ when plan != null =>
      '${plan![0].toUpperCase()}${plan!.substring(1)} plan',
    _ when isPro => 'PRO',
    _ => 'Free plan',
  };

  String get displayName =>
      (fullName?.trim().isNotEmpty ?? false) ? fullName!.trim() : username;

  /// Up to two letters for the avatar to fall back on.
  String get initials {
    final words = displayName
        .split(RegExp(r'[\s_.-]+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return '?';
    final letters = words.length == 1
        ? words.first.substring(0, 1)
        : '${words.first[0]}${words[1][0]}';
    return letters.toUpperCase();
  }

  Map<String, dynamic> toJson() => {
    'username': username,
    'fullName': ?fullName,
    'avatarUrl': ?avatarUrl,
    'isPro': isPro,
    'plan': ?plan,
    'buckets': ?buckets,
  };

  factory HfProfile.fromJson(Map<String, dynamic> json) => HfProfile(
    // Users call it "user", organisations call it "name".
    username:
        (json['user'] ?? json['name'] ?? json['username'] ?? '') as String,
    fullName: json['fullname'] as String? ?? json['fullName'] as String?,
    avatarUrl: _absolute(json['avatarUrl'] as String?),
    isPro: json['isPro'] == true,
    plan: json['plan'] as String?,
    buckets: (json['numBuckets'] ?? json['buckets']) as int?,
  );

  /// Site-relative paths are made absolute, and SVGs are dropped: Hugging
  /// Face serves the generated "no picture yet" avatars as SVG, which
  /// Flutter can't decode — better to show initials than a broken box.
  static String? _absolute(String? url) => switch (url) {
    null || '' => null,
    _ when url.toLowerCase().endsWith('.svg') => null,
    _ when url.startsWith('/') => 'https://huggingface.co$url',
    _ => url,
  };
}

const _timeout = Duration(seconds: 10);

/// Avatars are a few kilobytes; anything much bigger isn't one.
const _maxAvatarBytes = 2 * 1024 * 1024;

/// Downloads the picture itself, rather than leaving it to Image.network:
/// the bytes can then be kept with the rest of the profile, so the face is
/// there offline and on the next run.
///
/// Returns null if it can't be had — the initials stand in.
Future<Uint8List?> fetchHfAvatar(String url, {http.Client? client}) async {
  final connection = client ?? http.Client();
  try {
    final response = await connection.get(Uri.parse(url)).timeout(_timeout);
    if (response.statusCode != 200) return null;
    final bytes = response.bodyBytes;
    // Hugging Face serves these as PNG, JPEG or WebP depending on who asks.
    final type = response.headers['content-type'] ?? '';
    if (!type.startsWith('image/') || type.contains('svg')) return null;
    if (bytes.isEmpty || bytes.length > _maxAvatarBytes) return null;
    return bytes;
  } catch (_) {
    return null;
  } finally {
    if (client == null) connection.close();
  }
}

/// Looks up [username] on huggingface.co, as a user and then as an
/// organisation, since a bucket can live under either. Needs no token: these
/// are the same pages a browser shows to anyone.
///
/// Returns null whenever the profile can't be read — offline, renamed,
/// private, a changed API — because the settings screen works fine without
/// a face.
Future<HfProfile?> fetchHfProfile(
  String username, {
  http.Client? client,
}) async {
  final name = username.trim();
  if (name.isEmpty) return null;
  final connection = client ?? http.Client();
  try {
    for (final kind in const ['users', 'organizations']) {
      final response = await connection
          .get(
            Uri.parse(
              'https://huggingface.co/api/$kind/'
              '${Uri.encodeComponent(name)}/overview',
            ),
          )
          .timeout(_timeout);
      if (response.statusCode == 404) continue;
      if (response.statusCode != 200) return null;
      final json = jsonDecode(response.body);
      if (json is! Map<String, dynamic>) return null;
      final profile = HfProfile.fromJson(json);
      // Keep the name the app signed in with if the reply omits it.
      return profile.username.isEmpty
          ? HfProfile(
              username: name,
              fullName: profile.fullName,
              avatarUrl: profile.avatarUrl,
              isPro: profile.isPro,
              plan: profile.plan,
              buckets: profile.buckets,
            )
          : profile;
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    if (client == null) connection.close();
  }
}
