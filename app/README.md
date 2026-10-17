# Titrator App

Android app (Flutter) for the ESP32-S3 pH titrator. It talks to the device over
BLE as specified in [`docs/protocol.md`](../docs/protocol.md).

## Features

- Scan for BLE devices and connect (titrators are listed first)
- Live pH value and curve (last 5 minutes)
- Automatic titration to a target pH (0–14, 2 decimals); the app detects
  completion (pH within ±0.05 for 5 s), stops the device and notifies the user
- Aspirate / dispense for both syringe channels: tap for one step, hold for
  continuous motion; available at any time, a running titration is ended by it
- Guided multi-point pH calibration (6.86 / 4.00 / 9.18 or 7.00 / 4.01 / 10.01,
  at least 2 points): the app records the electrode voltage in each buffer,
  computes slope and offset and writes them to the device
- Chinese / English UI, switchable in the app

## Layout

```
lib/
  core/    pure Dart: protocol codec, completion detector, calibration, models
  data/    platform adapters: BLE link, notifications
  state/   Riverpod controllers (scan, device session, calibration, locale)
  ui/      pages and widgets
  l10n/    ARB translations (Dart files are generated)
  sim/     hardware-free simulator, reached only from main_sim.dart
```

Dependencies point downwards only: `ui → state → data → core`.

## Build

Toolchain: Flutter 3.47.7, Android SDK 37, JDK 17 (see `docs/DEV_GUIDE.md`).

```bash
flutter pub get          # also generates lib/l10n/app_localizations*.dart
flutter analyze
flutter test
flutter build apk --release   # install this one on the phone
```

Install release builds, not debug ones: a debug APK is ~200 MB, the release
APK ~20 MB. It contains arm64-v8a only (see `android/app/build.gradle.kts`).
Use debug builds (`flutter run`) only for development with hot reload.

`compileSdk` is 37 because `permission_handler_android` and
`reactive_ble_mobile` require it.

## Simulator

`lib/main_sim.dart` runs the whole app against a simulated titrator, so
everything can be tried on a phone without the board. `lib/main.dart` never
imports `lib/sim/`, so the real app contains none of it.

```bash
flutter build apk --release -t lib/main_sim.dart   # install on the phone
flutter run --release -t lib/main_sim.dart         # or run it directly
flutter run -t lib/main_sim.dart                   # development, hot reload
```

- `SimTitrator` models the firmware and the beaker (buffered acid-base
  chemistry, probe lag, 10 mL syringes with 0.1 M acid / base, starting at
  8 mL) and speaks the wire protocol of `docs/protocol.md`, including the busy
  rules, the jog timeout, the stored calibration and the error codes. Its
  electrode is not ideal (slope -57.4 mV/pH, offset +6.5 mV) and noisy, so the
  readings are slightly off until the app calibrates it. It is plain Dart
  driven by `tick()`, so the tests run it in simulated time.
- Scanning finds one device, `Titrator-SIM`.
- The floating **SIM** chip (bottom left) opens a panel with a live readout
  (true pH, syringe volumes, electrode mV, mode), the electrode position (in
  the sample or in one of the standard buffers, to calibrate with) and fault
  injection: drop the connection, limit error, electrode error, new sample.
- The build has the same application id as the real app, so it installs over
  it.
