// These checks print a report for a person to read.
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:happy_drive/app/session.dart';
import 'package:happy_drive/enrich/captioner.dart';

// Live check against Hugging Face Inference Providers. Not part of the suite.
/// Live check of AI descriptions. Skipped unless configured:
///
///   HF_TOKEN=hf_... TEST_IMAGE=/path/to/photo.jpg ///   flutter test test/live/caption_test.dart
void main() {
  final token = Platform.environment['HF_TOKEN'];
  final imagePath = Platform.environment['TEST_IMAGE'];
  if (token == null || imagePath == null) {
    test(
      'live caption check',
      () {},
      skip: 'set HF_TOKEN and TEST_IMAGE to run',
    );
    return;
  }

  test(
    'describe a real photo with the default model',
    () async {
      final bytes = File(imagePath).readAsBytesSync();
      final captioner = Captioner();
      final models = [
        Settings.defaultAiModel,
        'Qwen/Qwen2.5-VL-7B-Instruct',
        'zai-org/GLM-4.5V',
        'meta-llama/Llama-4-Scout-17B-16E-Instruct',
      ];
      for (final model in models) {
        final started = DateTime.now();
        try {
          final r = await captioner.describe(bytes, model: model, token: token);
          final ms = DateTime.now().difference(started).inMilliseconds;
          print(
            'OK   $model (${ms}ms)\n     caption: ${r.caption}\n     tags: ${r.tags}',
          );
        } on CaptionException catch (e) {
          print('FAIL $model -> ${e.failure.name}: $e');
        }
      }
      captioner.close();
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
