import 'package:flutter/material.dart';

import '../services/privacy_authorization_service.dart';

import 'package:vesta_tracker/l10n/tr.dart';
/// Explains to the minor, in plain language, what Vesta shares with their guardians.
///
/// Each purpose is only active if ALL their guardians authorised it, and it is
/// shown here in real time. It is part of Vesta's privacy approach:
/// the minor has the right to know what is collected about them.
class TransparencyScreen extends StatefulWidget {
  const TransparencyScreen({super.key});

  @override
  State<TransparencyScreen> createState() => _TransparencyScreenState();
}

class _Purpose {
  final String key;
  final IconData icon;
  final String title;
  final String shares;
  final String notShared;

  const _Purpose(this.key, this.icon, this.title, this.shares, this.notShared);
}

class _TransparencyScreenState extends State<TransparencyScreen> {
  static const Color _bg = Color(0xFF211B20);
  static const Color _card = Color(0xFF30232B);
  static const Color _ivory = Color(0xFFF4EDEA);
  static const Color _beige = Color(0xFFD6B7A6);
  static const Color _green = Color(0xFF72D6A0);

  static List<_Purpose> get _purposes => [
    _Purpose(
      'location',
      Icons.my_location_rounded,
      tr('Ubicación'),
      tr('Dónde está el teléfono, cada pocos metros, y avisos cuando llegas o sales de las zonas que marcaron tus tutores (casa, colegio...).'),
      tr('No se graba audio ni imagen.'),
    ),
    _Purpose(
      'device_status',
      Icons.battery_charging_full_rounded,
      tr('Estado del teléfono'),
      tr('Batería, tipo de conexión y modelo del teléfono, para saber si está encendido y conectado.'),
      tr('No se comparten tus fotos, archivos ni contactos.'),
    ),
    _Purpose(
      'usage_stats',
      Icons.bar_chart_rounded,
      tr('Tiempo de uso'),
      tr('Cuánto tiempo usas cada aplicación al día.'),
      tr('No se ve lo que haces dentro de las apps ni tus mensajes.'),
    ),
    _Purpose(
      'app_filtering',
      Icons.apps_rounded,
      tr('Control de aplicaciones'),
      tr('Qué apps tienes instaladas, para poder bloquear algunas, poner límites de tiempo o activar el modo estudio.'),
      tr('Siempre puedes pedir permiso desde "Pedir permiso".'),
    ),
    _Purpose(
      'domain_filtering',
      Icons.public_rounded,
      tr('Filtro de sitios web'),
      tr('Se bloquean las webs que tus tutores marcaron y se activa la búsqueda segura. Si intentas abrir una web bloqueada, se les avisa.'),
      tr('No se guarda tu historial de navegación.'),
    ),
    _Purpose(
      'alerts',
      Icons.notifications_active_rounded,
      tr('Avisos'),
      tr('Avisos importantes: batería baja, botón SOS, apps bloqueadas o si se desactiva la protección.'),
      tr('Tus tutores no reciben tus notificaciones ni tus conversaciones.'),
    ),
  ];

  Map<String, bool>? _status;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final status = <String, bool>{};
    for (final purpose in _purposes) {
      status[purpose.key] =
          await PrivacyAuthorizationService.isAuthorized(purpose.key);
    }
    if (mounted) setState(() => _status = status);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        foregroundColor: _ivory,
        title: Text(tr('Qué comparte Vesta')),
      ),
      body: _status == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 30),
              children: [
                Text(
                  tr('Tus tutores usan Vesta para cuidarte. Aquí puedes ver exactamente qué información reciben. Cada punto solo está activo si todos tus tutores lo autorizaron.'),
                  style: TextStyle(color: _beige, fontSize: 14, height: 1.5),
                ),
                const SizedBox(height: 18),
                for (final purpose in _purposes) _purposeCard(purpose),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: _card,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Text(
                    tr('¿Algo no te parece bien? Habla con tus tutores. También puedes pedir permiso para usar una app o más tiempo, y en una emergencia pulsa el botón SOS.'),
                    style: TextStyle(color: _ivory, fontSize: 14, height: 1.5),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _purposeCard(_Purpose purpose) {
    final active = _status![purpose.key] == true;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: active ? _green.withValues(alpha: 0.4) : Colors.transparent,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(purpose.icon, color: active ? _green : _beige),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  purpose.title,
                  style: const TextStyle(
                    color: _ivory,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Text(
                active ? tr('Activo') : tr('Desactivado'),
                style: TextStyle(
                  color: active ? _green : _beige,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            purpose.shares,
            style: const TextStyle(color: _ivory, fontSize: 13, height: 1.45),
          ),
          const SizedBox(height: 6),
          Text(
            purpose.notShared,
            style: const TextStyle(color: _beige, fontSize: 12, height: 1.4),
          ),
        ],
      ),
    );
  }
}
