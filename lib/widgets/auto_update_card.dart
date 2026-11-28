import 'package:flutter/material.dart';
import 'package:vesta_tracker/services/app_updater.dart';

import 'package:vesta_tracker/l10n/tr.dart';

/// Asks once for Android's "install unknown apps" permission so Vesta
/// Tracker can update itself. Only in the APK from vestasecurity.date, and
/// only while the permission is missing; otherwise it shows nothing.
class AutoUpdateCard extends StatefulWidget {
  const AutoUpdateCard({super.key});

  @override
  State<AutoUpdateCard> createState() => _AutoUpdateCardState();
}

class _AutoUpdateCardState extends State<AutoUpdateCard>
    with WidgetsBindingObserver {
  static const Color _surface = Color(0xFF30232B);
  static const Color _wine = Color(0xFF792D43);
  static const Color _rose = Color(0xFFC15B68);
  static const Color _ivory = Color(0xFFF4EDEA);
  static const Color _beige = Color(0xFFD6B7A6);

  UpdateStatus? _status;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final before = _status;
    final status = await AppUpdater.status();
    if (!mounted) return;
    setState(() => _status = status);
    // Just allowed: install a pending update straight away.
    if (before != null && !before.canInstall && status.canInstall) {
      final checked = await AppUpdater.checkNow();
      if (mounted) setState(() => _status = checked);
    }
  }

  Future<void> _allow() async {
    try {
      await AppUpdater.openInstallSettings();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('No se pudieron abrir los ajustes: {0}', [e]))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _status;
    if (s == null || !s.supported || s.canInstall) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(23),
        border: Border.all(color: _rose.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(colors: [_wine, _rose]),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: const Icon(Icons.system_update_rounded, color: _ivory, size: 25),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Text(
                  s.available
                      ? tr('Actualización {0} pendiente', [s.availableVersionName ?? ''])
                      : tr('Actualizaciones automáticas'),
                  style: const TextStyle(
                    color: _ivory,
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            tr('Permite una vez que Vesta Tracker instale sus actualizaciones. Así se mantiene al día sin que tengas que descargar nada.'),
            style: const TextStyle(color: _beige, fontSize: 13, height: 1.5),
          ),
          const SizedBox(height: 17),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _allow,
              icon: const Icon(Icons.settings_rounded),
              label: Text(tr('Permitir')),
              style: ElevatedButton.styleFrom(
                backgroundColor: _wine,
                foregroundColor: _ivory,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(15),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
