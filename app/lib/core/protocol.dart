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

  static Channel? parse(Object? id) =>
      values.where((c) => c.id == id).firstOrNull;
}

enum Direction {
  aspirate('in'),
  dispense('out');

  const Direction(this.wire);
  final String wire;

  static Direction? parse(Object? wire) =>
      values.where((d) => d.wire == wire).firstOrNull;
}

enum DeviceMode {
  idle,
  titrating,
  moving,
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

/// Stores the electrode calibration on the device: [slope] in mV per pH unit
/// (negative) and [offset], the mV at pH 7. The device answers with
/// [CalApplied].
final class CalSet extends Command {
  const CalSet(this.slope, this.offset);
  final double slope;
  final double offset;

  @override
  Map<String, Object> toJson() => {
    'cmd': 'cal_set',
    'slope': _round2(slope),
    'offset': _round2(offset),
  };
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
      {'evt': 'ph', 'v': final num v} => PhReading(
        v.toDouble(),
        mv: _num(json['mv']),
      ),
      {'evt': 'state'} => ModeChanged(DeviceMode.parse(json['s'])),
      {'evt': 'cal', 'slope': final num slope, 'offset': final num offset} =>
        CalApplied(slope.toDouble(), offset.toDouble()),
      {'evt': 'error'} => DeviceError(
        _str(json['code']) ?? 'unknown',
        message: _str(json['msg']),
        channel: Channel.parse(json['ch']),
        direction: Direction.parse(json['dir']),
      ),
      _ => null,
    };
  }
}

final class PhReading extends DeviceEvent {
  const PhReading(this.ph, {this.mv});
  final double ph;

  /// Raw electrode voltage; null when the firmware does not report it.
  final double? mv;
}

final class ModeChanged extends DeviceEvent {
  const ModeChanged(this.mode);
  final DeviceMode mode;
}

/// The calibration the device stored, in answer to [CalSet].
final class CalApplied extends DeviceEvent {
  const CalApplied(this.slope, this.offset);
  final double slope;
  final double offset;
}

final class DeviceError extends DeviceEvent {
  const DeviceError(this.code, {this.message, this.channel, this.direction});
  final String code;
  final String? message;

  /// The motion that hit a `limit`; null for other errors.
  final Channel? channel;
  final Direction? direction;
}

double? _num(Object? v) => v is num ? v.toDouble() : null;

String? _str(Object? v) => v is String ? v : null;
