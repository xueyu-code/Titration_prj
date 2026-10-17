import 'dart:convert';

/// BLE contract with the titrator firmware. Keep in sync with docs/protocol.md.
abstract final class TitratorUuids {
  static const service = 'f65c0001-8221-4068-aa47-28e41eec47fd';
  static const command = 'f65c0002-8221-4068-aa47-28e41eec47fd';
  static const event = 'f65c0003-8221-4068-aa47-28e41eec47fd';
}

/// Syringe channels. Channel 1 holds acid, channel 2 holds base.
enum Channel {
  ch1,
  ch2;

  int get id => index + 1;
}

enum Direction {
  aspirate('in'),
  dispense('out');

  const Direction(this.wire);
  final String wire;
}

enum DeviceMode {
  idle,
  titrating,
  moving,
  calibrating,
  unknown;

  static DeviceMode parse(Object? s) =>
      values.firstWhere((m) => m.name == s, orElse: () => unknown);
}

// ---------------------------------------------------------------- commands

sealed class Command {
  const Command();

  Map<String, Object> toJson();

  List<int> encode() => utf8.encode(jsonEncode(toJson()));
}

final class StartTitration extends Command {
  const StartTitration(this.target);
  final double target;

  @override
  Map<String, Object> toJson() => {'cmd': 'titrate', 'target': _round2(target)};
}

final class StopAll extends Command {
  const StopAll();

  @override
  Map<String, Object> toJson() => {'cmd': 'stop'};
}

/// Single fixed step (tap).
final class Move extends Command {
  const Move(this.channel, this.direction);
  final Channel channel;
  final Direction direction;

  @override
  Map<String, Object> toJson() => {
    'cmd': 'move',
    'ch': channel.id,
    'dir': direction.wire,
  };
}

/// Continuous motion (long press). Must be re-sent every [Jog.refresh];
/// the firmware stops on its own if the refresh stops arriving.
final class Jog extends Command {
  const Jog(this.channel, this.direction);
  final Channel channel;
  final Direction direction;

  static const refresh = Duration(milliseconds: 300);

  @override
  Map<String, Object> toJson() => {
    'cmd': 'jog',
    'ch': channel.id,
    'dir': direction.wire,
  };
}

final class CalStart extends Command {
  const CalStart();

  @override
  Map<String, Object> toJson() => {'cmd': 'cal_start'};
}

final class CalPoint extends Command {
  const CalPoint(this.bufferPh);
  final double bufferPh;

  @override
  Map<String, Object> toJson() => {'cmd': 'cal_point', 'ph': _round2(bufferPh)};
}

final class CalFinish extends Command {
  const CalFinish();

  @override
  Map<String, Object> toJson() => {'cmd': 'cal_finish'};
}

final class CalAbort extends Command {
  const CalAbort();

  @override
  Map<String, Object> toJson() => {'cmd': 'cal_abort'};
}

double _round2(double v) => (v * 100).roundToDouble() / 100;

// ------------------------------------------------------------------ events

sealed class DeviceEvent {
  const DeviceEvent();

  /// Decodes one EVT notification. Returns null for malformed or unknown
  /// messages so a newer firmware never crashes an older app.
  static DeviceEvent? decode(List<int> bytes) {
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      return null;
    }
    if (json is! Map<String, Object?>) return null;
    return switch (json) {
      {'evt': 'ph', 'v': final num v} => PhReading(v.toDouble()),
      {'evt': 'state'} => ModeChanged(DeviceMode.parse(json['s'])),
      {'evt': 'cal_point', 'ph': final num ph} => CalPointResult(
        ph.toDouble(),
        ok: json['ok'] == true,
      ),
      {'evt': 'cal_done'} => CalDone(
        ok: json['ok'] == true,
        slope: _num(json['slope']),
        offset: _num(json['offset']),
      ),
      {'evt': 'error'} => DeviceError(
        _str(json['code']) ?? 'unknown',
        _str(json['msg']),
      ),
      _ => null,
    };
  }
}

final class PhReading extends DeviceEvent {
  const PhReading(this.ph);
  final double ph;
}

final class ModeChanged extends DeviceEvent {
  const ModeChanged(this.mode);
  final DeviceMode mode;
}

final class CalPointResult extends DeviceEvent {
  const CalPointResult(this.bufferPh, {required this.ok});
  final double bufferPh;
  final bool ok;
}

final class CalDone extends DeviceEvent {
  const CalDone({required this.ok, this.slope, this.offset});
  final bool ok;
  final double? slope;
  final double? offset;
}

final class DeviceError extends DeviceEvent {
  const DeviceError(this.code, [this.message]);
  final String code;
  final String? message;
}

double? _num(Object? v) => v is num ? v.toDouble() : null;

String? _str(Object? v) => v is String ? v : null;
