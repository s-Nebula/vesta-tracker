import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../services/pairing_payload.dart';

import 'package:vesta_tracker/l10n/tr.dart';
/// Scans the linking QR and returns the code with `Navigator.pop`.
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  final MobileScannerController _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );

  bool _done = false;
  String? _lastInvalid;

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;

    for (final barcode in capture.barcodes) {
      final code = PairingPayload.parse(barcode.rawValue);

      if (code != null) {
        _done = true;
        Navigator.of(context).pop(code);
        return;
      }

      if (barcode.rawValue != null && barcode.rawValue != _lastInvalid) {
        _lastInvalid = barcode.rawValue;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('Este QR no es un código de vinculación de Vesta.')),
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const rose = Color(0xFFC15B68);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(tr('Escanear código QR')),
        actions: [
          IconButton(
            tooltip: tr('Linterna'),
            onPressed: () => _controller.toggleTorch(),
            icon: const Icon(Icons.flashlight_on_rounded),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  error.errorCode == MobileScannerErrorCode.permissionDenied
                      ? tr('Vesta necesita acceso a la cámara para leer el QR. Puedes concederlo en Ajustes o introducir el código a mano.')
                      : tr('No se pudo abrir la cámara. Introduce el código a mano.'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, height: 1.5),
                ),
              ),
            ),
          ),
          IgnorePointer(
            child: Center(
              child: Container(
                width: 250,
                height: 250,
                decoration: BoxDecoration(
                  border: Border.all(color: rose, width: 3),
                  borderRadius: BorderRadius.circular(24),
                ),
              ),
            ),
          ),
          Positioned(
            left: 24,
            right: 24,
            bottom: 48,
            child: Text(
              tr('Apunta al código QR que aparece en la app Vesta del tutor.'),
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white, fontSize: 15, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
