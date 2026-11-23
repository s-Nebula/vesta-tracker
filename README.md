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
flutter build apk --release   # needs android/key.properties (not in the repository)
```

## Licence

Copyright © 2026 FORBIDDEN S.A.S.

This program is free software: you can redistribute it and/or modify it under the terms of the GNU Affero General Public License version 3 (AGPL-3.0). See `LICENSE`.
