import 'dart:async';
import 'dart:io' show SocketException;
import 'dart:math';

import '../app/session.dart';
import '../data/local_db.dart';
import 'captioner.dart';
import 'places.dart';
import 'weather.dart';

/// Works through the enrichment queue after uploads and syncs: place names
/// (offline, always on), weather (opt-in) and AI descriptions (opt-in, daily
/// limit). Results are written to the catalogue in batches so every device
/// gets them.
class Enricher {
  final Session session;
  final Future<PlaceIndex> Function() loadPlaces;
  final WeatherClient weather;
  final Captioner captioner;
  final Future<String?> Function() readToken;
  final DateTime Function() clock;
  final Future<void> Function(Duration) sleep;

  Future<PlaceIndex>? _places;
  bool _running = false;

  Enricher(
    this.session, {
    Future<PlaceIndex> Function()? loadPlaces,
    WeatherClient? weather,
    Captioner? captioner,
    Future<String?> Function()? readToken,
    DateTime Function()? clock,
    Future<void> Function(Duration)? sleep,
  }) : loadPlaces = loadPlaces ?? PlaceIndex.loadBundled,
       weather = weather ?? WeatherClient(),
       captioner = captioner ?? Captioner(),
       readToken = readToken ?? session.credentials.readHfToken,
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
      if (session.settings.aiCaptions) await _captions();
    } finally {
      _running = false;
    }
  }

  void dispose() {
    weather.close();
    captioner.close();
  }

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

  Future<void> _captions() async {
    final settings = session.settings;
    if (settings.aiPausedReason != null) return;
    final token = await readToken();
    if (token == null || token.isEmpty) return;
    final model = settings.aiModel;
    final since = settings.aiWholeLibrary ? null : settings.aiEnabledAt;

    final patches = <String, Map<String, dynamic>>{};
    final done = <String>[];
    Future<void> flush() async {
      await session.patchPhotos(Map.of(patches));
      for (final id in done) {
        _db.completeJob(id, JobKind.caption);
      }
      patches.clear();
      done.clear();
    }

    try {
      while (settings.aiCaptions) {
        final left = settings.aiDailyLimit - settings.aiUsedToday(clock());
        if (left <= 0) return;
        final jobs = _db.dueJobs(
          JobKind.caption,
          clock(),
          limit: min(10, left),
          uploadedSince: since,
        );
        if (jobs.isEmpty) return;
        for (final job in jobs) {
          final r = _db.photo(job.photoId);
          // Deleted, or already described by another phone.
          if (r == null || r.caption != null) {
            done.add(job.photoId);
            continue;
          }
          try {
            final thumb = await session.photos.thumbnail(r.id);
            if (thumb == null) {
              done.add(r.id);
              continue;
            }
            final result = await captioner.describe(
              thumb,
              model: model,
              token: token,
            );
            settings.recordAiUse(clock());
            patches[r.id] = {
              'caption': result.caption,
              'tags': result.tags,
              'captionModel': model,
            };
            done.add(r.id);
          } on CaptionException catch (e) {
            if (e.pausesCaptioning) {
              settings.aiPausedReason = e.message;
              session.settingsChanged();
              return;
            }
            if (e.failure == CaptionFailure.busy) return;
            final wait = Duration(hours: pow(2, min(job.attempts, 6)).toInt());
            _db.retryJobLater(r.id, JobKind.caption, clock().add(wait));
          } on SocketException {
            return;
          }
        }
        await flush();
      }
    } finally {
      await flush();
    }
  }
}
