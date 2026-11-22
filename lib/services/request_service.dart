import 'package:cloud_firestore/cloud_firestore.dart';

/// Requests from the minor to the guardian (`children/{id}/requests`).
///
/// Format validated by `validNewRequest` in the Firestore rules. The
/// guardian answers from Vesta; if approved, the background service
/// turns the answer into a temporary permission for that app.
class RequestService {
  RequestService._();

  static CollectionReference<Map<String, dynamic>> _collection(String childId) =>
      FirebaseFirestore.instance
          .collection('children')
          .doc(childId)
          .collection('requests');

  static Future<void> create({
    required String childId,
    required String type,
    required String packageName,
    required String appName,
    required int minutes,
    String? message,
  }) async {
    final trimmed = message?.trim() ?? '';
    final data = <String, dynamic>{
      'type': type == 'extra_time' ? 'extra_time' : 'unlock_app',
      'packageName': packageName,
      'appName': appName.length > 100 ? appName.substring(0, 100) : appName,
      'minutes': minutes.clamp(5, 240),
      'status': 'pending',
      'createdAt': FieldValue.serverTimestamp(),
      if (trimmed.isNotEmpty)
        'message': trimmed.length > 200 ? trimmed.substring(0, 200) : trimmed,
    };

    // Offline, the write is queued and sent on reconnection:
    // the server confirmation is not awaited.
    final write = _collection(childId).add(data);
    await Future.any([
      write,
      Future<void>.delayed(const Duration(seconds: 4)),
    ]);
  }

  static Stream<QuerySnapshot<Map<String, dynamic>>> recent(String childId) =>
      _collection(childId)
          .orderBy('createdAt', descending: true)
          .limit(20)
          .snapshots(includeMetadataChanges: true);
}
