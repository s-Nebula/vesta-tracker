import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:battery_plus/battery_plus.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_options.dart';
import 'services/api_client.dart';
import 'services/geofence.dart';
import 'services/privacy_authorization_service.dart';
import 'services/usage_report_service.dart';

import 'package:vesta_tracker/l10n/tr.dart';
void _fireAndForget(Future<Object?> write, String label) {
  unawaited(write.then<void>(
    (_) {},
    onError: (Object error) => debugPrint('Error escribiendo $label: $error'),
  ));
}

@pragma('vm:entry-point')
class LocationService {
  /// Event the service sends to the UI when the guardian unlinks.
  static const String deviceUnlinkedEvent = 'deviceUnlinked';

  /// Offline time after which the guardian is notified on reconnection.
  static const Duration _offlineAlertThreshold = Duration(minutes: 15);

  static Future<void> initializeService() async {
    final service = FlutterBackgroundService();

    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onStart,
        isForegroundMode: true,
        autoStart: true,
        autoStartOnBoot: true,
        notificationChannelId: 'vesta_tracker_channel',
        initialNotificationTitle: 'Vesta Tracker',
        initialNotificationContent: tr('Servicio de protección activo'),
        foregroundServiceTypes: [AndroidForegroundType.location],
      ),
      iosConfiguration: IosConfiguration(autoStart: true),
    );

    await service.startService();
  }

  @pragma('vm:entry-point')
  static Future<void> onStart(ServiceInstance service) async {
    DartPluginRegistrant.ensureInitialized();

    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );

    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final childId = prefs.getString('child_id');

    if (childId == null || childId.isEmpty) {
      await PrivacyAuthorizationService.clearLocalLink();
      await PrivacyAuthorizationService.applyNativeFlags();
      service.stopSelf();
      return;
    }

    final db = FirebaseFirestore.instance;
    final battery = Battery();
    final childRef = db.collection('children').doc(childId);

    final lowBatteryKey = 'battery_low_alerted_$childId';
    final criticalBatteryKey = 'battery_critical_alerted_$childId';
    final speedAlertKey = 'speed_alert_active_$childId';
    final locationOffKey = 'location_off_alerted_$childId';
    const offlineSinceKey = 'offline_since_ms';

    var batteryUpdating = false;
    var usageUpdating = false;
    var refreshing = false;
    var reconciling = false;
    var stopped = false;

    var speedAlertActive = prefs.getBool(speedAlertKey) ?? false;

    AndroidDeviceInfo? deviceInfo;
    try {
      deviceInfo = await DeviceInfoPlugin().androidInfo;
    } catch (e) {
      debugPrint('No se pudo consultar información del dispositivo: $e');
    }

    StreamSubscription<List<ConnectivityResult>>? connectivitySubscription;
    StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
        appRulesSubscription;
    StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
        domainRulesSubscription;
    StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
        studyModeSubscription;
    StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
        appLimitsSubscription;
    StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
        webProtectionSubscription;
    StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
        approvedRequestsSubscription;
    StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? zonesSubscription;
    StreamSubscription<Position>? positionSubscription;

    var zones = <SafeZone>[];
    Map<String, String> zoneState = {};
    try {
      final raw = prefs.getString('zone_state_$childId');
      if (raw != null) {
        zoneState = Map<String, String>.from(jsonDecode(raw) as Map);
      }
    } catch (_) {}
    StreamSubscription<ServiceStatus>? locationServiceSubscription;

    Timer? batteryTimer;
    Timer? usageTimer;
    Timer? authorizationTimer;

    Future<bool> allowed(String purpose) {
      return PrivacyAuthorizationService.isAuthorized(purpose);
    }

    /// Records an alert for the guardians. `occurredAt` keeps the actual time of
    /// the event even if the write is synced later.
    Future<void> addAlert({
      required String purpose,
      required String title,
      required String subtitle,
      required String type,
      required String eventKey,
      Map<String, dynamic> extra = const {},
    }) async {
      if (!await allowed('alerts') || !await allowed(purpose)) return;

      // Offline, the Firestore Future does not complete until it syncs;
      // the write is already in the local queue, so it is not awaited.
      _fireAndForget(
        childRef.collection('alerts').add({
          'title': title,
          'subtitle': subtitle,
          'type': type,
          'eventKey': eventKey,
          'timestamp': FieldValue.serverTimestamp(),
          'occurredAt': Timestamp.now(),
          ...extra,
        }),
        'alerta $eventKey',
      );
    }

    Future<void> updateBatteryStatus() async {
      if (stopped || batteryUpdating) return;
      if (!await allowed('device_status')) return;

      batteryUpdating = true;

      try {
        final level = await battery.batteryLevel;
        final state = await battery.batteryState;

        String connection = 'desconocida';

        try {
          final results = await Connectivity().checkConnectivity();

          if (results.contains(ConnectivityResult.wifi)) {
            connection = 'wifi';
          } else if (results.contains(ConnectivityResult.mobile)) {
            connection = 'datos móviles';
          } else if (results.contains(ConnectivityResult.ethernet)) {
            connection = 'ethernet';
          } else if (results.contains(ConnectivityResult.none)) {
            connection = 'sin conexión';
          } else if (results.isNotEmpty) {
            connection = results.map((result) => result.name).join(', ');
          }
        } catch (e) {
          debugPrint('Error consultando conectividad: $e');
        }

        final deviceMetadata = <String, dynamic>{
          if (deviceInfo != null) ...{
            'manufacturer': deviceInfo.manufacturer,
            'model': deviceInfo.model,
            'brand': deviceInfo.brand,
            'androidVersion': deviceInfo.version.release,
            'androidSdk': deviceInfo.version.sdkInt,
          },
        };

        if (!await allowed('device_status')) return;

        _fireAndForget(childRef.collection('device_status').doc('current').set({
          ...deviceMetadata,
          'connectivity': connection,
          'batteryLevel': level,
          'batteryState': state.name,
          'isCharging':
              state == BatteryState.charging || state == BatteryState.full,
          'updatedAt': FieldValue.serverTimestamp(),
          'reportedAt': Timestamp.now(),
        }, SetOptions(merge: true)), 'estado del dispositivo');

        final lowAlerted = prefs.getBool(lowBatteryKey) ?? false;
        final criticalAlerted = prefs.getBool(criticalBatteryKey) ?? false;

        if (level <= 20 && !lowAlerted) {
          await addAlert(
            purpose: 'device_status',
            title: tr('Batería baja'),
            subtitle: tr('La batería del dispositivo está al {0}%.', [level]),
            type: 'warning',
            eventKey: 'battery_low',
          );
          await prefs.setBool(lowBatteryKey, true);
        }

        if (level <= 10 && !criticalAlerted) {
          await addAlert(
            purpose: 'device_status',
            title: tr('Batería crítica'),
            subtitle:
                tr('La batería está al {0}%. Conecte el dispositivo a un cargador.', [level]),
            type: 'critical',
            eventKey: 'battery_critical',
          );
          await prefs.setBool(criticalBatteryKey, true);
        }

        if (level > 25) {
          await prefs.setBool(lowBatteryKey, false);
        }

        if (level > 15) {
          await prefs.setBool(criticalBatteryKey, false);
        }
      } catch (e) {
        debugPrint('Error actualizando batería: $e');
      } finally {
        batteryUpdating = false;
      }
    }

    Future<void> updateUsageReport() async {
      if (stopped || usageUpdating) return;
      if (!await allowed('usage_stats')) return;

      usageUpdating = true;

      try {
        await UsageReportService.collectDailyReport(
          childId: childId,
          db: db,
        );
      } catch (e) {
        debugPrint('Error actualizando informe de uso: $e');
      } finally {
        usageUpdating = false;
      }
    }

    Future<void> syncAppRules(
      QuerySnapshot<Map<String, dynamic>> snapshot,
    ) async {
      try {
        if (!await allowed('app_filtering')) return;

        final blockedApps = <String>{};

        for (final doc in snapshot.docs) {
          final data = doc.data();
          final value = (data['value'] ?? '').toString().trim();

          if (data['type'] == 'block' && value.isNotEmpty) {
            blockedApps.add(value);
          }
        }

        await prefs.setString(
          'blocked_apps_json',
          jsonEncode(blockedApps.toList()),
        );

        debugPrint(
            'Reglas de aplicaciones sincronizadas: ${blockedApps.length}');
      } catch (e) {
        debugPrint('Error sincronizando reglas de aplicaciones: $e');
      }
    }

    Future<void> syncDomainRules(
      QuerySnapshot<Map<String, dynamic>> snapshot,
    ) async {
      try {
        if (!await allowed('domain_filtering')) return;

        final blockedDomains = <String>{};
        final allowedDomains = <String>{};

        for (final doc in snapshot.docs) {
          final data = doc.data();
          final type = data['type'];
          final value = (data['value'] ?? '').toString().trim();

          if (value.isEmpty) continue;

          if (type == 'block') blockedDomains.add(value);
          if (type == 'allow') allowedDomains.add(value);
        }

        await prefs.setString(
          'blocked_domains_json',
          jsonEncode(blockedDomains.toList()),
        );
        await prefs.setString(
          'allowed_domains_json',
          jsonEncode(allowedDomains.toList()),
        );

        debugPrint(
          'Reglas de dominios sincronizadas: '
          '${blockedDomains.length} bloqueados, '
          '${allowedDomains.length} permitidos',
        );
      } catch (e) {
        debugPrint('Error sincronizando reglas de dominios: $e');
      }
    }

    /// Copies the study mode settings to SharedPreferences so that
    /// AppBlockerService (Kotlin) applies them even offline.
    Future<void> syncStudyMode(
      DocumentSnapshot<Map<String, dynamic>> snapshot,
    ) async {
      try {
        if (!await allowed('app_filtering')) return;

        final data = snapshot.data();

        if (!snapshot.exists || data == null) {
          await prefs.remove('study_mode_json');
          return;
        }

        final endsAt = data['endsAt'];
        final schedules = (data['schedules'] is List)
            ? (data['schedules'] as List)
                .whereType<Map>()
                .map((schedule) => {
                      'days': (schedule['days'] is List)
                          ? (schedule['days'] as List)
                              .whereType<num>()
                              .map((day) => day.toInt())
                              .toList()
                          : <int>[],
                      'start': schedule['start']?.toString() ?? '',
                      'end': schedule['end']?.toString() ?? '',
                    })
                .toList()
            : <Map<String, dynamic>>[];

        final allowedApps = (data['allowedApps'] is List)
            ? (data['allowedApps'] as List)
                .map((app) => app.toString().trim())
                .where((app) => app.isNotEmpty)
                .toList()
            : <String>[];

        await prefs.setString(
          'study_mode_json',
          jsonEncode({
            'active': data['active'] == true,
            'endsAtMs': endsAt is Timestamp ? endsAt.millisecondsSinceEpoch : 0,
            'allowedApps': allowedApps,
            'schedules': schedules,
          }),
        );

        debugPrint('Modo estudio sincronizado (activo: ${data['active']}).');
      } catch (e) {
        debugPrint('Error sincronizando modo estudio: $e');
      }
    }

    /// Daily limits per app → AppTimePolicy (Kotlin).
    Future<void> syncAppLimits(
      DocumentSnapshot<Map<String, dynamic>> snapshot,
    ) async {
      if (!await allowed('app_filtering')) return;
      final raw = snapshot.data()?['limits'];
      final limits = <String, int>{};
      if (raw is Map) {
        raw.forEach((key, value) {
          if (value is num && value >= 1 && value <= 1440) {
            limits[key.toString()] = value.toInt();
          }
        });
      }
      await prefs.setString('app_limits_json', jsonEncode(limits));
    }

    /// SafeSearch y bloqueo de DNS cifrado → DnsVpnService (Kotlin).
    Future<void> syncWebProtection(
      DocumentSnapshot<Map<String, dynamic>> snapshot,
    ) async {
      if (!await allowed('domain_filtering')) return;
      final data = snapshot.data();
      await prefs.setString('web_protection_json', jsonEncode({
        'safeSearch': data?['safeSearch'] == true,
        'blockDoh': data?['blockDoh'] != false,
      }));
    }

    /// Requests approved by the guardian → temporary permissions per app.
    Future<void> syncApprovedRequests(
      QuerySnapshot<Map<String, dynamic>> snapshot,
    ) async {
      if (!await allowed('app_filtering')) return;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final grants = <String, int>{};
      for (final doc in snapshot.docs) {
        final data = doc.data();
        final pkg = data['packageName']?.toString() ?? '';
        final until = data['approvedUntil'];
        if (pkg.isEmpty || until is! Timestamp) continue;
        final untilMs = until.millisecondsSinceEpoch;
        if (untilMs <= nowMs) continue;
        if ((grants[pkg] ?? 0) < untilMs) grants[pkg] = untilMs;
      }
      await prefs.setString('temporary_allow_json', jsonEncode(grants));
    }

    Future<void> checkZones(Position position) async {
      if (zones.isEmpty) return;
      final transitions = Geofence.evaluate(
        state: zoneState,
        zones: zones,
        lat: position.latitude,
        lng: position.longitude,
        accuracy: position.accuracy,
      );
      await prefs.setString('zone_state_$childId', jsonEncode(zoneState));

      for (final transition in transitions) {
        final name = transition.zone.name;
        await addAlert(
          purpose: 'location',
          title: transition.entered ? tr('Llegó a {0}', [name]) : tr('Salió de {0}', [name]),
          subtitle: transition.entered
              ? tr('El dispositivo entró en la zona segura "{0}".', [name])
              : tr('El dispositivo salió de la zona segura "{0}".', [name]),
          type: 'info',
          eventKey: transition.entered ? 'zone_enter' : 'zone_exit',
          extra: {
            'zoneId': transition.zone.id,
            'zoneName': name,
            'lat': position.latitude,
            'lng': position.longitude,
          },
        );
      }
    }

    Future<void> stopEverything() async {
      if (stopped) return;
      stopped = true;

      batteryTimer?.cancel();
      usageTimer?.cancel();
      authorizationTimer?.cancel();

      await connectivitySubscription?.cancel();
      await appRulesSubscription?.cancel();
      await domainRulesSubscription?.cancel();
      await studyModeSubscription?.cancel();
      await appLimitsSubscription?.cancel();
      await webProtectionSubscription?.cancel();
      await approvedRequestsSubscription?.cancel();
      await zonesSubscription?.cancel();
      await positionSubscription?.cancel();
      await locationServiceSubscription?.cancel();
    }

    Future<void> handleUnlinked(String reason) async {
      debugPrint('El tutor desvinculó este dispositivo ($reason).');

      await stopEverything();
      await PrivacyAuthorizationService.clearLocalLink();
      await PrivacyAuthorizationService.applyNativeFlags();

      // The VPN and the native blocker stop by themselves when they see the
      // authorisation withdrawn. Tell the UI if it is open.
      service.invoke(deviceUnlinkedEvent, {'reason': reason});
      service.stopSelf();
    }

    void startPositionStream() {
      final androidSettings = AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
        intervalDuration: const Duration(seconds: 10),
        foregroundNotificationConfig: ForegroundNotificationConfig(
          notificationText: tr('Rastreo autorizado para Vesta'),
          notificationTitle: 'Vesta Tracker',
          enableWakeLock: true,
        ),
      );

      positionSubscription = Geolocator.getPositionStream(
        locationSettings: androidSettings,
      ).listen((position) async {
        try {
          if (!await allowed('location')) return;

          final telemetryData = {
            'lat': position.latitude,
            'lng': position.longitude,
            'accuracy': position.accuracy,
            'speed': position.speed,
            // Server time (when it arrived) and actual capture time.
            // Offline, Firestore queues the writes and they would all get
            // the same server time when syncing.
            'timestamp': FieldValue.serverTimestamp(),
            'capturedAt': Timestamp.fromDate(position.timestamp),
            'status': 'activo',
          };

          final telemetryRef = db.collection('telemetria').doc(childId);

          _fireAndForget(
            telemetryRef.set(telemetryData, SetOptions(merge: true)),
            'telemetría',
          );
          _fireAndForget(
            telemetryRef.collection('historial').add(telemetryData),
            'historial de ubicación',
          );

          await checkZones(position);

          if (position.speed > 22.2 && !speedAlertActive) {
            speedAlertActive = true;
            await prefs.setBool(speedAlertKey, true);
            await addAlert(
              purpose: 'location',
              title: tr('Exceso de velocidad'),
              subtitle:
                  tr('Velocidad detectada: {0} km/h', [(position.speed * 3.6).toStringAsFixed(1)]),
              type: 'critical',
              eventKey: 'speed',
            );
          } else if (position.speed < 20.83 && speedAlertActive) {
            speedAlertActive = false;
            await prefs.setBool(speedAlertKey, false);
          }
        } catch (e) {
          debugPrint('Error procesando ubicación: $e');
        }
      }, onError: (Object error) async {
        debugPrint('Error en stream GPS: $error');

        // Permission withdrawn or service turned off: notify and retry on the
        // next reconciliation cycle.
        await positionSubscription?.cancel();
        positionSubscription = null;

        if (error is PermissionDeniedException) {
          await addAlert(
            purpose: 'location',
            title: tr('Permiso de ubicación retirado'),
            subtitle:
                tr('Se retiró el permiso de ubicación de Vesta Tracker en el dispositivo.'),
            type: 'critical',
            eventKey: 'location_permission_revoked',
          );
        }
      });
    }

    void startLocationServiceWatcher() {
      locationServiceSubscription ??=
          Geolocator.getServiceStatusStream().listen((status) async {
        final alerted = prefs.getBool(locationOffKey) ?? false;

        if (status == ServiceStatus.disabled && !alerted) {
          await prefs.setBool(locationOffKey, true);
          await addAlert(
            purpose: 'location',
            title: tr('Ubicación desactivada'),
            subtitle:
                tr('Se desactivó la ubicación del dispositivo. El mapa dejará de actualizarse.'),
            type: 'critical',
            eventKey: 'location_disabled',
          );
        } else if (status == ServiceStatus.enabled && alerted) {
          await prefs.setBool(locationOffKey, false);
          await addAlert(
            purpose: 'location',
            title: tr('Ubicación reactivada'),
            subtitle: tr('El dispositivo vuelve a compartir su ubicación.'),
            type: 'info',
            eventKey: 'location_enabled',
          );
        }
      }, onError: (Object error) {
        debugPrint('Error vigilando el servicio de ubicación: $error');
      });
    }

    Future<void> reconcile() async {
      if (stopped || reconciling) return;

      reconciling = true;

      try {
        final deviceAllowed = await allowed('device_status');
        final usageAllowed = await allowed('usage_stats');
        final appAllowed = await allowed('app_filtering');
        final domainAllowed = await allowed('domain_filtering');
        final locationAllowed = await allowed('location');

        if (deviceAllowed) {
          unawaited(updateBatteryStatus());
        }

        if (usageAllowed) {
          unawaited(updateUsageReport());
        }

        if (appAllowed) {
          appRulesSubscription ??= childRef
              .collection('filter_rules')
              .where('category', isEqualTo: 'app')
              .where('isEnabled', isEqualTo: true)
              .snapshots()
              .listen(
            (snapshot) => unawaited(syncAppRules(snapshot)),
            onError: (error) {
              debugPrint('Error escuchando reglas de aplicaciones: $error');
              appRulesSubscription = null;
            },
          );

          studyModeSubscription ??= childRef
              .collection('controls')
              .doc('study_mode')
              .snapshots()
              .listen(
            (snapshot) => unawaited(syncStudyMode(snapshot)),
            onError: (error) {
              debugPrint('Error escuchando modo estudio: $error');
              studyModeSubscription = null;
            },
          );

          appLimitsSubscription ??= childRef
              .collection('controls')
              .doc('app_limits')
              .snapshots()
              .listen(
            (snapshot) => unawaited(syncAppLimits(snapshot)),
            onError: (error) {
              debugPrint('Error escuchando límites diarios: $error');
              appLimitsSubscription = null;
            },
          );

          approvedRequestsSubscription ??= childRef
              .collection('requests')
              .where('status', isEqualTo: 'approved')
              .snapshots()
              .listen(
            (snapshot) => unawaited(syncApprovedRequests(snapshot)),
            onError: (error) {
              debugPrint('Error escuchando peticiones: $error');
              approvedRequestsSubscription = null;
            },
          );
        } else {
          await appRulesSubscription?.cancel();
          appRulesSubscription = null;
          await studyModeSubscription?.cancel();
          studyModeSubscription = null;
          await appLimitsSubscription?.cancel();
          appLimitsSubscription = null;
          await approvedRequestsSubscription?.cancel();
          approvedRequestsSubscription = null;
          await prefs.setString('blocked_apps_json', '[]');
          await prefs.remove('study_mode_json');
          await prefs.remove('app_limits_json');
          await prefs.remove('temporary_allow_json');
        }

        if (domainAllowed) {
          domainRulesSubscription ??= childRef
              .collection('filter_rules')
              .where('category', isEqualTo: 'url')
              .where('isEnabled', isEqualTo: true)
              .snapshots()
              .listen(
            (snapshot) => unawaited(syncDomainRules(snapshot)),
            onError: (error) {
              debugPrint('Error escuchando reglas de dominios: $error');
              domainRulesSubscription = null;
            },
          );
          webProtectionSubscription ??= childRef
              .collection('controls')
              .doc('web_protection')
              .snapshots()
              .listen(
            (snapshot) => unawaited(syncWebProtection(snapshot)),
            onError: (error) {
              debugPrint('Error escuchando protección web: $error');
              webProtectionSubscription = null;
            },
          );
        } else {
          await domainRulesSubscription?.cancel();
          domainRulesSubscription = null;
          await webProtectionSubscription?.cancel();
          webProtectionSubscription = null;
          await prefs.setString('blocked_domains_json', '[]');
          await prefs.setString('allowed_domains_json', '[]');
          await prefs.remove('web_protection_json');
        }

        if (locationAllowed) {
          zonesSubscription ??= childRef.collection('zones').snapshots().listen(
            (snapshot) {
              zones = snapshot.docs
                  .map((doc) => SafeZone.fromMap(doc.id, doc.data()))
                  .whereType<SafeZone>()
                  .toList();
            },
            onError: (error) {
              debugPrint('Error escuchando zonas: $error');
              zonesSubscription = null;
            },
          );
          startLocationServiceWatcher();
          if (positionSubscription == null) startPositionStream();
        } else {
          await positionSubscription?.cancel();
          positionSubscription = null;
          await locationServiceSubscription?.cancel();
          locationServiceSubscription = null;
          await zonesSubscription?.cancel();
          zonesSubscription = null;
          zones = [];
        }
      } finally {
        reconciling = false;
      }
    }

    Future<void> refreshAuthorization() async {
      if (stopped || refreshing) return;

      refreshing = true;

      try {
        await PrivacyAuthorizationService.refresh();
      } on DeviceUnlinkedException catch (e) {
        refreshing = false;
        await handleUnlinked(e.reason);
        return;
      } on VestaApiException catch (e) {
        // Transient: the last confirmed authorisation is kept.
        debugPrint(
          'No se pudo actualizar autorización '
          '(${e.isTransient ? 'transitorio' : 'denegado'}): $e',
        );
      } catch (e) {
        debugPrint('No se pudo actualizar autorización: $e');
      } finally {
        await PrivacyAuthorizationService.applyNativeFlags();
        refreshing = false;
      }

      await reconcile();
    }

    Future<void> onConnectivityChanged(List<ConnectivityResult> results) async {
      final connected =
          results.any((result) => result != ConnectivityResult.none);

      if (!connected) {
        if (prefs.getInt(offlineSinceKey) == null) {
          await prefs.setInt(
            offlineSinceKey,
            DateTime.now().millisecondsSinceEpoch,
          );
        }
        return;
      }

      final offlineSince = prefs.getInt(offlineSinceKey);
      await prefs.remove(offlineSinceKey);

      await refreshAuthorization();

      if (offlineSince != null) {
        final offlineFor = DateTime.now().difference(
          DateTime.fromMillisecondsSinceEpoch(offlineSince),
        );

        if (offlineFor >= _offlineAlertThreshold) {
          final minutes = offlineFor.inMinutes;
          final duration = formatOfflineDuration(minutes, english: isEnglish);

          await addAlert(
            purpose: 'device_status',
            title: tr('Dispositivo sin conexión'),
            subtitle: tr('El dispositivo estuvo sin internet durante {0}. Ya volvió a conectarse.', [duration]),
            type: offlineFor >= const Duration(hours: 2) ? 'critical' : 'warning',
            eventKey: 'offline_period',
            extra: {
              'offlineSince':
                  Timestamp.fromMillisecondsSinceEpoch(offlineSince),
              'offlineMinutes': minutes,
            },
          );
        }
      }
    }

    // The known state (with its expiry) is kept until the backend is
    // queried. Without network, local protection stays active.
    await PrivacyAuthorizationService.applyNativeFlags();
    await refreshAuthorization();
    if (stopped) return;

    batteryTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => unawaited(updateBatteryStatus()),
    );

    usageTimer = Timer.periodic(
      const Duration(minutes: 15),
      (_) => unawaited(updateUsageReport()),
    );

    authorizationTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => unawaited(refreshAuthorization()),
    );

    try {
      final initial = await Connectivity().checkConnectivity();
      if (!initial.any((result) => result != ConnectivityResult.none) &&
          prefs.getInt(offlineSinceKey) == null) {
        await prefs.setInt(
          offlineSinceKey,
          DateTime.now().millisecondsSinceEpoch,
        );
      }
    } catch (e) {
      debugPrint('Error consultando conectividad inicial: $e');
    }

    connectivitySubscription = Connectivity()
        .onConnectivityChanged
        .listen((results) => unawaited(onConnectivityChanged(results)));

    service.on('stopService').listen((event) async {
      await stopEverything();
      await PrivacyAuthorizationService.denyAll();
      await PrivacyAuthorizationService.applyNativeFlags();
      service.stopSelf();
    });
  }
}

/// "25 minutos" / "2.5 horas", or "25 minutes" / "2.5 hours" in English.
/// Same wording as Vesta Parent and the API.
String formatOfflineDuration(int minutes, {required bool english}) {
  if (minutes < 120) {
    if (english) return '$minutes ${minutes == 1 ? 'minute' : 'minutes'}';
    return '$minutes ${minutes == 1 ? 'minuto' : 'minutos'}';
  }
  final hours = (minutes / 60).toStringAsFixed(1).replaceAll('.0', '');
  return english ? '$hours hours' : '$hours horas';
}
