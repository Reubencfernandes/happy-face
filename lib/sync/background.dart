import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:workmanager/workmanager.dart';

import '../app/credentials.dart';
import '../app/paths.dart';
import '../app/session.dart';
import '../crypto/vault.dart';
import '../enrich/enricher.dart';

const _taskName = 'happy-drive-backup';

/// Entry point for the OS-scheduled background task.
@pragma('vm:entry-point')
void backgroundDispatcher() {
  Workmanager().executeTask((task, input) async {
    try {
      // This isolate gets its own plugin registrations: without them the
      // native crypto and the path lookups here fall back to slow or absent
      // implementations.
      DartPluginRegistrant.ensureInitialized();
      await runBackgroundBackup();
    } catch (e) {
      debugPrint('Happy Drive background backup failed: $e');
    }
    // Always report success: a failed run simply tries again next period.
    return true;
  });
}

/// One background pass: sync, look for new photos, upload for up to
/// [budget] (Android stops background work after about 10 minutes).
Future<void> runBackgroundBackup({
  Duration budget = const Duration(minutes: 8),
  CredentialStore credentials = const CredentialStore(),
}) async {
  final account = await credentials.readAccount();
  if (account == null) return;
  final key = await credentials.readMasterKey(account);
  if (key == null) return;
  final session = await Session.open(
    account: account,
    vault: await Vault.fromMasterKey(key),
    dataDir: await appDataDir(),
    credentials: credentials,
  );
  try {
    if (!session.settings.autoBackup) return;
    // The app itself may be backing up right now. Two backups over one
    // database and one bucket duplicate work, and the Stop button in the app
    // has no way to reach this one — so stand aside and try again next hour.
    if (Session.backupRunningElsewhere(session.db)) return;
    await session.sync();
    final access = await session.scanGallery();
    if (!access.hasAccess) return;
    await session.backUpPending(budget: budget);
    final enricher = Enricher(session);
    try {
      await enricher.run();
    } finally {
      enricher.dispose();
    }
  } finally {
    session.dispose();
  }
}

/// Keeps the OS schedule in step with the auto-backup settings.
///
/// Android only. iOS decides for itself when (and whether) background tasks
/// run, so on iPhone new photos are backed up when the app is opened.
abstract final class BackgroundBackup {
  static bool get supported => !kIsWeb && Platform.isAndroid;

  static Future<void> configure({
    required bool enabled,
    required bool wifiOnly,
  }) async {
    if (!supported) return;
    final workmanager = Workmanager();
    await workmanager.initialize(backgroundDispatcher);
    if (!enabled) {
      await workmanager.cancelByUniqueName(_taskName);
      return;
    }
    await workmanager.registerPeriodicTask(
      _taskName,
      _taskName,
      frequency: const Duration(hours: 1),
      constraints: Constraints(
        networkType: wifiOnly ? NetworkType.unmetered : NetworkType.connected,
        requiresBatteryNotLow: true,
        requiresStorageNotLow: true,
      ),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(minutes: 15),
    );
  }
}
