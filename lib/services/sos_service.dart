import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';

import 'privacy_authorization_service.dart';

import 'package:vesta_tracker/l10n/tr.dart';
enum SosResult { sent, queuedOffline, notAuthorized, failed }

/// Emergency button: creates a critical `sos` alert that the server sends
/// instantly to every guardian (even if they chose "critical only").
class SosService {
  SosService._();

  static Future<SosResult> send(String childId) async {
    if (!await PrivacyAuthorizationService.isAuthorized('alerts')) {
      return SosResult.notAuthorized;
    }

    final data = <String, dynamic>{
      'title': tr('SOS: necesita ayuda'),
      'subtitle': tr('Pulsó el botón de emergencia en su teléfono.'),
      'type': 'critical',
      'eventKey': 'sos',
      'timestamp': FieldValue.serverTimestamp(),
      'occurredAt': Timestamp.now(),
    };

    // Location is only attached if the guardians authorised it.
    if (await PrivacyAuthorizationService.isAuthorized('location')) {
      try {
        final position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 8),
          ),
        );
        data['lat'] = position.latitude;
        data['lng'] = position.longitude;
        data['accuracy'] = position.accuracy;
        data['subtitle'] =
            tr('Pulsó el botón de emergencia. Toca para ver su ubicación.');
      } catch (_) {
        final last = await Geolocator.getLastKnownPosition();
        if (last != null) {
          data['lat'] = last.latitude;
          data['lng'] = last.longitude;
          data['accuracy'] = last.accuracy;
          data['approximateLocation'] = true;
        }
      }
    }

    try {
      final write = FirebaseFirestore.instance
          .collection('children')
          .doc(childId)
          .collection('alerts')
          .add(data);
      final confirmed = await Future.any([
        write.then((_) => true),
        Future<bool>.delayed(const Duration(seconds: 6), () => false),
      ]);
      return confirmed ? SosResult.sent : SosResult.queuedOffline;
    } catch (_) {
      return SosResult.failed;
    }
  }
}
