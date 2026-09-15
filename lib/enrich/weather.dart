import 'dart:convert';

import 'package:http/http.dart' as http;

class WeatherReport {
  final int code;
  final double? tempC;
  const WeatherReport(this.code, this.tempC);

  String get summary => describeWeatherCode(code);

  Map<String, dynamic> toJson() => {
    'code': code,
    'tempC': ?tempC,
    'summary': summary,
  };
}

/// The archive doesn't have this hour yet (it runs a few days behind).
class WeatherNotReady implements Exception {}

/// Past weather from Open-Meteo. Only a rounded location (about 11 km) and
/// the date are sent; results are cached per area and day, so photos taken
/// near each other on the same day cost one request.
class WeatherClient {
  final http.Client _http;
  final DateTime Function() clock;
  final _cache = <String, Future<Map<String, dynamic>>>{};

  WeatherClient({http.Client? client, DateTime Function()? clock})
    : _http = client ?? http.Client(),
      clock = clock ?? DateTime.now;

  void close() => _http.close();

  /// Weather at [takenAt] near [lat],[lng]. Returns null for photos from the
  /// future (a wrong camera clock). Throws [WeatherNotReady] when the data
  /// isn't published yet.
  Future<WeatherReport?> lookup(
    double lat,
    double lng,
    DateTime takenAt,
  ) async {
    final utc = takenAt.toUtc();
    final now = clock().toUtc();
    if (utc.isAfter(now)) return null;
    if (utc.year < 1940) return null; // before the reanalysis record starts

    final rLat = (lat * 10).round() / 10;
    final rLng = (lng * 10).round() / 10;
    final day = utc.toIso8601String().substring(0, 10);
    final recent = now.difference(utc) < const Duration(days: 7);
    final key = '$rLat,$rLng,$day,$recent';

    final Map<String, dynamic> json;
    try {
      json = await (_cache[key] ??= _fetch(rLat, rLng, day, recent));
    } catch (_) {
      _cache.remove(key);
      rethrow;
    }
    final hourly = json['hourly'] as Map<String, dynamic>?;
    final times = (hourly?['time'] as List?)?.cast<String>() ?? const [];
    final hour = '${day}T${utc.hour.toString().padLeft(2, '0')}:00';
    final i = times.indexOf(hour);
    if (i < 0) throw WeatherNotReady();
    final code = (hourly!['weather_code'] as List?)?[i];
    final temp = (hourly['temperature_2m'] as List?)?[i];
    if (code == null) throw WeatherNotReady();
    return WeatherReport(
      (code as num).toInt(),
      temp == null ? null : ((temp as num).toDouble() * 10).round() / 10,
    );
  }

  Future<Map<String, dynamic>> _fetch(
    double lat,
    double lng,
    String day,
    bool recent,
  ) async {
    final uri = Uri.https(
      recent ? 'api.open-meteo.com' : 'archive-api.open-meteo.com',
      recent ? '/v1/forecast' : '/v1/archive',
      {
        'latitude': '$lat',
        'longitude': '$lng',
        'start_date': day,
        'end_date': day,
        'hourly': 'temperature_2m,weather_code',
        'timezone': 'GMT',
      },
    );
    final r = await _http.get(uri).timeout(const Duration(seconds: 30));
    if (r.statusCode == 400) throw WeatherNotReady();
    if (r.statusCode != 200) {
      throw http.ClientException('Weather service error ${r.statusCode}', uri);
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }
}

/// WMO weather interpretation codes, as used by Open-Meteo.
String describeWeatherCode(int code) => switch (code) {
  0 => 'Clear sky',
  1 => 'Mostly clear',
  2 => 'Partly cloudy',
  3 => 'Overcast',
  45 || 48 => 'Fog',
  51 || 53 || 55 => 'Drizzle',
  56 || 57 => 'Freezing drizzle',
  61 => 'Light rain',
  63 => 'Rain',
  65 => 'Heavy rain',
  66 || 67 => 'Freezing rain',
  71 => 'Light snow',
  73 => 'Snow',
  75 => 'Heavy snow',
  77 => 'Snow grains',
  80 || 81 => 'Rain showers',
  82 => 'Heavy showers',
  85 || 86 => 'Snow showers',
  95 => 'Thunderstorm',
  96 || 99 => 'Thunderstorm with hail',
  _ => 'Unknown weather',
};
