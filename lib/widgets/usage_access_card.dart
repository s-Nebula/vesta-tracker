import 'package:flutter/material.dart';
import 'package:usage_stats/usage_stats.dart';

class UsageAccessCard extends StatefulWidget {
  final Future<void> Function()? onPermissionGranted;

  const UsageAccessCard({
    super.key,
    this.onPermissionGranted,
  });

  @override
  State<UsageAccessCard> createState() => _UsageAccessCardState();
}

class _UsageAccessCardState extends State<UsageAccessCard>
    with WidgetsBindingObserver {
  static const Color _surface = Color(0xFF30232B);
  static const Color _wine = Color(0xFF792D43);
  static const Color _rose = Color(0xFFC15B68);
  static const Color _ivory = Color(0xFFF4EDEA);
  static const Color _beige = Color(0xFFD6B7A6);

  bool _loading = true;
  bool _granted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkPermission();
  }

  Future<void> _checkPermission() async {
    try {
      final result = await UsageStats.checkUsagePermission() ?? false;
      if (!mounted) return;

      final shouldSync = result && (!_granted || _loading);

      setState(() {
        _granted = result;
        _loading = false;
      });

      if (shouldSync) {
        try {
          await widget.onPermissionGranted?.call();
        } catch (e) {
          debugPrint('Error sincronizando permiso de uso: $e');
        }
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkPermission();
    }
  }

  Future<void> _openSettings() async {
    try {
      await UsageStats.openUsageAccessSettings();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudieron abrir los ajustes: $e')),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final statusColor = _granted ? const Color(0xFF78C99A) : _rose;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(23),
        border: Border.all(
          color: statusColor.withValues(alpha: 0.35),
        ),
        boxShadow: [
          BoxShadow(
            color: statusColor.withValues(alpha: 0.08),
            blurRadius: 20,
            spreadRadius: 1,
          ),
        ],
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
                  gradient: const LinearGradient(
                    colors: [_wine, _rose],
                  ),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Icon(
                  _loading
                      ? Icons.hourglass_top_rounded
                      : _granted
                          ? Icons.check_circle_rounded
                          : Icons.bar_chart_rounded,
                  color: _ivory,
                  size: 25,
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _loading
                          ? 'Verificando permiso'
                          : _granted
                              ? 'Estadísticas habilitadas'
                              : 'Estadísticas de uso',
                      style: const TextStyle(
                        color: _ivory,
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: statusColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 7),
                        Text(
                          _loading
                              ? 'Comprobando estado...'
                              : _granted
                                  ? 'Permiso concedido'
                                  : 'Requiere autorización',
                          style: TextStyle(
                            color: statusColor,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            _granted
                ? 'Vesta puede recopilar tiempo de pantalla, uso por '
                    'aplicación y aperturas para generar los reportes.'
                : 'Android requiere autorización manual para consultar '
                    'el tiempo de uso de las aplicaciones.',
            style: const TextStyle(
              color: _beige,
              fontSize: 13,
              height: 1.5,
            ),
          ),
          if (!_loading && !_granted) ...[
            const SizedBox(height: 17),
            SizedBox(
              width: double.infinity,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [_wine, _rose],
                  ),
                  borderRadius: BorderRadius.circular(15),
                  boxShadow: [
                    BoxShadow(
                      color: _rose.withValues(alpha: 0.2),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: ElevatedButton.icon(
                  onPressed: _openSettings,
                  icon: const Icon(Icons.settings_rounded),
                  label: const Text('Abrir ajustes de Android'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.transparent,
                    foregroundColor: _ivory,
                    shadowColor: Colors.transparent,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(15),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
