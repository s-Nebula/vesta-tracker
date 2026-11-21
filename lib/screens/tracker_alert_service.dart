import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

class TrackerAlertService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  Future<void> registrarAlertaBloqueo({
    required String childId,
    required String urlIntentada,
  }) async {
    try {
      await _firestore
          .collection('children')
          .doc(childId)
          .collection('alerts')
          .add({
        'title': 'Acceso Bloqueado',
        'subtitle': 'Intentó acceder a: $urlIntentada',
        'type': 'critical',
        'timestamp': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error al registrar alerta de bloqueo: $e');
      }
    }
  }
}
