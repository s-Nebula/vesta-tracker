# Vesta Tracker (vesta_tracker)

Minor's app of **Vesta Security**. It links with **Vesta Parent** by QR code and,
within the purposes the guardians have authorised, shares location and device
status, applies study mode, time limits, app blocking and web filtering (local DNS
VPN with safe search), and lets the minor send SOS alerts and requests.

## Development

- Flutter 3 / Dart 3 plus native Kotlin services
  (`android/app/src/main/kotlin`: AccessibilityService, VpnService, usage stats).
- UI language: Spanish and English (`lib/l10n/`), following the phone's language.
  Native texts use `Lang.t(es, en)`.

```bash
flutter pub get
flutter analyze
flutter test
# APK for vestasecurity.date (self-updating) and bundle for Google Play.
# Both need the signing key (vesta-build/secrets/signing, not in the repository).
flutter build apk --release --flavor web --dart-define=VESTA_API_URL=https://api.vestasecurity.date
flutter build appbundle --release --flavor play --dart-define=VESTA_API_URL=https://api.vestasecurity.date
```

## Updates

Two Android flavours with the same `applicationId` and key:

- **web**: the APK from `vestasecurity.date/downloads`. It checks
  `downloads/version.json` when it opens and every 6 h on Wi-Fi; it downloads
  the new APK, checks its SHA-256 and signing key and installs it with
  `PackageInstaller` (no tap on Android 12+ once "install unknown apps" is
  allowed; otherwise Android asks). Code: `android/app/src/web`,
  `lib/services/app_updater.dart`. Publish with
  `vesta-build/publicar-actualizacion.sh` after raising `version:` in `pubspec.yaml`.
- **play**: no self-updater and no `REQUEST_INSTALL_PACKAGES` (Play policy).
  Play installs the updates; the app asks Play for an in-app update when one
  is available (priority 4-5 in Play Console = immediate).

`flutter run` and `flutter build` use `web` by default (`default-flavor` in
`pubspec.yaml`).

## Licence

Copyright © 2026 FORBIDDEN S.A.S.

This program is free software: you can redistribute it and/or modify it under the terms of the GNU Affero General Public License version 3 (AGPL-3.0). See `LICENSE`.
