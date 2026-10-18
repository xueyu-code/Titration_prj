# Titrator Firmware

ESP-IDF firmware for the ESP32-S3-DevKitC-1 (ESP32-S3-WROOM-1-N16R8) that
drives the two syringe pumps, reads the pH module and talks to the app over
BLE as specified in [`docs/protocol.md`](../docs/protocol.md). The design,
pin plan and every decision behind it are in [`DESIGN.md`](DESIGN.md)
(Chinese).

## Hardware

- Two 42 steppers on TMC2209 modules in STEP/DIR mode, 1/16 microstep (MS1 =
  MS2 = VIO). STEP pulses come from MCPWM and are counted by PCNT, so the step
  count is exact.
- One limit switch per syringe, at the empty end.
- PH-4502C on 5 V; Po through a 15k/10k divider into GPIO1 (ADC1, 6 dB). To
  and Do are not used.

Pin plan: DESIGN §13. Open hardware questions: DESIGN §18.

## Layout

```
main/                  wiring: queue, tasks, device ports
components/core/       pure C, no ESP-IDF: protocol, pH, sensor fault,
                       axis (motion profile, homing), titration loop, device
components/platform/   thin ESP-IDF layer: stepper, ph_adc, ble_link, cal_store
test/host/             host unit tests and the closed-loop beaker rig
```

## Build and flash

Toolchain: ESP-IDF v5.5.5 in `~/esp/esp-idf-v5.5.5`.

```bash
. ~/esp/esp-idf-v5.5.5/export.sh
cd firmware
idf.py build                              # target and options come from sdkconfig.defaults
idf.py -p /dev/ttyUSB0 flash monitor      # UART port of the DevKitC
```

`sdkconfig` is generated from `sdkconfig.defaults` only when `firmware/sdkconfig`
does not exist. After `sdkconfig.defaults` changes (as with a board change),
delete `firmware/sdkconfig` before `idf.py build`.

## Host tests

No board needed. The tests compile `core` with gcc, ASan and UBSan, and run
the titration loop against a simulated beaker and electrode.

```bash
cmake -S firmware/test/host -B firmware/test/host/build -G Ninja
cmake --build firmware/test/host/build
ctest --test-dir firmware/test/host/build --output-on-failure
```

## Editor

`.clangd` points clangd at the two compile databases: `core` and the host
tests use `test/host/build`, `main` and `platform` use `build` (run the
builds above once). The system clangd has no Xtensa target, so in `main` and
`platform` it can still miss a newlib header. Espressif's own clangd
(`idf_tools.py install esp-clang`) removes that last gap.

## Status

Verified without hardware: all host tests, including the closed loop
(buffered samples converge, unbuffered ones stop with `no_converge`), and a
warning-free `idf.py build`.

Not yet verified, needs the board (details in DESIGN §1.3, §4 and §19):

- ADC: steady `V_adc` on a 1.05 V divider, the linearity measurement over
  0.7–1.3 V, and the sensor-fault rail thresholds.
- Stepper: PCNT equals the commanded steps, the limit pin stops a dispense
  within two steps, and there are no stray edges at start and stop.
- BLE: the app finds `Titrator-XXXX`, gets `state`, `cal` and `ph` at 2 Hz,
  `cal_set` survives a reboot, and a reconnect works.
- Task stack high-water marks after a titration and a `cal_set`.
