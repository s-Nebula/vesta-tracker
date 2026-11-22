import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:vesta_tracker/l10n/tr.dart';
class ReportService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Future<Map<String, dynamic>> generarReporteDiario(String childId, DateTime dia) async {
    DateTime inicioDia = DateTime(dia.year, dia.month, dia.day);
    DateTime finDia = inicioDia.add(const Duration(days: 1));

    QuerySnapshot snapshot = await _db
        .collection('telemetria')
        .doc(childId)
        .collection('historial')
        .where('timestamp', isGreaterThanOrEqualTo: inicioDia)
        .where('timestamp', isLessThan: finDia)
        .get();

    int totalPuntos = snapshot.docs.length;

    return {
      'totalRegistros': totalPuntos,
      'fecha': inicioDia,
    };
  }
}

class ReportScreen extends StatefulWidget {
  final String childId;
  const ReportScreen({super.key, required this.childId});

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  final ReportService _reportService = ReportService();
  DateTime _selectedDate = DateTime.now();
  late Future<Map<String, dynamic>> _reportFuture;

  static const Color _background = Color(0xFF211B20);
  static const Color _surface = Color(0xFF30232B);
  static const Color _wine = Color(0xFF792D43);
  static const Color _rose = Color(0xFFC15B68);
  static const Color _ivory = Color(0xFFF4EDEA);
  static const Color _beige = Color(0xFFD6B7A6);

  @override
  void initState() {
    super.initState();
    _loadReport();
  }

  void _loadReport() {
    _reportFuture = _reportService.generarReporteDiario(
      widget.childId,
      _selectedDate,
    );
  }

  Future<void> _selectDate(BuildContext context) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2023),
      lastDate: DateTime.now(),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.dark(
              primary: _rose,
              surface: _surface,
              onSurface: _ivory,
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null && picked != _selectedDate) {
      setState(() {
        _selectedDate = picked;
        _loadReport();
      });
    }
  }

  String get _formattedDate =>
      '${_selectedDate.day.toString().padLeft(2, '0')}/'
      '${_selectedDate.month.toString().padLeft(2, '0')}/'
      '${_selectedDate.year}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _background,
      appBar: AppBar(
        backgroundColor: _background,
        foregroundColor: _ivory,
        elevation: 0,
        title: Text(
          tr('Reporte de actividad'),
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: _surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: _wine),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.calendar_month_rounded,
                    color: _rose,
                    size: 28,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          tr('FECHA DEL REPORTE'),
                          style: TextStyle(
                            color: _beige,
                            fontSize: 12,
                            letterSpacing: 1.3,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          _formattedDate,
                          style: const TextStyle(
                            color: _ivory,
                            fontSize: 19,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => _selectDate(context),
                    tooltip: tr('Cambiar fecha'),
                    style: IconButton.styleFrom(
                      backgroundColor: _wine,
                      foregroundColor: _ivory,
                    ),
                    icon: const Icon(Icons.edit_calendar_rounded),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Text(
              tr('Resumen diario'),
              style: TextStyle(
                color: _ivory,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 14),
            Expanded(
              child: FutureBuilder<Map<String, dynamic>>(
                future: _reportFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(
                      child: CircularProgressIndicator(color: _rose),
                    );
                  }

                  if (snapshot.hasError) {
                    return Center(
                      child: Text(
                        tr('Error al cargar reporte: {0}', [snapshot.error]),
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: _beige),
                      ),
                    );
                  }

                  if (!snapshot.hasData) {
                    return Center(
                      child: Text(
                        tr('No hay datos disponibles.'),
                        style: TextStyle(color: _beige),
                      ),
                    );
                  }

                  final data = snapshot.data!;
                  final int totalRegistros = data['totalRegistros'] ?? 0;
                  final bool hasActivity = totalRegistros > 0;

                  return ListView(
                    children: [
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
                            Row(
                              children: [
                                Icon(
                                  Icons.location_on_rounded,
                                  color: _rose,
                                  size: 23,
                                ),
                                SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    tr('Registros de ubicación'),
                                    style: TextStyle(
                                      color: _ivory,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 18),
                            Text(
                              '$totalRegistros',
                              style: const TextStyle(
                                color: _ivory,
                                fontSize: 38,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              tr('Puntos registrados durante el día'),
                              style: TextStyle(
                                color: _beige,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          color: _surface,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: _wine),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 46,
                              height: 46,
                              decoration: BoxDecoration(
                                color: _wine,
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Icon(
                                hasActivity
                                    ? Icons.check_circle_outline_rounded
                                    : Icons.hourglass_empty_rounded,
                                color: _rose,
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    tr('Estado del rastreo'),
                                    style: TextStyle(
                                      color: _ivory,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(height: 5),
                                  Text(
                                    hasActivity
                                        ? tr('Activo durante el día')
                                        : tr('Sin actividad registrada'),
                                    style: const TextStyle(
                                      color: _beige,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Icon(
                              hasActivity
                                  ? Icons.circle
                                  : Icons.circle_outlined,
                              color: hasActivity ? _rose : _beige,
                              size: 12,
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
