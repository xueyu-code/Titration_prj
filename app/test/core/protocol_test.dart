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
      expect(wire(const CalSet(-57.92, 4.35)), {
        'cmd': 'cal_set',
        'slope': -57.92,
        'offset': 4.35,
      });
    });

    test('values are rounded to 2 decimals', () {
      expect((wire(const StartTitration(7.004)) as Map)['target'], 7.0);
      expect((wire(const StartTitration(7.006)) as Map)['target'], 7.01);
      final cal = wire(const CalSet(-57.9249, -4.3551)) as Map;
      expect(cal['slope'], -57.92);
      expect(cal['offset'], -4.36);
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

    test('ph carries the electrode voltage', () {
      expect(
        decode('{"evt":"ph","v":6.98,"mv":1.2}'),
        isA<PhReading>().having((e) => e.mv, 'mv', 1.2),
      );
      expect(
        decode('{"evt":"ph","v":6.98,"mv":-30}'),
        isA<PhReading>().having((e) => e.mv, 'mv', -30.0),
      );
      // Older firmware or a malformed field: still a reading, without mv.
      expect(
        decode('{"evt":"ph","v":6.98}'),
        isA<PhReading>().having((e) => e.mv, 'mv', isNull),
      );
      expect(
        decode('{"evt":"ph","v":6.98,"mv":"1.2"}'),
        isA<PhReading>().having((e) => e.mv, 'mv', isNull),
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

    test('cal', () {
      expect(
        decode('{"evt":"cal","slope":-57.9,"offset":4}'),
        isA<CalApplied>()
            .having((e) => e.slope, 'slope', -57.9)
            .having((e) => e.offset, 'offset', 4.0),
      );
      expect(decode('{"evt":"cal","slope":-57.9}'), isNull);
      expect(decode('{"evt":"cal","slope":"-57.9","offset":4}'), isNull);
    });

    test('cal knows the factory defaults', () {
      expect(const CalApplied(-59.16, 0).isFactory, isTrue);
      expect(const CalApplied(-59.159999, 0.001).isFactory, isTrue);
      expect(const CalApplied(-57.92, 0).isFactory, isFalse);
      expect(const CalApplied(-59.16, 4.35).isFactory, isFalse);
      expect(const CalApplied(-57.4, 0).efficiency, closeTo(0.970, 0.001));
    });

    test('error', () {
      expect(
        decode('{"evt":"error","code":"busy","msg":"titrating"}'),
        isA<DeviceError>()
            .having((e) => e.code, 'code', 'busy')
            .having((e) => e.message, 'message', 'titrating')
            .having((e) => e.channel, 'channel', isNull)
            .having((e) => e.direction, 'direction', isNull),
      );
      expect(
        decode('{"evt":"error"}'),
        isA<DeviceError>()
            .having((e) => e.code, 'code', 'unknown')
            .having((e) => e.message, 'message', isNull),
      );
    });

    test('limit error carries the motion that hit it', () {
      expect(
        decode('{"evt":"error","code":"limit","ch":1,"dir":"in"}'),
        isA<DeviceError>()
            .having((e) => e.code, 'code', 'limit')
            .having((e) => e.channel, 'channel', Channel.ch1)
            .having((e) => e.direction, 'direction', Direction.aspirate),
      );
      expect(
        decode('{"evt":"error","code":"limit","ch":2,"dir":"out"}'),
        isA<DeviceError>()
            .having((e) => e.channel, 'channel', Channel.ch2)
            .having((e) => e.direction, 'direction', Direction.dispense),
      );
      // Unknown values are dropped, not guessed.
      expect(
        decode('{"evt":"error","code":"limit","ch":3,"dir":"up"}'),
        isA<DeviceError>()
            .having((e) => e.code, 'code', 'limit')
            .having((e) => e.channel, 'channel', isNull)
            .having((e) => e.direction, 'direction', isNull),
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
    });
  });
}
