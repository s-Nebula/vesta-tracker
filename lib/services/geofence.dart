import 'dart:math' as math;

import 'package:vesta_tracker/l10n/tr.dart';
/// Safe zone set by the guardian (`children/{id}/zones/{zoneId}`).
class SafeZone {
  final String id;
  final String name;
  final double lat;
  final double lng;
  final double radius;
  final bool notifyEnter;
  final bool notifyExit;

  const SafeZone({
    required this.id,
    required this.name,
    required this.lat,
    required this.lng,
    required this.radius,
    this.notifyEnter = true,
    this.notifyExit = true,
  });

  static SafeZone? fromMap(String id, Map<String, dynamic> data) {
    final lat = data['lat'];
    final lng = data['lng'];
    final radius = data['radius'];
    if (lat is! num || lng is! num || radius is! num) return null;
    return SafeZone(
      id: id,
      name: (data['name'] ?? tr('Zona')).toString(),
      lat: lat.toDouble(),
      lng: lng.toDouble(),
      radius: radius.toDouble().clamp(50, 5000).toDouble(),
      notifyEnter: data['notifyEnter'] != false,
      notifyExit: data['notifyExit'] != false,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'lat': lat,
        'lng': lng,
        'radius': radius,
        'notifyEnter': notifyEnter,
        'notifyExit': notifyExit,
      };
}

class ZoneTransition {
  final SafeZone zone;
  final bool entered;
  const ZoneTransition(this.zone, this.entered);
}

class Geofence {
  Geofence._();

  /// Positions with a larger error are not used to decide.
  static const double maxAccuracy = 250;

  static double distanceMeters(double lat1, double lng1, double lat2, double lng2) {
    const earth = 6371000.0;
    final dLat = _rad(lat2 - lat1);
    final dLng = _rad(lng2 - lng1);
    final a = math.pow(math.sin(dLat / 2), 2) +
        math.cos(_rad(lat1)) * math.cos(_rad(lat2)) * math.pow(math.sin(dLng / 2), 2);
    return 2 * earth * math.asin(math.sqrt(a.toDouble()));
  }

  static double _rad(double degrees) => degrees * math.pi / 180;

  /// Updates [state] (`zoneId -> 'inside' | 'outside'`) with a new position
  /// and returns the transitions that must be notified.
  ///
  /// Hysteresis: entry happens at `distance <= radius` and exit at
  /// `distance > radius + margin`, where the margin depends on accuracy.
  /// The first time a zone is seen only its state is recorded.
  static List<ZoneTransition> evaluate({
    required Map<String, String> state,
    required List<SafeZone> zones,
    required double lat,
    required double lng,
    required double accuracy,
  }) {
    if (accuracy > maxAccuracy) return const [];

    final margin = math.max(25.0, math.min(accuracy, 200.0));
    final transitions = <ZoneTransition>[];
    final ids = zones.map((z) => z.id).toSet();
    state.removeWhere((id, _) => !ids.contains(id));

    for (final zone in zones) {
      final distance = distanceMeters(lat, lng, zone.lat, zone.lng);
      final previous = state[zone.id];

      String? next;
      if (distance <= zone.radius) {
        next = 'inside';
      } else if (distance > zone.radius + margin) {
        next = 'outside';
      }
      if (next == null) continue; // hysteresis band: no change

      state[zone.id] = next;
      if (previous == null || previous == next) continue;

      final entered = next == 'inside';
      if ((entered && zone.notifyEnter) || (!entered && zone.notifyExit)) {
        transitions.add(ZoneTransition(zone, entered));
      }
    }

    return transitions;
  }
}
