import 'package:flutter_test/flutter_test.dart';
import 'package:vesta_tracker/services/pairing_payload.dart';
import 'package:vesta_tracker/l10n/tr.dart';

void main() {
  // The tests check the Spanish texts.
  setUpAll(() => debugSetAppLanguage('es'));

  test('acepta el formato vesta://link', () {
    expect(PairingPayload.parse('vesta://link?code=abcdef1234'), 'ABCDEF1234');
    expect(PairingPayload.parse(' VESTA://LINK?code=ABCDEF1234 '), 'ABCDEF1234');
  });

  test('acepta el código sin más', () {
    expect(PairingPayload.parse('abcdef1234'), 'ABCDEF1234');
  });

  test('rechaza QR ajenos o mal formados', () {
    for (final raw in [
      null,
      '',
      'https://example.com/?code=ABCDEF1234',
      'vesta://otro?code=ABCDEF1234',
      'vesta://link?code=ABC',
      'vesta://link?code=GHIJKL1234',
      'ABCDEF12345',
    ]) {
      expect(PairingPayload.parse(raw), isNull, reason: '$raw');
    }
  });
}
