import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:usage_stats/usage_stats.dart';
import 'privacy_authorization_service.dart';

class UsageReportService {
  static const String _trackerPackage = 'org.vestaopensource.tracker';

  static Future<void> collectDailyReport({
    required String childId,
    required FirebaseFirestore db,
  }) async {
    try {
      if (!await PrivacyAuthorizationService.isAuthorized('usage_stats')) {
        return;
      }

      final permission = await UsageStats.checkUsagePermission() ?? false;
      final now = DateTime.now();
      final start = DateTime(now.year, now.month, now.day);
      final dateKey = '${now.year.toString().padLeft(4, '0')}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';

      final reportRef = db
          .collection('children')
          .doc(childId)
          .collection('usage_reports')
          .doc(dateKey);

      if (!permission) {
        await reportRef.set({
          'date': dateKey,
          'collectionStatus': 'permission_required',
          'permissionGranted': false,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        return;
      }

      final usageStats = await UsageStats.queryUsageStats(
        start,
        now,
        intervalType: IntervalType.daily,
      );

      final events = await UsageStats.queryEvents(start, now);
      final appNames = <String, String>{};

      if (await PrivacyAuthorizationService.isAuthorized('app_filtering')) {
        final installedSnapshot = await db
            .collection('children')
            .doc(childId)
            .collection('installed_apps')
            .get();

        if (await PrivacyAuthorizationService.isAuthorized('app_filtering')) {
          appNames.addAll({
            for (final doc in installedSnapshot.docs)
              doc.id: (doc.data()['appName'] ?? doc.id).toString(),
          });
        }
      }

      final appUsage = <String, Map<String, dynamic>>{};
      var totalAppUsageMs = 0;
      for (final usage in usageStats) {
        final packageName = usage.packageName?.trim() ?? '';
        final foregroundMs = usage.totalTimeInForegroundMs ?? 0;

        if (packageName.isEmpty ||
            packageName == _trackerPackage ||
            foregroundMs <= 0) {
          continue;
        }

        final entry = appUsage.putIfAbsent(
            packageName,
            () => {
                  'packageName': packageName,
                  'appName': appNames[packageName] ?? packageName,
                  'foregroundTimeMs': 0,
                  'launchCount': 0,
                });

        entry['foregroundTimeMs'] =
            (entry['foregroundTimeMs'] as int) + foregroundMs;
        totalAppUsageMs += foregroundMs;
      }

      final orderedEvents = events.toList()
        ..sort((a, b) {
          final aTime = a.timeStampDate;
          final bTime = b.timeStampDate;
          if (aTime == null || bTime == null) return 0;
          return aTime.compareTo(bTime);
        });

      var totalAppOpens = 0;
      var screenInteractive = false;
      DateTime? screenStart;
      var totalScreenTimeMs = 0;

      for (final event in orderedEvents) {
        final eventTime = event.timeStampDate;
        if (eventTime == null) continue;

        final type = event.eventTypeDescription;
        final packageName = event.packageName?.trim() ?? '';

        if (type == 'ACTIVITY_RESUMED' &&
            packageName.isNotEmpty &&
            packageName != _trackerPackage) {
          totalAppOpens++;
          final entry = appUsage.putIfAbsent(
              packageName,
              () => {
                    'packageName': packageName,
                    'appName': appNames[packageName] ?? packageName,
                    'foregroundTimeMs': 0,
                    'launchCount': 0,
                  });
          entry['launchCount'] = (entry['launchCount'] as int) + 1;
        }

        if (type == 'SCREEN_INTERACTIVE' && !screenInteractive) {
          screenInteractive = true;
          screenStart = eventTime;
        } else if (type == 'SCREEN_NON_INTERACTIVE' &&
            screenInteractive &&
            screenStart != null) {
          final duration = eventTime.difference(screenStart).inMilliseconds;
          if (duration > 0) totalScreenTimeMs += duration;
          screenInteractive = false;
          screenStart = null;
        }
      }

      if (screenInteractive && screenStart != null) {
        final duration = now.difference(screenStart).inMilliseconds;
        if (duration > 0) totalScreenTimeMs += duration;
      }

      final apps = appUsage.values.toList()
        ..sort((a, b) => (b['foregroundTimeMs'] as int)
            .compareTo(a['foregroundTimeMs'] as int));

      if (!await PrivacyAuthorizationService.isAuthorized('usage_stats')) {
        return;
      }

      await reportRef.set({
        'date': dateKey,
        'totalScreenTimeMs': totalScreenTimeMs,
        'totalAppUsageMs': totalAppUsageMs,
        'totalAppOpens': totalAppOpens,
        'apps': apps.take(30).toList(),
        'permissionGranted': true,
        'collectionStatus': 'active',
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      debugPrint(
        'Vesta usage report actualizado: $dateKey '
        '(${apps.length} aplicaciones)',
      );
    } catch (e) {
      debugPrint('Error recopilando estadísticas de uso: $e');
    }
  }
}
