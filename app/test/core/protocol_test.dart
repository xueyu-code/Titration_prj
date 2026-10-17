import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:titrator_app/core/protocol.dart';

Object? wire(Command c) => jsonDecode(utf8.decode(c.encode()));

DeviceEvent? decode(String s) => DeviceEvent.decode(utf8.encode(s));

void main() {
  group('commands', () {
    test('encode as the JSON of docs/protocol.md', () {
      expect(wire(const StartTitration(7)), {'cmd': 'titrate', 'target': 7.0});
      expect(wire(const StopAll()), {'cmd': 'stop'});
      expect(wire(const Move(Channel.ch1, Direction.aspirate)), {
        'cmd': 'move',
        'ch': 1,
        'dir': 'in',
      });
      expect(wire(const Move(Channel.ch2, Direction.dispense)), {
        'cmd': 'move',
        'ch': 2,
        'dir': 'out',
      });
      expect(wire(const Jog(Channel.ch2, Direction.aspirate)), {
        'cmd': 'jog',
        'ch': 2,
        'dir': 'in',
      });
      expect(wire(const CalStart()), {'cmd': 'cal_start'});
      expect(wire(const CalPoint(6.86)), {'cmd': 'cal_point', 'ph': 6.86});
      expect(wire(const CalFinish()), {'cmd': 'cal_finish'});
      expect(wire(const CalAbort()), {'cmd': 'cal_abort'});
    });

    test('pH values are rounded to 2 decimals', () {
      expect((wire(const StartTitration(7.004)) as Map)['target'], 7.0);
      expect((wire(const StartTitration(7.006)) as Map)['target'], 7.01);
      expect((wire(const CalPoint(4.0049)) as Map)['ph'], 4.0);
      // 6.855 is not exactly representable; either neighbour is acceptable.
      expect(
        (wire(const StartTitration(6.855)) as Map)['target'],
        anyOf(6.85, 6.86),
      );
    });

    test('a command fits in one MTU-3 write', () {
      expect(const StartTitration(14).encode().length, lessThan(244));
    });
  });

  group('events', () {
    test('ph', () {
      final e = decode('{"evt":"ph","v":6.98}');
      expect(e, isA<PhReading>().having((e) => e.ph, 'ph', 6.98));
      // JSON integers are accepted too.
      expect(
        decode('{"evt":"ph","v":7}'),
        isA<PhReading>().having((e) => e.ph, 'ph', 7.0),
      );
    });

    test('state', () {
      for (final mode in DeviceMode.values.where(
        (m) => m != DeviceMode.unknown,
      )) {
        expect(
          decode('{"evt":"state","s":"${mode.name}"}'),
          isA<ModeChanged>().having((e) => e.mode, 'mode', mode),
        );
      }
    });

    test('unknown state string maps to DeviceMode.unknown', () {
      expect(
        decode('{"evt":"state","s":"flying"}'),
        isA<ModeChanged>().having((e) => e.mode, 'mode', DeviceMode.unknown),
      );
      expect(
        decode('{"evt":"state"}'),
        isA<ModeChanged>().having((e) => e.mode, 'mode', DeviceMode.unknown),
      );
    });

    test('cal_point', () {
      expect(
        decode('{"evt":"cal_point","ph":6.86,"ok":true,"mv":12.5}'),
        isA<CalPointResult>()
            .having((e) => e.bufferPh, 'bufferPh', 6.86)
            .having((e) => e.ok, 'ok', true),
      );
      expect(
        decode('{"evt":"cal_point","ph":4,"ok":false}'),
        isA<CalPointResult>().having((e) => e.ok, 'ok', false),
      );
      // A missing ok must not count as success.
      expect(
        decode('{"evt":"cal_point","ph":4}'),
        isA<CalPointResult>().having((e) => e.ok, 'ok', false),
      );
    });

    test('cal_done', () {
      expect(
        decode('{"evt":"cal_done","ok":true,"slope":98.5,"offset":-3}'),
        isA<CalDone>()
            .having((e) => e.ok, 'ok', true)
            .having((e) => e.slope, 'slope', 98.5)
            .having((e) => e.offset, 'offset', -3.0),
      );
      expect(
        decode('{"evt":"cal_done","ok":false}'),
        isA<CalDone>()
            .having((e) => e.ok, 'ok', false)
            .having((e) => e.slope, 'slope', isNull)
            .having((e) => e.offset, 'offset', isNull),
      );
    });

    test('error', () {
      expect(
        decode('{"evt":"error","code":"busy","msg":"titrating"}'),
        isA<DeviceError>()
            .having((e) => e.code, 'code', 'busy')
            .having((e) => e.message, 'message', 'titrating'),
      );
      expect(
        decode('{"evt":"error"}'),
        isA<DeviceError>()
            .having((e) => e.code, 'code', 'unknown')
            .having((e) => e.message, 'message', isNull),
      );
    });

    test('unknown fields are ignored', () {
      expect(decode('{"evt":"ph","v":7.1,"extra":[1,2]}'), isA<PhReading>());
    });

    test('malformed or unknown messages decode to null', () {
      expect(decode(''), isNull);
      expect(decode('{"evt":"ph","v":'), isNull);
      expect(decode('not json'), isNull);
      expect(DeviceEvent.decode([0xff, 0xfe, 0x00]), isNull);
      expect(decode('[1,2]'), isNull);
      expect(decode('"ph"'), isNull);
      expect(decode('7'), isNull);
      expect(decode('null'), isNull);
      expect(decode('{}'), isNull);
      expect(decode('{"evt":"reboot"}'), isNull);
      expect(decode('{"evt":"ph"}'), isNull);
      expect(decode('{"evt":"ph","v":"7"}'), isNull);
      expect(decode('{"evt":"cal_point","ok":true}'), isNull);
    });
  });
}
