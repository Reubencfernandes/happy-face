import 'dart:async';
import 'dart:io' show SocketException;
import 'dart:math';

import '../app/session.dart';
import '../data/local_db.dart';
import 'places.dart';
import 'weather.dart';

/// Works through the enrichment queue after uploads and syncs: place names
/// (offline, always on) and weather (opt-in). Results are written to the
/// catalogue in batches so every device gets them.
class Enricher {
  final Session session;
  final Future<PlaceIndex> Function() loadPlaces;
  final WeatherClient weather;
  final DateTime Function() clock;
  final Future<void> Function(Duration) sleep;

  Future<PlaceIndex>? _places;
  bool _running = false;

  Enricher(
    this.session, {
    Future<PlaceIndex> Function()? loadPlaces,
    WeatherClient? weather,
    DateTime Function()? clock,
    Future<void> Function(Duration)? sleep,
  }) : loadPlaces = loadPlaces ?? PlaceIndex.loadBundled,
       weather = weather ?? WeatherClient(),
       clock = clock ?? DateTime.now,
       sleep = sleep ?? Future.delayed;

  LocalDb get _db => session.db;

  /// Runs every enabled step. Safe to call often; overlapping calls return
  /// immediately.
  Future<void> run() async {
    if (_running) return;
    _running = true;
    try {
      _db.enqueueMissingEnrichment();
      await _placeNames();
      if (session.settings.weather) await _weather();
    } finally {
      _running = false;
    }
  }

  void dispose() => weather.close();

  Future<void> _placeNames() async {
    while (true) {
      final jobs = _db.dueJobs(JobKind.place, clock(), limit: 500);
      if (jobs.isEmpty) return;
      final index = await (_places ??= loadPlaces());
      final patches = <String, Map<String, dynamic>>{};
      for (final job in jobs) {
        final r = _db.photo(job.photoId);
        if (r != null && r.hasLocation) {
          final match = index.nearest(r.lat!, r.lng!);
          if (match != null) {
            patches[r.id] = {'place': match.city, 'country': match.country};
          }
        }
      }
      await session.patchPhotos(patches);
      for (final job in jobs) {
        _db.completeJob(job.photoId, JobKind.place);
      }
    }
  }

  Future<void> _weather() async {
    final patches = <String, Map<String, dynamic>>{};
    final done = <String>[];
    Future<void> flush() async {
      await session.patchPhotos(Map.of(patches));
      for (final id in done) {
        _db.completeJob(id, JobKind.weather);
      }
      patches.clear();
      done.clear();
    }

    try {
      while (session.settings.weather) {
        final jobs = _db.dueJobs(JobKind.weather, clock(), limit: 25);
        if (jobs.isEmpty) break;
        for (final job in jobs) {
          final r = _db.photo(job.photoId);
          if (r == null || !r.hasLocation) {
            done.add(job.photoId);
            continue;
          }
          try {
            final report = await weather.lookup(r.lat!, r.lng!, r.takenAt);
            if (report != null) patches[r.id] = {'weather': report.toJson()};
            done.add(r.id);
          } on WeatherNotReady {
            _db.retryJobLater(
              r.id,
              JobKind.weather,
              clock().add(const Duration(days: 2)),
            );
          } on SocketException {
            return; // Offline: try again next run.
          } catch (_) {
            final wait = Duration(
              minutes: 30 * pow(2, min(job.attempts, 5)).toInt(),
            );
            _db.retryJobLater(r.id, JobKind.weather, clock().add(wait));
          }
          // Stay well inside Open-Meteo's free rate limits.
          await sleep(const Duration(milliseconds: 150));
        }
        await flush();
      }
    } finally {
      await flush();
    }
  }
}
