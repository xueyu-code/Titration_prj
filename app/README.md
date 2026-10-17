# Titrator App

Android app (Flutter) for the ESP32-S3 pH titrator. It talks to the device over
BLE as specified in [`docs/protocol.md`](../docs/protocol.md).

## Features

- Scan for BLE devices and connect (titrators are listed first)
- Live pH value and curve (last 5 minutes)
- Automatic titration to a target pH (0–14, 2 decimals); the app detects
  completion (pH within ±0.05 for 5 s), stops the device and notifies the user
- Aspirate / dispense for both syringe channels: tap for one step, hold for
  continuous motion
- Guided multi-point pH calibration (6.86 / 4.00 / 9.18 or 7.00 / 4.01 / 10.01,
  at least 2 points)
- Every reading is stored locally; history view for any time range
- Chinese / English UI, switchable in the app

## Layout

```
lib/
  core/    pure Dart: protocol codec, completion detector, models
  data/    platform adapters: BLE link, sqlite sample store, notifications
  state/   Riverpod controllers (scan, device session, calibration, locale)
  ui/      pages and widgets
  l10n/    ARB translations (Dart files are generated)
```

Dependencies point downwards only: `ui → state → data → core`.

## Build

Toolchain: Flutter 3.47.7, Android SDK 37, JDK 17 (see `docs/DEV_GUIDE.md`).

```bash
flutter pub get          # also generates lib/l10n/app_localizations*.dart
flutter analyze
flutter test
flutter build apk --release
```

`compileSdk` is 37 because `permission_handler_android` and
`reactive_ble_mobile` require it.
