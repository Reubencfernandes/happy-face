import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:math';

import 'package:flutter/services.dart' show rootBundle;

class PlaceMatch {
  final String city;
  final String country;
  final String countryCode;
  final double distanceKm;
  const PlaceMatch(this.city, this.country, this.countryCode, this.distanceKm);
}

/// Offline reverse geocoding: the nearest town or city (population 15,000+)
/// from the bundled GeoNames list. Coordinates never leave the phone.
class PlaceIndex {
  final List<double> _lat;
  final List<double> _lng;
  final List<String> _name;
  final List<String> _cc;
  final Map<String, String> _countries;

  /// 1°×1° cells → indexes into the lists above.
  final Map<int, List<int>> _grid = {};

  PlaceIndex._(this._lat, this._lng, this._name, this._cc, this._countries) {
    for (var i = 0; i < _lat.length; i++) {
      (_grid[_cell(_lat[i].floor(), _lng[i].floor())] ??= []).add(i);
    }
  }

  int get length => _lat.length;

  static Future<PlaceIndex> loadBundled() async {
    final cities = await rootBundle.load('assets/places/cities.tsv.gz');
    final countries = await rootBundle.loadString(
      'assets/places/countries.tsv',
    );
    return parse(
      utf8.decode(
        gzip.decode(
          cities.buffer.asUint8List(cities.offsetInBytes, cities.lengthInBytes),
        ),
      ),
      countries,
    );
  }

  static PlaceIndex parse(String citiesTsv, String countriesTsv) {
    final countries = <String, String>{};
    for (final line in const LineSplitter().convert(countriesTsv)) {
      if (line.startsWith('#') || line.isEmpty) continue;
      final f = line.split('\t');
      if (f.length >= 2) countries[f[0]] = f[1];
    }
    final lat = <double>[], lng = <double>[];
    final name = <String>[], cc = <String>[];
    for (final line in const LineSplitter().convert(citiesTsv)) {
      if (line.startsWith('#') || line.isEmpty) continue;
      final f = line.split('\t');
      if (f.length < 4) continue;
      final la = double.tryParse(f[0]), lo = double.tryParse(f[1]);
      if (la == null || lo == null) continue;
      lat.add(la);
      lng.add(lo);
      name.add(f[2]);
      cc.add(f[3]);
    }
    return PlaceIndex._(lat, lng, name, cc, countries);
  }

  /// The nearest place within [maxKm], or null (e.g. far out at sea).
  PlaceMatch? nearest(double latitude, double longitude, {double maxKm = 60}) {
    final baseLat = latitude.floor();
    final baseLng = longitude.floor();
    // 1° of latitude is ~111 km; widen the longitude search near the poles.
    final lngReach = (1 / max(cos(latitude * pi / 180), 0.2)).ceil();
    int? best;
    var bestKm = double.infinity;
    for (var dLat = -1; dLat <= 1; dLat++) {
      for (var dLng = -lngReach; dLng <= lngReach; dLng++) {
        var cellLng = baseLng + dLng;
        if (cellLng < -180) cellLng += 360;
        if (cellLng >= 180) cellLng -= 360;
        for (final i
            in _grid[_cell(baseLat + dLat, cellLng)] ?? const <int>[]) {
          final km = haversineKm(latitude, longitude, _lat[i], _lng[i]);
          if (km < bestKm) {
            bestKm = km;
            best = i;
          }
        }
      }
    }
    if (best == null || bestKm > maxKm) return null;
    return PlaceMatch(
      _name[best],
      _countries[_cc[best]] ?? _cc[best],
      _cc[best],
      bestKm,
    );
  }

  static int _cell(int lat, int lng) => (lat + 90) * 360 + (lng + 180);
}

double haversineKm(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371.0;
  double rad(double d) => d * pi / 180;
  final dLat = rad(lat2 - lat1);
  final dLng = rad(lng2 - lng1);
  final a =
      pow(sin(dLat / 2), 2) +
      cos(rad(lat1)) * cos(rad(lat2)) * pow(sin(dLng / 2), 2);
  return 2 * r * asin(min(1.0, sqrt(a)));
}
