import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/api_client.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import '../location_service.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/pairing_payload.dart';
import '../services/privacy_authorization_service.dart';
import 'qr_scan_screen.dart';

import 'package:vesta_tracker/l10n/tr.dart';
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _controller = TextEditingController();
  bool _isLoading = false;

  static const Color _background = Color(0xFF211B20);
  static const Color _surface = Color(0xFF30232B);
  static const Color _wine = Color(0xFF792D43);
  static const Color _rose = Color(0xFFC15B68);
  static const Color _ivory = Color(0xFFF4EDEA);
  static const Color _beige = Color(0xFFD6B7A6);

  Future<bool> _solicitarPermisos() async {
    final status = await Permission.location.request();
    if (!status.isGranted) return false;

    final statuses = await [
      Permission.locationAlways,
      Permission.notification,
    ].request();

    return statuses[Permission.locationAlways]?.isGranted ?? false;
  }

  Future<void> _escanearQr() async {
    if (_isLoading) return;

    final code = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const QrScanScreen()),
    );

    if (code == null || !mounted) return;

    _controller.text = code;
    await _vincular();
  }

  Future<void> _vincular() async {
    final codigo = _controller.text.trim().toUpperCase();

    if (!PairingPayload.isValidCode(codigo)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('Introduce un código válido de 10 caracteres.')),
        ),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      var user = FirebaseAuth.instance.currentUser;

      if (user == null) {
        final credential = await FirebaseAuth.instance.signInAnonymously();
        user = credential.user;
      }

      if (user == null || !user.isAnonymous) {
        throw Exception(tr('No se pudo autenticar el dispositivo.'));
      }

      // Permissions are requested before using up the single-use code.
      final permisosConcedidos = await _solicitarPermisos();

      if (!permisosConcedidos) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                tr('Es necesario permitir la ubicación \'Siempre\' para el rastreo.'),
              ),
              action: SnackBarAction(
                label: tr('Configuración'),
                onPressed: openAppSettings,
              ),
            ),
          );
        }
        return;
      }

      final result = await VestaApiClient.post(
        '/api/devices/link',
        body: {'pairingCode': codigo},
      );

      final childId = result['childId'] as String?;

      if (childId == null || childId.isEmpty) {
        throw Exception(tr('El servidor no devolvió el identificador del perfil.'));
      }

      final service = FlutterBackgroundService();
      service.invoke('stopService');
      await Future.delayed(const Duration(milliseconds: 500));

      // Start from a clean state: no rules from a previous link.
      await PrivacyAuthorizationService.clearLocalLink();

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('child_id', childId);

      await LocationService.initializeService();

      if (mounted) context.go('/success/$childId');
    } catch (e) {
      debugPrint('Error de vinculación: $e');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('No se pudo vincular: {0}', [e]))),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _background,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF211B20),
              Color(0xFF321F29),
              Color(0xFF211B20),
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(
                horizontal: 24,
                vertical: 30,
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 88,
                        height: 88,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [_wine, _rose],
                          ),
                          borderRadius: BorderRadius.circular(28),
                          boxShadow: [
                            BoxShadow(
                              color: _rose.withValues(alpha: 0.30),
                              blurRadius: 28,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Image.asset(
                            'assets/brand/vesta_simbolo.png',
                            fit: BoxFit.contain,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 25),
                    Text(
                      tr('VESTA TRACKER'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: _ivory,
                        fontSize: 27,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 2.5,
                      ),
                    ),
                    const SizedBox(height: 9),
                    Text(
                      tr('Protección y tranquilidad, siempre conectados.'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: _beige,
                        fontSize: 14,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 35),
                    Container(
                      padding: const EdgeInsets.all(23),
                      decoration: BoxDecoration(
                        color: _surface,
                        borderRadius: BorderRadius.circular(26),
                        border: Border.all(
                          color: const Color(0xFF59404A),
                        ),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x44211B20),
                            blurRadius: 24,
                            offset: Offset(0, 10),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            tr('Vincular dispositivo'),
                            style: TextStyle(
                              color: _ivory,
                              fontSize: 21,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 9),
                          Text(
                            tr('Escanea el QR que aparece en la app Vesta del tutor o introduce el código de 10 caracteres.'),
                            style: TextStyle(
                              color: _beige,
                              fontSize: 13,
                              height: 1.6,
                            ),
                          ),
                          const SizedBox(height: 25),
                          TextField(
                            controller: _controller,
                            textCapitalization: TextCapitalization.characters,
                            textAlign: TextAlign.center,
                            maxLength: 10,
                            enabled: !_isLoading,
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                RegExp(r'[A-Fa-f0-9]'),
                              ),
                              UpperCaseTextFormatter(),
                            ],
                            style: const TextStyle(
                              color: _ivory,
                              fontSize: 23,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 5,
                            ),
                            decoration: InputDecoration(
                              counterText: '',
                              hintText: 'XXXXXXXXXX',
                              hintStyle: TextStyle(
                                color: _beige.withValues(alpha: 0.45),
                                letterSpacing: 4,
                                fontSize: 17,
                              ),
                              prefixIcon: const Icon(
                                Icons.qr_code_rounded,
                                color: _rose,
                              ),
                              filled: true,
                              fillColor: _background,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 15,
                                vertical: 19,
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(17),
                                borderSide: const BorderSide(
                                  color: Color(0xFF59404A),
                                ),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(17),
                                borderSide: const BorderSide(
                                  color: _rose,
                                  width: 1.7,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 22),
                          SizedBox(
                            height: 55,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  colors: [_wine, _rose],
                                ),
                                borderRadius: BorderRadius.circular(17),
                                boxShadow: [
                                  BoxShadow(
                                    color: _rose.withValues(alpha: 0.22),
                                    blurRadius: 15,
                                    offset: const Offset(0, 5),
                                  ),
                                ],
                              ),
                              child: ElevatedButton(
                                onPressed: _isLoading ? null : _vincular,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.transparent,
                                  disabledBackgroundColor: Colors.transparent,
                                  shadowColor: Colors.transparent,
                                  foregroundColor: _ivory,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(17),
                                  ),
                                ),
                                child: _isLoading
                                    ? const SizedBox(
                                        width: 23,
                                        height: 23,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.5,
                                          color: _ivory,
                                        ),
                                      )
                                    : Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Icon(Icons.link_rounded, size: 21),
                                          SizedBox(width: 10),
                                          Text(
                                            tr('VINCULAR DISPOSITIVO'),
                                            style: TextStyle(
                                              fontWeight: FontWeight.bold,
                                              letterSpacing: 0.7,
                                            ),
                                          ),
                                        ],
                                      ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 14),
                          Row(
                            children: [
                              Expanded(
                                child: Divider(
                                  color: _beige.withValues(alpha: 0.25),
                                ),
                              ),
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 10),
                                child: Text(
                                  'o',
                                  style: TextStyle(
                                    color: _beige.withValues(alpha: 0.7),
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Divider(
                                  color: _beige.withValues(alpha: 0.25),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          SizedBox(
                            height: 52,
                            child: OutlinedButton.icon(
                              onPressed: _isLoading ? null : _escanearQr,
                              icon: const Icon(Icons.qr_code_scanner_rounded),
                              label: Text(
                                tr('ESCANEAR CÓDIGO QR'),
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.7,
                                ),
                              ),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: _ivory,
                                side: const BorderSide(color: _rose, width: 1.4),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(17),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 23),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.lock_outline_rounded,
                          color: _beige,
                          size: 15,
                        ),
                        const SizedBox(width: 7),
                        Flexible(
                          child: Text(
                            tr('Conexión protegida por Vesta'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: _beige.withValues(alpha: 0.8),
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    return newValue.copyWith(
      text: newValue.text.toUpperCase(),
      selection: newValue.selection,
    );
  }
}
