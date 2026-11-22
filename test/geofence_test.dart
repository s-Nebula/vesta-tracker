import 'package:flutter_test/flutter_test.dart';
import 'package:vesta_tracker/services/geofence.dart';
import 'package:vesta_tracker/l10n/tr.dart';

void main() {
  // The tests check the Spanish texts.
  setUpAll(() => debugSetAppLanguage('es'));

  const home = SafeZone(id: 'home', name: 'Casa', lat: 11.24, lng: -74.2, radius: 150);
  // ~0.001° de latitud ≈ 111 m.
  double north(double meters) => 11.24 + meters / 111195;

  List<ZoneTransition> step(Map<String, String> state, double meters,
          {double accuracy = 10}) =>
      Geofence.evaluate(
        state: state,
        zones: const [home],
        lat: north(meters),
        lng: -74.2,
        accuracy: accuracy,
      );

  test('distancia aproximada', () {
    expect(Geofence.distanceMeters(11.24, -74.2, north(100), -74.2),
        closeTo(100, 1));
  });

  test('la primera posición solo registra el estado', () {
    final state = <String, String>{};
    expect(step(state, 0), isEmpty);
    expect(state['home'], 'inside');
  });

  test('salida y llegada con histéresis', () {
    final state = <String, String>{'home': 'inside'};
    // Just outside the radius but inside the margin: no exit.
    expect(step(state, 160), isEmpty);
    expect(state['home'], 'inside');

    final exit = step(state, 400);
    expect(exit, hasLength(1));
    expect(exit.first.entered, isFalse);

    final enter = step(state, 20);
    expect(enter.single.entered, isTrue);
    expect(step(state, 30), isEmpty);
  });

  test('ignora posiciones imprecisas', () {
    final state = <String, String>{'home': 'inside'};
    expect(step(state, 2000, accuracy: 900), isEmpty);
    expect(state['home'], 'inside');
  });

  test('respeta notifyEnter/notifyExit y limpia zonas borradas', () {
    const school = SafeZone(
      id: 'school', name: 'Colegio', lat: 11.24, lng: -74.2, radius: 100,
      notifyEnter: false,
    );
    final state = <String, String>{'school': 'outside', 'deleted': 'inside'};
    final result = Geofence.evaluate(
      state: state, zones: const [school], lat: 11.24, lng: -74.2, accuracy: 5,
    );
    expect(result, isEmpty);
    expect(state.containsKey('deleted'), isFalse);
  });
}
