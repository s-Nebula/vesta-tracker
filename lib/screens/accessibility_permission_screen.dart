import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:app_settings/app_settings.dart';
import 'package:go_router/go_router.dart';

import 'package:vesta_tracker/l10n/tr.dart';
class AccessibilityPermissionScreen extends StatefulWidget {
  final String childId;

  const AccessibilityPermissionScreen({
    super.key,
    required this.childId,
  });

  @override
  State<AccessibilityPermissionScreen> createState() =>
      _AccessibilityPermissionScreenState();
}

class _AccessibilityPermissionScreenState
    extends State<AccessibilityPermissionScreen> with WidgetsBindingObserver {
  static const Color _background = Color(0xFF211B20);
  static const Color _surface = Color(0xFF30232B);
  static const Color _wine = Color(0xFF792D43);
  static const Color _rose = Color(0xFFC15B68);
  static const Color _ivory = Color(0xFFF4EDEA);
  static const Color _beige = Color(0xFFD6B7A6);

  static const MethodChannel _channel = MethodChannel('com.vesta.blocker/apps');

  bool? _enabled;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkAccessibility();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkAccessibility();
    }
  }

  Future<void> _checkAccessibility() async {
    if (_checking) return;

    setState(() => _checking = true);

    try {
      final enabled = await _channel.invokeMethod<bool>(
        'isAccessibilityServiceEnabled',
      );

      if (mounted) {
        setState(() => _enabled = enabled ?? false);

        if (enabled == true) {
          context.go('/tracker/${widget.childId}');
        }
      }
    } on PlatformException {
      if (mounted) {
        setState(() => _enabled = null);
      }
    } finally {
      if (mounted) {
        setState(() => _checking = false);
      }
    }
  }

  Future<void> _openSettings() async {
    try {
      await AppSettings.openAppSettings(
        type: AppSettingsType.accessibility,
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('No se pudieron abrir los ajustes de Android.')),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isEnabled = _enabled == true;

    return Scaffold(
      backgroundColor: _background,
      appBar: AppBar(
        backgroundColor: _background,
        foregroundColor: _ivory,
        elevation: 0,
        automaticallyImplyLeading: false,
        title: Text(
          tr('Configurar protección'),
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 24),
              Center(
                child: Container(
                  width: 116,
                  height: 116,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _wine,
                    border: Border.all(color: _rose, width: 2),
                  ),
                  child: Icon(
                    isEnabled
                        ? Icons.verified_user_rounded
                        : Icons.security_rounded,
                    size: 62,
                    color: _rose,
                  ),
                ),
              ),
              const SizedBox(height: 28),
              Text(
                tr('Activa el servicio de accesibilidad'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _ivory,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                tr('Este paso permite que Vesta Tracker detecte cuándo se abren las aplicaciones protegidas y aplique las reglas de bloqueo configuradas desde Vesta Padre.'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _beige,
                  fontSize: 14,
                  height: 1.6,
                ),
              ),
              const SizedBox(height: 26),
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: _surface,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: _wine),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr('Cómo activarlo'),
                      style: TextStyle(
                        color: _ivory,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    SizedBox(height: 16),
                    _InstructionStep(
                      number: '1',
                      text: tr('Pulsa «Abrir ajustes de accesibilidad».'),
                    ),
                    _InstructionStep(
                      number: '2',
                      text: tr('Busca Vesta Tracker en la lista de servicios.'),
                    ),
                    _InstructionStep(
                      number: '3',
                      text: tr('Entra en Vesta Tracker y activa el interruptor.'),
                    ),
                    _InstructionStep(
                      number: '4',
                      text: tr('Confirma la activación si Android lo solicita.'),
                    ),
                    SizedBox(height: 12),
                    Text(
                      tr('Después, vuelve a esta aplicación. Comprobaremos automáticamente si el servicio quedó activado.'),
                      style: TextStyle(
                        color: _beige,
                        fontSize: 13,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: _surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: isEnabled ? Colors.green.shade700 : _wine,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      _checking
                          ? Icons.sync_rounded
                          : isEnabled
                              ? Icons.check_circle_rounded
                              : Icons.pending_actions_rounded,
                      color: _checking
                          ? _beige
                          : isEnabled
                              ? Colors.green.shade400
                              : _rose,
                      size: 25,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _checking
                            ? tr('Comprobando el servicio...')
                            : isEnabled
                                ? tr('Accesibilidad activada correctamente')
                                : _enabled == null
                                    ? tr('No se pudo comprobar el estado')
                                    : tr('Activación pendiente'),
                        style: const TextStyle(
                          color: _ivory,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                height: 54,
                child: ElevatedButton.icon(
                  onPressed: _openSettings,
                  icon: const Icon(Icons.settings_rounded),
                  label: Text(tr('Abrir ajustes de accesibilidad')),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _wine,
                    foregroundColor: _ivory,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    textStyle: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _checking ? null : _checkAccessibility,
                icon: const Icon(Icons.refresh_rounded),
                label: Text(tr('Comprobar de nuevo')),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _beige,
                  side: const BorderSide(color: _wine),
                  minimumSize: const Size.fromHeight(48),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              SizedBox(
                height: 54,
                child: ElevatedButton.icon(
                  onPressed: isEnabled && !_checking
                      ? () => context.go('/tracker/${widget.childId}')
                      : null,
                  icon: const Icon(Icons.arrow_forward_rounded),
                  label: Text(tr('CONTINUAR A VESTA TRACKER')),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _rose,
                    disabledBackgroundColor: _surface,
                    foregroundColor: _ivory,
                    disabledForegroundColor: _beige.withValues(alpha: 0.45),
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    textStyle: const TextStyle(
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                tr('Este permiso se administra desde los ajustes del sistema Android.'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _beige,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InstructionStep extends StatelessWidget {
  final String number;
  final String text;

  const _InstructionStep({
    required this.number,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 13),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 25,
            height: 25,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: Color(0xFF792D43),
              shape: BoxShape.circle,
            ),
            child: Text(
              number,
              style: const TextStyle(
                color: Color(0xFFF4EDEA),
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: Color(0xFFF4EDEA),
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
