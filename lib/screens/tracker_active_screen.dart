import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:go_router/go_router.dart';
import '../location_service.dart';
import '../widgets/usage_access_card.dart';
import '../services/usage_report_service.dart';
import '../services/privacy_authorization_service.dart';
import 'tracker_filter_service.dart';

class TrackerActiveScreen extends StatefulWidget {
  final String childId;

  const TrackerActiveScreen({super.key, required this.childId});

  @override
  State<TrackerActiveScreen> createState() => _TrackerActiveScreenState();
}

class _TrackerActiveScreenState extends State<TrackerActiveScreen> {
  bool _isLoading = true;
  bool _isNavigating = false;
  bool _locationAuthorized = false;

  final TrackerFilterService _filterService = TrackerFilterService();
  StreamSubscription<List<Map<String, dynamic>>>? _filterSubscription;
  Timer? _authorizationTimer;

  List<Map<String, dynamic>> _reglasActuales = [];

  @override
  void initState() {
    super.initState();
    _initService();
  }

  static const MethodChannel _appsChannel =
      MethodChannel('com.vesta.blocker/apps');

  Future<void> _syncInstalledApps() async {
    try {
      if (!await PrivacyAuthorizationService.isAuthorized('app_filtering'))
        return;
      final rawApps =
          await _appsChannel.invokeMethod<List<dynamic>>('getInstalledApps');

      if (rawApps == null) return;
      if (!await PrivacyAuthorizationService.isAuthorized('app_filtering'))
        return;

      final collection = FirebaseFirestore.instance
          .collection('children')
          .doc(widget.childId)
          .collection('installed_apps');

      if (!await PrivacyAuthorizationService.isAuthorized('app_filtering'))
        return;
      final existingSnapshot = await collection.get();
      if (!await PrivacyAuthorizationService.isAuthorized('app_filtering'))
        return;
      final existing = {
        for (final doc in existingSnapshot.docs) doc.id: doc.data()
      };

      final installedPackages = <String>{};
      final pending = <MapEntry<String, Map<String, dynamic>>>[];

      for (final raw in rawApps) {
        if (raw is! Map) continue;

        final packageName = (raw['packageName'] ?? '').toString().trim();
        final appName = (raw['name'] ?? '').toString().trim();
        final iconBase64 = (raw['iconBase64'] ?? '').toString();

        if (packageName.isEmpty || appName.isEmpty) continue;

        installedPackages.add(packageName);

        final previous = existing[packageName];

        if (previous == null ||
            previous['appName'] != appName ||
            previous['iconBase64'] != iconBase64 ||
            previous['isInstalled'] != true) {
          pending.add(MapEntry(packageName, {
            'packageName': packageName,
            'appName': appName,
            'iconBase64': iconBase64,
            'isInstalled': true,
            'updatedAt': FieldValue.serverTimestamp(),
          }));
        }
      }

      for (final doc in existingSnapshot.docs) {
        if (!installedPackages.contains(doc.id) &&
            doc.data()['isInstalled'] != false) {
          pending.add(MapEntry(doc.id, {
            'isInstalled': false,
            'updatedAt': FieldValue.serverTimestamp(),
          }));
        }
      }

      for (var i = 0; i < pending.length; i += 450) {
        final batch = FirebaseFirestore.instance.batch();
        final section = pending.skip(i).take(450);

        for (final entry in section) {
          batch.set(
            collection.doc(entry.key),
            entry.value,
            SetOptions(merge: true),
          );
        }

        if (!await PrivacyAuthorizationService.isAuthorized('app_filtering'))
          return;
        await batch.commit();
      }

      debugPrint(
        'Catálogo de aplicaciones sincronizado: '
        '${installedPackages.length} aplicaciones.',
      );
    } catch (e) {
      debugPrint('Error al sincronizar aplicaciones: $e');
    }
  }

  Future<void> _cargarReglasFiltro() async {
    try {
      final categories = <String>{};

      if (await PrivacyAuthorizationService.isAuthorized('app_filtering')) {
        categories.add('app');
      }
      if (await PrivacyAuthorizationService.isAuthorized('domain_filtering')) {
        categories.add('url');
      }

      await _filterSubscription?.cancel();
      _filterSubscription = null;

      if (!mounted) return;

      if (categories.isEmpty) {
        setState(() => _reglasActuales = []);
        return;
      }

      _filterSubscription = _filterService
          .obtenerReglasActivas(widget.childId, categories)
          .listen(
        (reglas) {
          if (mounted) {
            setState(() => _reglasActuales = reglas);
          }
        },
        onError: (Object error) {
          debugPrint('Error en el stream de reglas: $error');
          if (mounted) {
            setState(() => _reglasActuales = []);
          }
        },
      );
    } catch (e) {
      debugPrint('Error al cargar reglas de filtro: $e');
      await _filterSubscription?.cancel();
      _filterSubscription = null;
      if (mounted) {
        setState(() => _reglasActuales = []);
      }
    }
  }

  Future<void> _refreshScreenAuthorization() async {
    if (!mounted) return;

    var locationAuthorized = false;

    try {
      await PrivacyAuthorizationService.refresh();
      locationAuthorized =
          await PrivacyAuthorizationService.isAuthorized('location');
    } catch (e) {
      debugPrint('No se pudo renovar autorización de pantalla: $e');
    } finally {
      await PrivacyAuthorizationService.applyNativeFlags();
    }

    if (mounted) {
      setState(() => _locationAuthorized = locationAuthorized);
      await _cargarReglasFiltro();
    }
  }

  Future<void> _initService() async {
    var locationAuthorized = false;
    try {
      final service = FlutterBackgroundService();

      if (!(await service.isRunning())) {
        await LocationService.initializeService();
      }

      try {
        await PrivacyAuthorizationService.refresh();
        locationAuthorized =
            await PrivacyAuthorizationService.isAuthorized('location');
      } catch (e) {
        debugPrint('No se pudo actualizar la autorización: $e');
      } finally {
        await PrivacyAuthorizationService.applyNativeFlags();
      }

      if (await PrivacyAuthorizationService.isAuthorized('domain_filtering')) {
        try {
          await _appsChannel.invokeMethod<bool>('startDnsVpn');
        } catch (e) {
          debugPrint('No se pudo iniciar la protección DNS: $e');
        }
      } else {
        debugPrint('Protección DNS omitida: no hay autorización vigente.');
      }

      if (await PrivacyAuthorizationService.isAuthorized('app_filtering')) {
        await _syncInstalledApps();
      } else {
        debugPrint('Catálogo de aplicaciones omitido: sin autorización.');
      }
    } catch (e) {
      debugPrint('Error al inicializar: $e');
    }

    if (mounted) {
      await _cargarReglasFiltro();
      _authorizationTimer ??= Timer.periodic(
        const Duration(seconds: 60),
        (_) => _refreshScreenAuthorization(),
      );
      setState(() {
        _locationAuthorized = locationAuthorized;
        _isLoading = false;
      });
    }
  }

  Future<void> _volverAConfigurarLocalmente() async {
    if (_isNavigating) return;
    _isNavigating = true;

    try {
      await _filterSubscription?.cancel();

      // Detener la VPN antes de eliminar la sesión local.
      try {
        await _appsChannel.invokeMethod<bool>('stopDnsVpn');
      } catch (e) {
        debugPrint('No se pudo detener la VPN: $e');
      }

      final service = FlutterBackgroundService();
      service.invoke('stopService');

      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('child_id');
      await prefs.remove('parent_id');

      if (mounted) context.go('/setup');
    } catch (e) {
      debugPrint('Error al limpiar la sesión local: $e');
      _isNavigating = false;
    }
  }

  @override
  void dispose() {
    _authorizationTimer?.cancel();
    _filterSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (!_locationAuthorized) {
      return const Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'La ubicación no está autorizada. '
              'La telemetría permanecerá oculta hasta que todos los tutores '
              'autoricen este propósito.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('telemetria')
          .doc(widget.childId)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (snapshot.hasError) {
          return Scaffold(
            body: Center(
              child: Text(
                  'No se pudo consultar el estado del dispositivo: ${snapshot.error}'),
            ),
          );
        }

        if (!snapshot.hasData || !snapshot.data!.exists) {
          return const Scaffold(
            body: Center(
                child: Text('Esperando la primera señal de ubicación...')),
          );
        }

        final data = snapshot.data!.data() ?? {};
        final status = data['status'];

        if (status == 'desvinculado') {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _volverAConfigurarLocalmente();
          });

          return const Scaffold(
            body: Center(
                child: Text('El tutor ha desvinculado este dispositivo.')),
          );
        }

        return Scaffold(
          backgroundColor: const Color(0xFF211B20),
          appBar: AppBar(
            backgroundColor: const Color(0xFF211B20),
            foregroundColor: const Color(0xFFF4EDEA),
            elevation: 0,
            title: const Text('Vesta Tracker'),
          ),
          body: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 112,
                  height: 112,
                  decoration: BoxDecoration(
                    color: const Color(0xFF421827),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: const Color(0xFFC15B68),
                      width: 2,
                    ),
                  ),
                  child: const Icon(
                    Icons.my_location,
                    size: 58,
                    color: Color(0xFFC15B68),
                  ),
                ),
                const SizedBox(height: 20),
                const Text('Rastreo activo',
                    style: TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFFF4EDEA))),
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.symmetric(horizontal: 20),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF30232B),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: const Color(0xFF792D43),
                    ),
                  ),
                  child: Column(
                    children: [
                      const Icon(
                        Icons.access_time_rounded,
                        color: Color(0xFFC15B68),
                        size: 25,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'ÚLTIMA SEÑAL',
                        style: TextStyle(
                          color: Color(0xFFD6B7A6),
                          fontSize: 11,
                          letterSpacing: 1.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        data['timestamp']?.toDate()?.toString() ??
                            'Recibiendo...',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Color(0xFFF4EDEA),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                UsageAccessCard(
                  onPermissionGranted: () async {
                    // Primera recopilación: inmediatamente al conceder el permiso.
                    await UsageReportService.collectDailyReport(
                      childId: widget.childId,
                      db: FirebaseFirestore.instance,
                    );

                    // Segundo intento: permite recoger eventos que Android
                    // todavía estuviera terminando de actualizar.
                    await Future<void>.delayed(
                      const Duration(seconds: 5),
                    );
                    await UsageReportService.collectDailyReport(
                      childId: widget.childId,
                      db: FirebaseFirestore.instance,
                    );
                  },
                ),
                const SizedBox(height: 12),
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 20),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 16,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF30232B),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: const Color(0xFF792D43),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.shield_outlined,
                        color: Color(0xFFC15B68),
                        size: 27,
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Text(
                          'Filtros de protección sincronizados',
                          style: TextStyle(
                            color: Color(0xFFF4EDEA),
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      Container(
                        constraints: const BoxConstraints(
                          minWidth: 42,
                          minHeight: 42,
                        ),
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF421827),
                          borderRadius: BorderRadius.circular(13),
                          border: Border.all(
                            color: const Color(0xFFC15B68),
                          ),
                        ),
                        child: Text(
                          '${_reglasActuales.length}',
                          style: const TextStyle(
                            color: Color(0xFFF4EDEA),
                            fontSize: 19,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
