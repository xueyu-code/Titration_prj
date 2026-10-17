import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:titrator_app/core/protocol.dart';
import 'package:titrator_app/data/device_link.dart';
import 'package:titrator_app/sim/sim_link.dart';
import 'package:titrator_app/sim/sim_titrator.dart';
import 'package:titrator_app/state/providers.dart';
import 'package:titrator_app/state/scan_controller.dart';

import '../state/fakes.dart';

Duration ms(int n) => Duration(milliseconds: n);

void main() {
  group('SimDeviceLink', () {
    test('connects, reports the state, streams readings', () {
      fakeAsync((async) {
        final sim = SimTitrator();
        final link = SimDeviceLink(sim);
        final statuses = <LinkStatus>[];
        final events = <DeviceEvent>[];
        link.status.listen(statuses.add);
        link.events.listen(events.add);

        link.connect('SIM');
        async.elapse(ms(599));
        expect(statuses, [LinkStatus.connecting]);
        async.elapse(ms(2));
        expect(statuses, [LinkStatus.connecting, LinkStatus.connected]);
        expect(events.single, isA<ModeChanged>());

        async.elapse(const Duration(seconds: 2));
        expect(events.whereType<PhReading>(), hasLength(4));

        link.dispose();
      });
    });

    test('commands reach the simulator after a short delay', () {
      fakeAsync((async) {
        final sim = SimTitrator();
        final link = SimDeviceLink(sim);
        link.connect('SIM');
        async.elapse(const Duration(seconds: 1));

        link.send(const Jog(Channel.ch1, Direction.dispense));
        async.elapse(ms(10));
        expect(sim.mode, DeviceMode.idle);
        async.elapse(ms(100));
        expect(sim.mode, DeviceMode.moving);
        expect(sim.syringeMl(Channel.ch1), lessThan(10));

        link.dispose();
      });
    });

    test('sending while disconnected fails', () {
      fakeAsync((async) {
        final link = SimDeviceLink(SimTitrator());
        Object? error;
        link.send(const StopAll()).catchError((Object e) => error = e);
        async.flushMicrotasks();
        expect(error, isA<LinkException>());
        link.dispose();
      });
    });

    test('dropLink looks like a lost connection and stops the device', () {
      fakeAsync((async) {
        final sim = SimTitrator();
        final link = SimDeviceLink(sim);
        final statuses = <LinkStatus>[];
        link.status.listen(statuses.add);
        link.connect('SIM');
        async.elapse(const Duration(seconds: 1));
        link.send(const StartTitration(10));
        async.elapse(const Duration(seconds: 1));
        expect(sim.mode, DeviceMode.titrating);

        link.dropLink();
        async.flushMicrotasks();
        expect(statuses.last, LinkStatus.disconnected);
        expect(sim.mode, DeviceMode.idle);

        // No more ticks, and writes fail.
        final volume = sim.syringeMl(Channel.ch2);
        async.elapse(const Duration(seconds: 5));
        expect(sim.syringeMl(Channel.ch2), volume);
        Object? error;
        link.send(const StopAll()).catchError((Object e) => error = e);
        async.flushMicrotasks();
        expect(error, isA<LinkException>());

        link.dispose();
      });
    });

    test('disconnecting while connecting cancels the attempt', () {
      fakeAsync((async) {
        final link = SimDeviceLink(SimTitrator());
        Object? error;
        link.connect('SIM').catchError((Object e) => error = e);
        async.elapse(ms(100));
        link.disconnect();
        async.elapse(const Duration(seconds: 1));
        expect(error, isA<LinkException>());
        link.dispose();
      });
    });
  });

  group('SimScanController', () {
    test('finds the simulated titrator after a moment', () {
      fakeAsync((async) {
        final container = ProviderContainer(
          overrides: [
            appNotifierProvider.overrideWithValue(FakeAppNotifier()),
            scanProvider.overrideWith(SimScanController.new),
          ],
        );
        container.listen(scanProvider, (_, _) {});

        expect(container.read(scanProvider).bleStatus.name, 'ready');
        container.read(scanProvider.notifier).start();
        async.flushMicrotasks();
        expect(container.read(scanProvider).scanning, isTrue);
        expect(container.read(scanProvider).devices, isEmpty);

        async.elapse(SimScanController.scanTime);
        final state = container.read(scanProvider);
        expect(state.scanning, isFalse);
        expect(state.devices.single.name, 'Titrator-SIM');
        expect(ScanController.isTitrator(state.devices.single), isTrue);

        container.dispose();
      });
    });
  });
}
