import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/request_service.dart';

import 'package:vesta_tracker/l10n/tr.dart';
/// The minor asks their guardian for permission to use an app or for more time.
class RequestScreen extends StatefulWidget {
  final String childId;
  final String? initialPackage;
  final String? initialAppName;
  final String initialType;

  const RequestScreen({
    super.key,
    required this.childId,
    this.initialPackage,
    this.initialAppName,
    this.initialType = 'unlock_app',
  });

  @override
  State<RequestScreen> createState() => _RequestScreenState();
}

class _RequestScreenState extends State<RequestScreen> {
  static const MethodChannel _channel = MethodChannel('com.vesta.blocker/apps');

  static const Color _bg = Color(0xFF211B20);
  static const Color _card = Color(0xFF30232B);
  static const Color _rose = Color(0xFFC15B68);
  static const Color _ivory = Color(0xFFF4EDEA);
  static const Color _beige = Color(0xFFD6B7A6);

  final _message = TextEditingController();
  late String _type = widget.initialType;
  late String? _package = widget.initialPackage;
  late String? _appName = widget.initialAppName;
  int _minutes = 30;
  bool _sending = false;

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  Future<void> _pickApp() async {
    List<dynamic> apps = const [];
    try {
      apps = await _channel.invokeMethod<List<dynamic>>('getInstalledApps') ?? [];
    } catch (_) {}
    if (!mounted) return;

    final picked = await showModalBottomSheet<Map>(
      context: context,
      backgroundColor: _bg,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        builder: (context, controller) => ListView(
          controller: controller,
          children: [
            Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                tr('¿Qué aplicación quieres usar?'),
                style: TextStyle(
                  color: _ivory,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            for (final app in apps.whereType<Map>())
              ListTile(
                leading: _icon(app['iconBase64']?.toString()),
                title: Text(
                  app['name']?.toString() ?? '',
                  style: const TextStyle(color: _ivory),
                ),
                onTap: () => Navigator.pop(context, app),
              ),
          ],
        ),
      ),
    );

    if (picked != null) {
      setState(() {
        _package = picked['packageName']?.toString();
        _appName = picked['name']?.toString();
      });
    }
  }

  Widget _icon(String? base64) {
    if (base64 == null || base64.isEmpty) {
      return const Icon(Icons.android_rounded, color: _beige);
    }
    try {
      return Image.memory(base64Decode(base64), width: 34, height: 34);
    } catch (_) {
      return const Icon(Icons.android_rounded, color: _beige);
    }
  }

  Future<void> _send() async {
    final pkg = _package;
    if (pkg == null || pkg.isEmpty) return;

    setState(() => _sending = true);
    try {
      await RequestService.create(
        childId: widget.childId,
        type: _type,
        packageName: pkg,
        appName: _appName ?? pkg,
        minutes: _minutes,
        message: _message.text,
      );
      if (!mounted) return;
      _message.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('Petición enviada. Te avisaremos cuando responda.')),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('No se pudo enviar: {0}', [e]))),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        foregroundColor: _ivory,
        title: Text(tr('Pedir permiso')),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 30),
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: _card,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SegmentedButton<String>(
                  segments: [
                    ButtonSegment(
                      value: 'unlock_app',
                      label: Text(tr('Usar una app')),
                      icon: Icon(Icons.lock_open_rounded),
                    ),
                    ButtonSegment(
                      value: 'extra_time',
                      label: Text(tr('Más tiempo')),
                      icon: Icon(Icons.more_time_rounded),
                    ),
                  ],
                  selected: {_type},
                  onSelectionChanged: (value) =>
                      setState(() => _type = value.first),
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: _sending ? null : _pickApp,
                  icon: const Icon(Icons.apps_rounded),
                  label: Text(_appName ?? tr('Elegir aplicación')),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _ivory,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  tr('¿Cuánto tiempo?'),
                  style: TextStyle(color: _beige, fontSize: 13),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final minutes in const [15, 30, 60, 120])
                      ChoiceChip(
                        label: Text(minutes < 60 ? '$minutes min' : '${minutes ~/ 60} h'),
                        selected: _minutes == minutes,
                        onSelected: (_) => setState(() => _minutes = minutes),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _message,
                  maxLength: 200,
                  style: const TextStyle(color: _ivory),
                  decoration: InputDecoration(
                    labelText: tr('Mensaje para tu tutor (opcional)'),
                    labelStyle: TextStyle(color: _beige),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: _sending || _package == null ? null : _send,
                  style: FilledButton.styleFrom(
                    backgroundColor: _rose,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  icon: const Icon(Icons.send_rounded),
                  label: Text(tr('Enviar petición')),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Text(
            tr('TUS PETICIONES'),
            style: TextStyle(
              color: _beige,
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.4,
            ),
          ),
          const SizedBox(height: 8),
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: RequestService.recent(widget.childId),
            builder: (context, snapshot) {
              final docs = snapshot.data?.docs ?? [];
              if (docs.isEmpty) {
                return Text(
                  tr('Todavía no has enviado ninguna petición.'),
                  style: TextStyle(color: _beige),
                );
              }
              return Column(
                children: docs.map((doc) {
                  final data = doc.data();
                  final status = data['status']?.toString() ?? 'pending';
                  final pending = doc.metadata.hasPendingWrites;
                  final until = data['approvedUntil'];
                  final (icon, color, text) = switch (status) {
                    'approved' => (
                        Icons.check_circle_rounded,
                        const Color(0xFF72D6A0),
                        until is Timestamp
                            ? tr('Aprobada hasta las {0}:{1}', [until.toDate().hour.toString().padLeft(2, '0'), until.toDate().minute.toString().padLeft(2, '0')])
                            : tr('Aprobada'),
                      ),
                    'denied' => (
                        Icons.cancel_rounded,
                        _rose,
                        tr('Rechazada'),
                      ),
                    _ => (
                        Icons.hourglass_top_rounded,
                        _beige,
                        pending ? tr('Se enviará al tener conexión') : tr('Esperando respuesta'),
                      ),
                  };
                  return Card(
                    color: _card,
                    child: ListTile(
                      leading: Icon(icon, color: color),
                      title: Text(
                        tr('{0} · {1} min', [data['appName'] ?? data['packageName'], data['minutes']]),
                        style: const TextStyle(color: _ivory),
                      ),
                      subtitle: Text(text, style: TextStyle(color: color)),
                    ),
                  );
                }).toList(),
              );
            },
          ),
        ],
      ),
    );
  }
}
