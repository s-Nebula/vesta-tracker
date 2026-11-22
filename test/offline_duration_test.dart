import 'package:flutter_test/flutter_test.dart';
import 'package:vesta_tracker/location_service.dart';

void main() {
  test('offline duration in Spanish and English', () {
    expect(formatOfflineDuration(45, english: false), '45 minutos');
    expect(formatOfflineDuration(45, english: true), '45 minutes');
    expect(formatOfflineDuration(150, english: true), '2.5 hours');
    expect(formatOfflineDuration(180, english: false), '3 horas');
  });
}
