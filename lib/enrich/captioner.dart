import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class Caption {
  final String caption;
  final List<String> tags;
  const Caption(this.caption, this.tags);
}

enum CaptionFailure {
  /// The token is wrong or lacks the Inference Providers permission.
  token,

  /// Out of Hugging Face credits.
  credits,

  /// The model doesn't exist, isn't served, or can't read images.
  model,

  /// Too many requests; try later.
  busy,

  /// The model replied with something unusable, or a temporary error.
  other,
}

class CaptionException implements Exception {
  final CaptionFailure failure;
  final String message;
  const CaptionException(this.failure, this.message);

  /// Stops all captioning until the user changes something.
  bool get pausesCaptioning =>
      failure == CaptionFailure.token ||
      failure == CaptionFailure.credits ||
      failure == CaptionFailure.model;

  @override
  String toString() => message;
}

/// Describes photos with a vision-language model through Hugging Face
/// Inference Providers. Only the small thumbnail is ever sent.
class Captioner {
  static final endpoint = Uri.parse(
    'https://router.huggingface.co/v1/chat/completions',
  );

  static const prompt =
      'You are labelling a photo in someone\'s private photo library so they '
      'can search it later. Reply with JSON only, no other text: '
      '{"caption": "one plain sentence under 20 words describing the scene", '
      '"tags": ["3 to 8 lowercase words or short phrases: objects, place type, '
      'activity, season or time of day"]}. '
      'Never guess who people are or name them.';

  final http.Client _http;
  Captioner({http.Client? client}) : _http = client ?? http.Client();

  void close() => _http.close();

  Future<Caption> describe(
    Uint8List jpeg, {
    required String model,
    required String token,
  }) async {
    final body = jsonEncode({
      'model': model,
      'max_tokens': 400,
      'temperature': 0.2,
      'messages': [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': prompt},
            {
              'type': 'image_url',
              'image_url': {
                'url': 'data:image/jpeg;base64,${base64Encode(jpeg)}',
              },
            },
          ],
        },
      ],
    });
    final http.Response r;
    try {
      r = await _http
          .post(
            endpoint,
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 90));
    } on TimeoutException {
      throw const CaptionException(
        CaptionFailure.other,
        'The AI service took too long.',
      );
    }

    switch (r.statusCode) {
      case 200:
        break;
      case 401 || 403:
        throw const CaptionException(
          CaptionFailure.token,
          'Your Hugging Face token was rejected. It needs the "Make calls to Inference Providers" permission.',
        );
      case 402:
        throw const CaptionException(
          CaptionFailure.credits,
          'Out of Hugging Face credits. Descriptions are paused until you add credits.',
        );
      case 429:
        throw const CaptionException(
          CaptionFailure.busy,
          'The AI service is busy.',
        );
      case 400 || 404 || 422:
        throw CaptionException(
          CaptionFailure.model,
          'The model "$model" isn\'t available for photos. ${_errorText(r.body)}'
              .trim(),
        );
      default:
        throw CaptionException(
          CaptionFailure.other,
          'AI service error ${r.statusCode}.',
        );
    }

    final String content;
    try {
      final json = jsonDecode(r.body) as Map<String, dynamic>;
      content =
          ((json['choices'] as List).first as Map)['message']['content']
              as String;
    } catch (_) {
      throw const CaptionException(
        CaptionFailure.other,
        'Unexpected reply from the AI service.',
      );
    }
    return parse(content);
  }

  /// Extracts the caption from a model reply, tolerating reasoning blocks,
  /// code fences and chatter around the JSON.
  static Caption parse(String content) {
    var text = content.replaceAll(
      RegExp(r'<think>.*?</think>', dotAll: true),
      '',
    );
    text = text.replaceAll(RegExp(r'```(?:json)?'), '');
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start >= 0 && end > start) {
      try {
        final json = jsonDecode(text.substring(start, end + 1));
        if (json is Map) {
          final caption = _clean(json['caption']?.toString() ?? '');
          final tags = <String>{};
          final rawTags = json['tags'];
          for (final t in rawTags is List ? rawTags : const []) {
            final tag = _clean('$t').toLowerCase();
            if (tag.isNotEmpty && tag.length <= 40) tags.add(tag);
          }
          if (caption.isNotEmpty) {
            return Caption(caption, tags.take(10).toList());
          }
        }
      } on FormatException {
        // Fall through to plain text.
      }
    }
    // No JSON: accept a short plain-text description.
    final plain = _clean(text);
    if (plain.isNotEmpty && plain.length <= 300 && !plain.contains('{')) {
      return Caption(plain, const []);
    }
    throw const CaptionException(
      CaptionFailure.other,
      'The AI reply couldn\'t be understood.',
    );
  }

  static String _clean(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

  static String _errorText(String body) {
    try {
      final json = jsonDecode(body);
      if (json is Map) {
        final e = json['error'];
        final message = e is Map ? e['message'] : e;
        if (message is String) {
          return message.length > 140
              ? '${message.substring(0, 140)}…'
              : message;
        }
      }
    } catch (_) {}
    return '';
  }
}
