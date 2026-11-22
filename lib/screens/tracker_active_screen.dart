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
import '../services/api_client.dart';
import '../services/privacy_authorization_service.dart';
import '../services/study_mode_state.dart';
import '../services/sos_service.dart';
import 'request_screen.dart';
import 'transparency_screen.dart';
import 'tracker_filter_service.dart';

import 'package:vesta_tracker/l10n/tr.dart';
class TrackerActiveScreen extends StatefulWidget {
  final String childId;

  const TrackerActiveScreen({super.key, required this.childId});

  @override
  State<TrackerActiveScreen> createState() => _TrackerActiveScreenState();
}

class _TrackerActiveScreenState extends State<TrackerActiveScreen>
    with WidgetsBindingObserver {
  bool _isLoading = true;
  bool _isNavigating = false;
  bool _offline = false;
  bool _locationAuthorized = false;
  bool _appFilteringAuthorized = false;
  bool _domainFilteringAuthorized = false;
  DateTime? _lastVerifiedAt;
  StudyModeState _studyMode = StudyModeState.inactive;
  Stream<DocumentSnapshot<Map<String, dynamic>>>? _telemetryStream;
  StreamSubscription<Map<String, dynamic>?>? _unlinkSubscription;
  Timer? _clockTimer;

  final TrackerFilterService _filterService = TrackerFilterService();
  StreamSubscription<List<Map<String, dynamic>>>? _filterSubscription;
  Timer? _authorizationTimer;

  List<Map<String, dynamic>> _reglasActuales = [];

  bool _sendingSos = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initService();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _openPendingRequest();
      _reloadLocalState();
    }
  }

  /// If the app was opened from the "App blocked" notice, open the request.
  Future<void> _openPendingRequest() async {
    try {
      final request =
          await _appsChannel.invokeMapMethod<String, dynamic>('consumePendingRequest');
      if (request == null || !mounted || _isNavigating) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => RequestScreen(
          childId: widget.childId,
          initialPackage: request['packageName']?.toString(),
          initialAppName: request['appName']?.toString(),
          initialType: request['type']?.toString() ?? 'unlock_app',
        ),
      ));
    } catch (e) {
      debugPrint('No se pudo leer la petición pendiente: $e');
    }
  }

  Future<void> _sendSos() async {
    if (_sendingSos) return;
    setState(() => _sendingSos = true);
    final result = await SosService.send(widget.childId);
    if (!mounted) return;
    setState(() => _sendingSos = false);

    final message = switch (result) {
      SosResult.sent => tr('Aviso de emergencia enviado a tus tutores.'),
      SosResult.queuedOffline =>
        tr('No hay conexión: el aviso se enviará en cuanto vuelva internet. Si es urgente, llama al 123 o a tus tutores.'),
      SosResult.notAuthorized =>
        tr('Los avisos no están autorizados en este teléfono. Si es urgente, llama al 123 o a tus tutores.'),
      SosResult.failed =>
        tr('No se pudo enviar el aviso. Si es urgente, llama al 123.'),
    };

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(
          result == SosResult.sent ? Icons.check_circle_rounded : Icons.warning_rounded,
          color: result == SosResult.sent ? _green : _amber,
          size: 40,
        ),
        title: const Text('SOS'),
        content: Text(message),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(tr('Entendido')),
          ),
        ],
      ),
    );
  }

  static const MethodChannel _appsChannel =
      MethodChannel('com.vesta.blocker/apps');

  Future<void> _syncInstalledApps() async {
    try {
      if (!await PrivacyAuthorizationService.isAuthorized('app_filtering')) {
        return;
        }
      final rawApps =
          await _appsChannel.invokeMethod<List<dynamic>>('getInstalledApps');

      if (rawApps == null) return;
      if (!await PrivacyAuthorizationService.isAuthorized('app_filtering')) {
        return;
        }

      final collection = FirebaseFirestore.instance
          .collection('children')
          .doc(widget.childId)
          .collection('installed_apps');

      if (!await PrivacyAuthorizationService.isAuthorized('app_filtering')) {
        return;
        }
      final existingSnapshot = await collection.get();
      if (!await PrivacyAuthorizationService.isAuthorized('app_filtering')) {
        return;
        }
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

        if (!await PrivacyAuthorizationService.isAuthorized('app_filtering')) {
          return;
          }
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

  Future<void> _refreshScreenAuthorization({bool initial = false}) async {
    if (!mounted || _isNavigating) return;

    try {
      await PrivacyAuthorizationService.refresh();
      if (mounted) setState(() => _offline = false);
    } on DeviceUnlinkedException catch (e) {
      debugPrint('Dispositivo desvinculado: $e');
      await _volverAConfigurarLocalmente(unlinkedByGuardian: true);
      return;
    } on VestaApiException catch (e) {
      debugPrint('No se pudo renovar autorización de pantalla: $e');
      if (mounted) setState(() => _offline = e.isTransient);
    } catch (e) {
      debugPrint('No se pudo renovar autorización de pantalla: $e');
    } finally {
      await PrivacyAuthorizationService.applyNativeFlags();
    }

    await _reloadLocalState();
    if (!initial) await _cargarReglasFiltro();
  }

  /// Reads the state shared by the UI, the background service and Kotlin.
  Future<void> _reloadLocalState() async {
    final location =
        await PrivacyAuthorizationService.isAuthorized('location');
    final apps =
        await PrivacyAuthorizationService.isAuthorized('app_filtering');
    final domains =
        await PrivacyAuthorizationService.isAuthorized('domain_filtering');
    final verifiedAt = await PrivacyAuthorizationService.lastVerifiedAt();

    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final study = StudyModeState.fromJson(prefs.getString('study_mode_json'));

    if (!mounted) return;
    setState(() {
      _locationAuthorized = location;
      _appFilteringAuthorized = apps;
      _domainFilteringAuthorized = domains;
      _lastVerifiedAt = verifiedAt;
      _studyMode = apps ? study : StudyModeState.inactive;
    });
  }

  Future<void> _initService() async {
    try {
      final service = FlutterBackgroundService();

      _unlinkSubscription = service
          .on(LocationService.deviceUnlinkedEvent)
          .listen((_) => _volverAConfigurarLocalmente(unlinkedByGuardian: true));

      if (!(await service.isRunning())) {
        await LocationService.initializeService();
      }

      await _refreshScreenAuthorization(initial: true);
      if (_isNavigating) return;

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
        unawaited(_syncInstalledApps());
      } else {
        debugPrint('Catálogo de aplicaciones omitido: sin autorización.');
      }
    } catch (e) {
      debugPrint('Error al inicializar: $e');
    }

    if (mounted && !_isNavigating) {
      await _cargarReglasFiltro();
      _authorizationTimer ??= Timer.periodic(
        const Duration(seconds: 60),
        (_) => _refreshScreenAuthorization(),
      );
      // Study mode can start or end by schedule without anything changing
      // on the server: it is re-evaluated every 30 s.
      _clockTimer ??= Timer.periodic(
        const Duration(seconds: 30),
        (_) => _reloadLocalState(),
      );
      setState(() => _isLoading = false);
      unawaited(_openPendingRequest());
    }
  }

  Future<void> _volverAConfigurarLocalmente({
    bool unlinkedByGuardian = false,
  }) async {
    if (_isNavigating) return;
    _isNavigating = true;

    try {
      _authorizationTimer?.cancel();
      _clockTimer?.cancel();
      await _filterSubscription?.cancel();

      // Stop the VPN before deleting the local session.
      try {
        await _appsChannel.invokeMethod<bool>('stopDnsVpn');
      } catch (e) {
        debugPrint('No se pudo detener la VPN: $e');
      }

      FlutterBackgroundService().invoke('stopService');
      await PrivacyAuthorizationService.clearLocalLink();
      await PrivacyAuthorizationService.applyNativeFlags();

      if (!mounted) return;

      if (unlinkedByGuardian) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr('El tutor desvinculó este dispositivo. Puedes vincularlo de nuevo con un código nuevo.'),
            ),
          ),
        );
      }

      context.go('/setup');
    } catch (e) {
      debugPrint('Error al limpiar la sesión local: $e');
      _isNavigating = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _authorizationTimer?.cancel();
    _clockTimer?.cancel();
    _filterSubscription?.cancel();
    _unlinkSubscription?.cancel();
    super.dispose();
  }

  static const Color _bg = Color(0xFF211B20);
  static const Color _card = Color(0xFF30232B);
  static const Color _border = Color(0xFF792D43);
  static const Color _rose = Color(0xFFC15B68);
  static const Color _ivory = Color(0xFFF4EDEA);
  static const Color _beige = Color(0xFFD6B7A6);
  static const Color _green = Color(0xFF72D6A0);
  static const Color _amber = Color(0xFFE3B341);

  String _formatTime(DateTime? date) {
    if (date == null) return tr('Sin datos');
    final local = date.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    final dd = local.day.toString().padLeft(2, '0');
    final mo = local.month.toString().padLeft(2, '0');
    return '$dd/$mo · $hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        backgroundColor: _bg,
        body: Center(child: CircularProgressIndicator(color: _rose)),
      );
    }

    final study = _studyMode;
    final studyActive = study.isActiveAt(DateTime.now());

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        foregroundColor: _ivory,
        elevation: 0,
        title: const Text('Vesta Tracker'),
      ),
      body: RefreshIndicator(
        color: _rose,
        onRefresh: _refreshScreenAuthorization,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 30),
          children: [
            if (studyActive) ...[
              _studyBanner(study),
              const SizedBox(height: 14),
            ],
            _sosButton(),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: _actionButton(
                    Icons.front_hand_rounded,
                    tr('Pedir permiso'),
                    () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => RequestScreen(childId: widget.childId),
                    )),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _actionButton(
                    Icons.visibility_rounded,
                    tr('Qué comparte Vesta'),
                    () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const TransparencyScreen(),
                    )),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _protectionCard(),
            const SizedBox(height: 14),
            _locationCard(),
            const SizedBox(height: 14),
            UsageAccessCard(
              onPermissionGranted: () async {
                // First collection: right after the permission is granted.
                await UsageReportService.collectDailyReport(
                  childId: widget.childId,
                  db: FirebaseFirestore.instance,
                );

                // Second attempt: picks up events Android may still have
                // been finishing updating.
                await Future<void>.delayed(const Duration(seconds: 5));
                await UsageReportService.collectDailyReport(
                  childId: widget.childId,
                  db: FirebaseFirestore.instance,
                );
              },
            ),
            const SizedBox(height: 12),
            _filtersCard(),
          ],
        ),
      ),
    );
  }

  Widget _sosButton() {
    return Material(
      color: const Color(0xFFB3261E),
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        // Press and hold avoids accidental sends from a pocket.
        onLongPress: _sendingSos ? null : _sendSos,
        onTap: () => ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('Mantén pulsado el botón para enviar el aviso SOS.')),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 20),
          child: Row(
            children: [
              _sendingSos
                  ? const SizedBox(
                      width: 34,
                      height: 34,
                      child: CircularProgressIndicator(color: Colors.white),
                    )
                  : const Icon(Icons.sos_rounded, color: Colors.white, size: 38),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr('Emergencia'),
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Text(
                      tr('Mantén pulsado para avisar a tus tutores con tu ubicación'),
                      style: TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _actionButton(IconData icon, String label, VoidCallback onTap) {
    return Material(
      color: _card,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: _border),
          ),
          child: Column(
            children: [
              Icon(icon, color: _rose, size: 28),
              const SizedBox(height: 8),
              Text(
                label,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: _ivory,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  BoxDecoration get _cardDecoration => BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _border),
      );

  Widget _studyBanner(StudyModeState study) {
    final until = study.currentEnd(DateTime.now());

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Color(0xFF3B5BA5), _rose]),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          const Icon(Icons.menu_book_rounded, color: Colors.white, size: 34),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr('Modo estudio activo'),
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  until == null
                      ? tr('Solo están disponibles las apps permitidas por tu tutor.')
                      : tr('Hasta las {0}:{1}. Solo están disponibles las apps permitidas.', [until.hour.toString().padLeft(2, '0'), until.minute.toString().padLeft(2, '0')]),
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusRow(IconData icon, String label, bool ok, {String? okText}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: _beige),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label, style: const TextStyle(color: _ivory)),
          ),
          Text(
            ok ? (okText ?? tr('Activo')) : tr('No autorizado'),
            style: TextStyle(
              color: ok ? _green : _beige.withValues(alpha: 0.7),
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _protectionCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _cardDecoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _offline ? Icons.cloud_off_rounded : Icons.verified_user_rounded,
                color: _offline ? _amber : _rose,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _offline ? tr('Protección sin conexión') : tr('Protección activa'),
                  style: const TextStyle(
                    color: _ivory,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _offline
                ? tr('Se mantienen las últimas reglas recibidas. Última verificación: {0}.', [_formatTime(_lastVerifiedAt)])
                : tr('Última verificación: {0}.', [_formatTime(_lastVerifiedAt)]),
            style: TextStyle(color: _beige.withValues(alpha: 0.9), fontSize: 12),
          ),
          const Divider(color: _border, height: 22),
          _statusRow(Icons.my_location_rounded, tr('Ubicación'), _locationAuthorized),
          _statusRow(
            Icons.apps_rounded,
            tr('Control de aplicaciones'),
            _appFilteringAuthorized,
          ),
          _statusRow(
            Icons.dns_rounded,
            tr('Filtro de sitios web'),
            _domainFilteringAuthorized,
          ),
        ],
      ),
    );
  }

  Widget _locationCard() {
    if (!_locationAuthorized) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: _cardDecoration,
        child: Text(
          tr('La ubicación no está autorizada. No se comparte hasta que todos los tutores autoricen este propósito.'),
          style: TextStyle(color: _beige, fontSize: 12, height: 1.5),
        ),
      );
    }

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _telemetryStream ??= FirebaseFirestore.instance
          .collection('telemetria')
          .doc(widget.childId)
          .snapshots(includeMetadataChanges: true),
      builder: (context, snapshot) {
        final data = snapshot.data?.data();
        final pending = snapshot.data?.metadata.hasPendingWrites ?? false;
        final captured = data?['capturedAt'];
        final server = data?['timestamp'];
        final date = captured is Timestamp
            ? captured.toDate()
            : server is Timestamp
                ? server.toDate()
                : null;

        return Container(
          padding: const EdgeInsets.all(16),
          decoration: _cardDecoration,
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: const Color(0xFF421827),
                  shape: BoxShape.circle,
                  border: Border.all(color: _rose, width: 2),
                ),
                child: const Icon(Icons.my_location, color: _rose, size: 26),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr('ÚLTIMA SEÑAL'),
                      style: TextStyle(
                        color: _beige,
                        fontSize: 12,
                        letterSpacing: 1.5,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      snapshot.hasError
                          ? tr('No disponible')
                          : date == null
                              ? tr('Esperando la primera señal...')
                              : _formatTime(date),
                      style: const TextStyle(color: _ivory, fontSize: 15),
                    ),
                    if (pending)
                      Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: Text(
                          tr('Pendiente de enviar (sin conexión)'),
                          style: TextStyle(color: _amber, fontSize: 12),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _filtersCard() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: _cardDecoration,
      child: Row(
        children: [
          const Icon(Icons.shield_outlined, color: _rose, size: 27),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              tr('Filtros de protección sincronizados'),
              style: TextStyle(
                color: _ivory,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
          Container(
            constraints: const BoxConstraints(minWidth: 42, minHeight: 42),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF421827),
              borderRadius: BorderRadius.circular(13),
              border: Border.all(color: _rose),
            ),
            child: Text(
              '${_reglasActuales.length}',
              style: const TextStyle(
                color: _ivory,
                fontSize: 19,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
