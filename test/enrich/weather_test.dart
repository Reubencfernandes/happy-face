import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:happy_drive/enrich/weather.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

String hourly(String day, {List<int?>? codes, List<double?>? temps}) =>
    jsonEncode({
      'hourly': {
        'time': [
          for (var h = 0; h < 24; h++)
            '${day}T${h.toString().padLeft(2, '0')}:00',
        ],
        'weather_code': codes ?? List.generate(24, (h) => h < 12 ? 0 : 63),
        'temperature_2m': temps ?? List.generate(24, (h) => 20.0 + h / 10),
      },
    });

void main() {
  final now = DateTime.utc(2026, 9, 15, 12);

  test(
    'reads the hour the photo was taken, from the archive for old photos',
    () async {
      final requests = <Uri>[];
      final client = WeatherClient(
        clock: () => now,
        client: MockClient((r) async {
          requests.add(r.url);
          return http.Response(hourly('2025-06-01'), 200);
        }),
      );
      final morning = await client.lookup(
        15.4909,
        73.8278,
        DateTime.utc(2025, 6, 1, 9, 40),
      );
      expect(morning!.code, 0);
      expect(morning.summary, 'Clear sky');
      expect(morning.tempC, 20.9);

      final evening = await client.lookup(
        15.4911,
        73.8281,
        DateTime.utc(2025, 6, 1, 18),
      );
      expect(evening!.summary, 'Rain');

      expect(requests, hasLength(1), reason: 'same area and day is cached');
      final uri = requests.single;
      expect(uri.host, 'archive-api.open-meteo.com');
      expect(
        uri.queryParameters['latitude'],
        '15.5',
        reason: 'location is rounded',
      );
      expect(uri.queryParameters['longitude'], '73.8');
      expect(uri.queryParameters['start_date'], '2025-06-01');
      expect(uri.queryParameters['timezone'], 'GMT');
    },
  );

  test('recent photos use the forecast API, which has no delay', () async {
    late Uri seen;
    final client = WeatherClient(
      clock: () => now,
      client: MockClient((r) async {
        seen = r.url;
        return http.Response(hourly('2026-09-14'), 200);
      }),
    );
    await client.lookup(38.72, -9.14, DateTime.utc(2026, 9, 14, 15));
    expect(seen.host, 'api.open-meteo.com');
    expect(seen.path, '/v1/forecast');
  });

  test('missing values mean not published yet', () async {
    final client = WeatherClient(
      clock: () => now,
      client: MockClient(
        (r) async => http.Response(
          hourly('2026-09-01', codes: List.filled(24, null)),
          200,
        ),
      ),
    );
    await expectLater(
      client.lookup(1, 1, DateTime.utc(2026, 9, 1, 10)),
      throwsA(isA<WeatherNotReady>()),
    );
  });

  test('photos from the future or before records began are skipped', () async {
    final client = WeatherClient(
      clock: () => now,
      client: MockClient((r) async => fail('no request expected')),
    );
    expect(await client.lookup(1, 1, DateTime.utc(2030)), isNull);
    expect(await client.lookup(1, 1, DateTime.utc(1900)), isNull);
  });

  test('a failed request is not cached', () async {
    var calls = 0;
    final client = WeatherClient(
      clock: () => now,
      client: MockClient((r) async {
        calls++;
        return calls == 1
            ? http.Response('busy', 503)
            : http.Response(hourly('2025-01-01'), 200);
      }),
    );
    await expectLater(
      client.lookup(1, 1, DateTime.utc(2025, 1, 1, 5)),
      throwsA(isA<http.ClientException>()),
    );
    expect((await client.lookup(1, 1, DateTime.utc(2025, 1, 1, 5)))!.code, 0);
    expect(calls, 2);
  });

  test('every WMO code has a readable description', () {
    for (final code in [
      0,
      1,
      2,
      3,
      45,
      48,
      51,
      56,
      61,
      63,
      65,
      66,
      71,
      73,
      75,
      77,
      80,
      82,
      85,
      95,
      96,
      99,
    ]) {
      expect(
        describeWeatherCode(code),
        isNot('Unknown weather'),
        reason: '$code',
      );
    }
    expect(describeWeatherCode(42), 'Unknown weather');
  });
}
