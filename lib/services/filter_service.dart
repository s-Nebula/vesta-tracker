import 'package:cloud_firestore/cloud_firestore.dart';

class FilterService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Stream<QuerySnapshot> getTelemetryByDateRange(
    String childId, 
    DateTime startDate, 
    DateTime endDate
  ) {
    return _db
        .collection('telemetria')
        .doc(childId)
        .collection('historial') // Opcional: si guardas un subhistorial de puntos
        .where('timestamp', isGreaterThanOrEqualTo: startDate)
        .where('timestamp', isLessThanOrEqualTo: endDate)
        .orderBy('timestamp', descending: true)
        .snapshots();
  }

  Stream<QuerySnapshot> getTelemetryByStatus(String childId, String statusFilter) {
    return _db
        .collection('telemetria')
        .where('childId', isEqualTo: childId)
        .where('status', isEqualTo: statusFilter)
        .snapshots();
  }
}