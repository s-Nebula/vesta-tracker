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
import 'services/privacy_authorization_service.dart';
import 'services/usage_report_service.dart';

@pragma('vm:entry-point')
class LocationService {
  static Future<void> initializeService() async {
    final service = FlutterBackgroundService();

    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onStart,
        isForegroundMode: true,
        autoStart: true,
        notificationChannelId: 'vesta_tracker_channel',
        initialNotificationTitle: 'Vesta Tracker',
        initialNotificationContent: 'Servicio de protección activo',
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
    final childId = prefs.getString('child_id');

    if (childId == null || childId.isEmpty) {
      await PrivacyAuthorizationService.denyAll();
      service.stopSelf();
      return;
    }

    final db = FirebaseFirestore.instance;
    final battery = Battery();

    final lowBatteryKey = 'battery_low_alerted_$childId';
    final criticalBatteryKey = 'battery_critical_alerted_$childId';
    final speedAlertKey = 'speed_alert_active_$childId';

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
    StreamSubscription<Position>? positionSubscription;

    Timer? batteryTimer;
    Timer? usageTimer;
    Timer? authorizationTimer;

    Future<bool> allowed(String purpose) async {
      return PrivacyAuthorizationService.isAuthorized(purpose);
    }

    Future<void> updateBatteryStatus() async {
      if (stopped || batteryUpdating) return;
      if (!await allowed('device_status')) return;

      batteryUpdating = true;

      try {
        final level = await battery.batteryLevel;
        final state = await battery.batteryState;

        if (!await allowed('device_status')) return;

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

        await db
            .collection('children')
            .doc(childId)
            .collection('device_status')
            .doc('current')
            .set({
          ...deviceMetadata,
          'connectivity': connection,
          'batteryLevel': level,
          'batteryState': state.name,
          'isCharging':
              state == BatteryState.charging || state == BatteryState.full,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));

        if (!await allowed('device_status') || !await allowed('alerts')) {
          return;
        }

        final lowAlerted = prefs.getBool(lowBatteryKey) ?? false;
        final criticalAlerted = prefs.getBool(criticalBatteryKey) ?? false;

        if (level <= 20 && !lowAlerted) {
          if (await allowed('device_status') && await allowed('alerts')) {
            await db
                .collection('children')
                .doc(childId)
                .collection('alerts')
                .add({
              'title': 'Batería baja',
              'subtitle': 'La batería del dispositivo está al $level%.',
              'type': 'warning',
              'timestamp': FieldValue.serverTimestamp(),
              'eventKey': 'battery_low',
            });
            await prefs.setBool(lowBatteryKey, true);
          }
        }

        if (level <= 10 && !criticalAlerted) {
          if (await allowed('device_status') && await allowed('alerts')) {
            await db
                .collection('children')
                .doc(childId)
                .collection('alerts')
                .add({
              'title': 'Batería crítica',
              'subtitle':
                  'La batería está al $level%. Conecte el dispositivo a un cargador.',
              'type': 'critical',
              'timestamp': FieldValue.serverTimestamp(),
              'eventKey': 'battery_critical',
            });
            await prefs.setBool(criticalBatteryKey, true);
          }
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

        if (!await allowed('app_filtering')) return;

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

        if (!await allowed('domain_filtering')) return;

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
          appRulesSubscription ??= db
              .collection('children')
              .doc(childId)
              .collection('filter_rules')
              .where('category', isEqualTo: 'app')
              .where('isEnabled', isEqualTo: true)
              .snapshots()
              .listen(
            (snapshot) => unawaited(syncAppRules(snapshot)),
            onError: (error) {
              debugPrint('Error escuchando reglas de aplicaciones: $error');
            },
          );
        } else {
          await appRulesSubscription?.cancel();
          appRulesSubscription = null;
          await prefs.setString('blocked_apps_json', '[]');
        }

        if (domainAllowed) {
          domainRulesSubscription ??= db
              .collection('children')
              .doc(childId)
              .collection('filter_rules')
              .where('category', isEqualTo: 'url')
              .where('isEnabled', isEqualTo: true)
              .snapshots()
              .listen(
            (snapshot) => unawaited(syncDomainRules(snapshot)),
            onError: (error) {
              debugPrint('Error escuchando reglas de dominios: $error');
            },
          );
        } else {
          await domainRulesSubscription?.cancel();
          domainRulesSubscription = null;
          await prefs.setString('blocked_domains_json', '[]');
          await prefs.setString('allowed_domains_json', '[]');
        }

        if (locationAllowed && positionSubscription == null) {
          final androidSettings = AndroidSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 5,
            intervalDuration: const Duration(seconds: 10),
            foregroundNotificationConfig: const ForegroundNotificationConfig(
              notificationText: 'Rastreo autorizado para Vesta',
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
                'speed': position.speed,
                'timestamp': FieldValue.serverTimestamp(),
                'status': 'activo',
              };

              if (!await allowed('location')) return;

              await db
                  .collection('telemetria')
                  .doc(childId)
                  .set(telemetryData, SetOptions(merge: true));

              if (!await allowed('location')) return;

              await db
                  .collection('telemetria')
                  .doc(childId)
                  .collection('historial')
                  .add(telemetryData);

              if (position.speed > 22.2 && !speedAlertActive) {
                if (await allowed('location') && await allowed('alerts')) {
                  await db
                      .collection('children')
                      .doc(childId)
                      .collection('alerts')
                      .add({
                    'title': 'Exceso de velocidad',
                    'subtitle':
                        'Velocidad detectada: ${(position.speed * 3.6).toStringAsFixed(1)} km/h',
                    'type': 'critical',
                    'timestamp': FieldValue.serverTimestamp(),
                    'eventKey': 'speed',
                  });

                  speedAlertActive = true;
                  await prefs.setBool(speedAlertKey, true);
                }
              } else if (position.speed < 20.83 && speedAlertActive) {
                speedAlertActive = false;
                await prefs.setBool(speedAlertKey, false);
              }
            } catch (e) {
              debugPrint('Error procesando ubicación: $e');
            }
          }, onError: (error) {
            debugPrint('Error en stream GPS: $error');
          });
        } else if (!locationAllowed && positionSubscription != null) {
          await positionSubscription!.cancel();
          positionSubscription = null;
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
      } catch (e) {
        debugPrint('No se pudo actualizar autorización: $e');
      } finally {
        await PrivacyAuthorizationService.applyNativeFlags();
        refreshing = false;
      }

      await reconcile();
    }

    // Estado inicial: denegar todo hasta consultar al backend.
    await PrivacyAuthorizationService.denyAll();
    await PrivacyAuthorizationService.applyNativeFlags();

    await refreshAuthorization();

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

    connectivitySubscription =
        Connectivity().onConnectivityChanged.listen((results) {
      final connected =
          results.any((result) => result != ConnectivityResult.none);

      if (connected) {
        unawaited(refreshAuthorization());
      }
    });

    service.on('stopService').listen((event) async {
      if (stopped) return;
      stopped = true;

      batteryTimer?.cancel();
      usageTimer?.cancel();
      authorizationTimer?.cancel();

      await connectivitySubscription?.cancel();
      await appRulesSubscription?.cancel();
      await domainRulesSubscription?.cancel();
      await positionSubscription?.cancel();

      await PrivacyAuthorizationService.denyAll();
      await PrivacyAuthorizationService.applyNativeFlags();

      service.stopSelf();
    });
  }
}
