// These checks print a report for a person to read.
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:happy_drive/enrich/weather.dart';

/// Live check of weather lookups. Run with:
///   LIVE_WEATHER=1 flutter test test/live/weather_test.dart
void main() {
  if (Platform.environment['LIVE_WEATHER'] == null) {
    test('live weather check', () {}, skip: 'set LIVE_WEATHER=1 to run');
    return;
  }
  test('real Open-Meteo lookups', () async {
    final client = WeatherClient();
    Future<void> look(
      String what,
      double lat,
      double lng,
      DateTime when,
    ) async {
      try {
        final r = await client.lookup(lat, lng, when);
        print(
          'OK   $what ${when.toIso8601String()} -> ${r?.summary}, ${r?.tempC}C',
        );
      } on WeatherNotReady {
        print('WAIT $what -> not published yet (will retry later)');
      } catch (e) {
        print('FAIL $what -> $e');
      }
    }

    // Panjim, Goa: monsoon afternoon and a dry-season morning.
    await look('Goa monsoon', 15.4909, 73.8278, DateTime.utc(2025, 7, 15, 9));
    await look('Goa dry', 15.4909, 73.8278, DateTime.utc(2025, 1, 15, 4));
    await look('Lisbon', 38.7223, -9.1393, DateTime.utc(2024, 12, 25, 12));
    // Yesterday: exercises the forecast API path.
    await look(
      'yesterday',
      15.4909,
      73.8278,
      DateTime.now().toUtc().subtract(const Duration(days: 1)),
    );
    client.close();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
