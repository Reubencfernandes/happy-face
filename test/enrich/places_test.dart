import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:happy_drive/enrich/places.dart';

void main() {
  late PlaceIndex index;

  setUpAll(() {
    // The same files the app bundles.
    index = PlaceIndex.parse(
      utf8.decode(
        gzip.decode(File('assets/places/cities.tsv.gz').readAsBytesSync()),
      ),
      File('assets/places/countries.tsv').readAsStringSync(),
    );
  });

  test('bundled list is loaded', () {
    expect(index.length, greaterThan(30000));
  });

  test('finds the nearest town with its country', () {
    final goa = index.nearest(15.4909, 73.8278)!;
    expect(goa.city, 'Panjim');
    expect(goa.country, 'India');
    expect(goa.distanceKm, lessThan(2));

    expect(index.nearest(38.7223, -9.1393)!.city, 'Lisbon');
    expect(index.nearest(38.7223, -9.1393)!.country, 'Portugal');
    expect(index.nearest(69.6496, 18.9560)!.city, 'Tromsø');
  });

  test('works across the antimeridian', () {
    // Just east of 180°, the closest city is on the other side of the line.
    final fiji = index.nearest(-18.14, 178.44)!;
    expect(fiji.city, 'Suva');
    expect(fiji.country, 'Fiji');
  });

  test('nothing is returned far out at sea', () {
    expect(index.nearest(30.0, -40.0), isNull, reason: 'mid-Atlantic');
    expect(index.nearest(-60.0, 100.0), isNull, reason: 'Southern Ocean');
  });

  test('haversine distance', () {
    // Lisbon to Madrid is about 503 km.
    expect(haversineKm(38.7223, -9.1393, 40.4168, -3.7038), closeTo(503, 5));
    expect(haversineKm(10, 10, 10, 10), 0);
  });
}
