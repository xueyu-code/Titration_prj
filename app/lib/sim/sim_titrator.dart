import 'dart:convert';
import 'dart:math';

import '../core/calibration.dart';
import '../core/protocol.dart';

/// A titrator without hardware: firmware behaviour plus the beaker it acts on.
///
/// It speaks the wire protocol of docs/protocol.md: [handle] takes one CMD
/// write, [onNotify] receives every EVT notification as UTF-8 JSON. Time only
/// advances through [tick]. Pure Dart, so it can double as the reference for
/// the real firmware.
class SimTitrator {
  SimTitrator({this.onNotify = _discard, Random? random})
    : _random = random ?? Random() {
    newSample();
    _probe = _beaker.ph;
  }

  static const pumpMlPerSecond = 0.5;

  /// Volume of one `move`.
  static const stepMl = 0.05;

  /// A `jog` stops by itself when not refreshed within this time.
  static const jogTimeout = Duration(seconds: 1);
  static const capacityMl = 10.0;

  /// Both syringes start partly filled, so aspirating and dispensing work at
  /// once; a titration needs at most about 5.5 mL.
  static const initialMl = 8.0;

  /// Wait after each titration dose for mixing and the electrode response.
  static const mixDelay = Duration(seconds: 2);

  /// The titration holds while the reading is this close to the target.
  static const tolerance = 0.02;

  /// Proportional dose: [doseMlPerPh] per pH unit of error, within the limits.
  static const doseMlPerPh = 0.3;
  static const minDoseMl = 0.005;
  static const maxDoseMl = 0.5;

  /// The true response of the simulated electrode, which is not ideal: what
  /// calibration finds out. Slope in mV per pH unit, offset in mV at pH 7.
  static const electrodeSlope = -57.4;
  static const electrodeOffset = 6.5;

  static const reportInterval = Duration(milliseconds: 500);
  static const _probeTau = 1.5; // seconds
  static const _noiseSd = 0.25; // mV
  static const _maxStep = Duration(milliseconds: 50);

  /// Net strong base per litre of reagent, by channel: 0.1 M acid, 0.1 M base.
  static const _reagentMolar = [-0.1, 0.1];

  static final _stepTime = Duration(
    microseconds: (stepMl / pumpMlPerSecond * 1e6).round(),
  );

  static const _all = {'titrate', 'stop', 'move', 'jog', 'cal_set'};

  /// Commands accepted per mode (protocol section 3).
  static const _accepts = {
    DeviceMode.idle: _all,
    DeviceMode.titrating: {'stop', 'move', 'jog'},
    DeviceMode.moving: {'stop', 'move', 'jog'},
  };

  static void _discard(List<int> _) {}

  /// Receives each EVT notification. [SimDeviceLink] takes this over.
  void Function(List<int> bytes) onNotify;

  /// The buffer (its pH) the electrode is dipped in; null: in the sample.
  double? bufferPh;

  final Random _random;
  final _syringeMl = [initialMl, initialMl];
  late _Beaker _beaker;
  var _mode = DeviceMode.idle;
  var _now = Duration.zero;

  /// The pH the electrode currently feels: that of its surroundings, with a
  /// lag.
  late double _probe;

  // The stored calibration; factory defaults until `cal_set` (protocol 2.4).
  var _calSlope = idealSlope;
  var _calOffset = 0.0;

  // Report schedule.
  var _nextReport = reportInterval;

  // Moving: the syringe driven and when to stop.
  ({Channel channel, Direction direction})? _motion;
  var _motionEnd = Duration.zero;

  // Titrating: the target and the earliest time of the next dose.
  var _target = 7.0;
  var _nextDose = Duration.zero;

  DeviceMode get mode => _mode;

  /// True pH of the sample (the probe reading follows it with a lag).
  double get samplePh => _beaker.ph;

  /// Electrode voltage in mV, without noise.
  double get electrodeMv => electrodeOffset + electrodeSlope * (_probe - 7);

  double syringeMl(Channel channel) => _syringeMl[channel.index];

  /// A fresh sample at a random pH; the syringes keep their contents.
  void newSample() => _beaker = _Beaker(5.5 + _random.nextDouble() * 3.5);

  /// The app subscribed to EVT: report the state.
  void connected() => _emitState();

  /// The link is gone: all motors stop.
  void disconnected() => _idle();

  /// Fault hook: `limit` also stops motion and titration; `sensor` only
  /// reports.
  void injectError(String code) {
    final running = _mode == DeviceMode.titrating || _mode == DeviceMode.moving;
    if (code == 'limit' && running) {
      _fail(code);
    } else {
      _error(code);
    }
  }

  /// Handles one CMD write: malformed or unknown is `bad_cmd`, a command the
  /// current mode does not accept is `busy`, otherwise it takes effect.
  void handle(List<int> bytes) {
    try {
      final json = jsonDecode(utf8.decode(bytes));
      if (json is! Map<String, Object?>) throw const FormatException('object');
      final cmd = json['cmd'];
      if (cmd is! String || !_all.contains(cmd)) {
        throw const FormatException('unknown command');
      }
      if (_accepts[_mode]!.contains(cmd)) {
        _run(cmd, json);
      } else {
        _error('busy');
      }
    } on FormatException {
      _error('bad_cmd');
    }
  }

  /// Advances simulated time by [dt].
  void tick(Duration dt) {
    while (dt > Duration.zero) {
      final step = dt < _maxStep ? dt : _maxStep;
      _advance(step);
      dt -= step;
    }
  }

  // ---------------------------------------------------------------- commands

  void _run(String cmd, Map<String, Object?> args) {
    switch (cmd) {
      case 'titrate':
        _target = _ph(args['target']);
        _nextDose = _now;
        _setMode(DeviceMode.titrating);
      case 'stop':
        _idle();
      case 'move':
        _drive(_channel(args['ch']), _direction(args['dir']), jog: false);
      case 'jog':
        _drive(_channel(args['ch']), _direction(args['dir']), jog: true);
      case 'cal_set':
        final slope = _number(args['slope'], -70, -40);
        final offset = _number(args['offset'], -100, 100);
        _calSlope = slope;
        _calOffset = offset;
        _emit({'evt': 'cal', 'slope': slope, 'offset': offset});
    }
  }

  /// Starts or extends a motion of one syringe.
  void _drive(Channel channel, Direction direction, {required bool jog}) {
    final i = channel.index;
    final atLimit = direction == Direction.dispense
        ? _syringeMl[i] <= 0
        : _syringeMl[i] >= capacityMl;
    if (atLimit) return _fail('limit', channel: channel, direction: direction);

    final motion = (channel: channel, direction: direction);
    // Taps add up: each `move` is exactly one step.
    _motionEnd = jog
        ? _now + jogTimeout
        : (_motion == motion ? _motionEnd : _now) + _stepTime;
    _motion = motion;
    _setMode(DeviceMode.moving);
  }

  // ------------------------------------------------------------------- time

  void _advance(Duration dt) {
    final from = _now;
    _now += dt;
    _runMotion(from);
    _runTitration();

    final seconds = dt.inMicroseconds / 1e6;
    final source = bufferPh ?? _beaker.ph;
    _probe += (source - _probe) * (1 - exp(-seconds / _probeTau));
    if (_now >= _nextReport) {
      _nextReport += reportInterval;
      final mv = _round(electrodeMv + _noise(), 1);
      _emit({'evt': 'ph', 'v': _round(_phOf(mv), 2), 'mv': mv});
    }
  }

  void _runMotion(Duration from) {
    final motion = _motion;
    if (motion == null) return;
    final until = _now < _motionEnd ? _now : _motionEnd;
    final ml = (until - from).inMicroseconds / 1e6 * pumpMlPerSecond;

    final i = motion.channel.index;
    final dispense = motion.direction == Direction.dispense;
    final moved = min(
      ml,
      dispense ? _syringeMl[i] : capacityMl - _syringeMl[i],
    );
    if (dispense) {
      _syringeMl[i] -= moved;
      _beaker.dose(moved, _reagentMolar[i]);
    } else {
      _syringeMl[i] += moved;
    }

    if (moved < ml) {
      _fail('limit', channel: motion.channel, direction: motion.direction);
    } else if (_now >= _motionEnd) {
      _idle();
    }
  }

  /// One control step: dose towards the target, then wait for mixing. Like
  /// the firmware it acts on its own calibrated reading, not on the true pH.
  void _runTitration() {
    if (_mode != DeviceMode.titrating || _now < _nextDose) return;
    final err = _target - _phOf(electrodeMv);
    if (err.abs() <= tolerance) return;

    final channel = err > 0 ? Channel.ch2 : Channel.ch1; // base : acid
    final ml = (doseMlPerPh * err.abs()).clamp(minDoseMl, maxDoseMl);
    if (_syringeMl[channel.index] < ml) {
      return _fail('limit', channel: channel, direction: Direction.dispense);
    }
    _syringeMl[channel.index] -= ml;
    _beaker.dose(ml, _reagentMolar[channel.index]);
    _nextDose = _now + mixDelay;
  }

  /// The device's pH for electrode voltage [mv]: protocol section 2.4.
  double _phOf(double mv) => 7 + (mv - _calOffset) / _calSlope;

  /// Gaussian electrode noise in mV (Box-Muller).
  double _noise() =>
      _noiseSd *
      sqrt(-2 * log(1 - _random.nextDouble())) *
      cos(2 * pi * _random.nextDouble());

  // ------------------------------------------------------------------ state

  void _setMode(DeviceMode mode) {
    if (mode == _mode) return;
    _mode = mode;
    _emitState();
  }

  /// Stops everything and returns to idle.
  void _idle() {
    _motion = null;
    _setMode(DeviceMode.idle);
  }

  /// The device stops by itself: error first, then `state: idle`.
  void _fail(String code, {Channel? channel, Direction? direction}) {
    _error(code, channel: channel, direction: direction);
    _idle();
  }

  void _emitState() => _emit({'evt': 'state', 's': _mode.name});

  void _error(String code, {Channel? channel, Direction? direction}) => _emit({
    'evt': 'error',
    'code': code,
    'ch': ?channel?.id,
    'dir': ?direction?.wire,
  });

  void _emit(Map<String, Object> event) =>
      onNotify(utf8.encode(jsonEncode(event)));
}

// ------------------------------------------------------- argument parsing

Channel _channel(Object? v) =>
    Channel.parse(v) ?? (throw const FormatException('ch'));

Direction _direction(Object? v) =>
    Direction.parse(v) ?? (throw const FormatException('dir'));

double _number(Object? v, double min, double max) =>
    v is num && v >= min && v <= max
    ? v.toDouble()
    : throw const FormatException('number out of range');

double _ph(Object? v) => _number(v, 0, 14);

double _round(double v, int decimals) {
  final f = pow(10, decimals);
  return (v * f).round() / f;
}

// ------------------------------------------------------------------ beaker

/// The sample: strong acid/base reagents added to three weak-acid buffers.
/// Its pH follows from the charge balance, so the titration curve is smooth
/// and buffered like a real one.
class _Beaker {
  /// A sample at [ph]: the net strong base is whatever balances the charges.
  _Beaker(this.ph) {
    final h = _pow10(-ph);
    base = volume * (_kw / h - h) + _dissociated(h);
  }

  static const _kw = 1e-14;
  static const _pKa = [4.76, 7.20, 9.25];

  /// Moles of each weak acid: 5 mM in the initial 50 mL.
  static const _acidMol = 0.005 * 0.050;

  /// Litres.
  double volume = 0.050;

  /// Net strong base (base minus acid) in mol; negative when acidic.
  double base = 0;

  double ph;

  /// Adds [ml] of reagent with the given net strong base molarity.
  void dose(double ml, double molar) {
    volume += ml / 1000;
    base += ml / 1000 * molar;
    ph = _solve();
  }

  /// Moles of weak-acid anions at hydrogen ion concentration [h].
  static double _dissociated(double h) {
    var mol = 0.0;
    for (final pKa in _pKa) {
      final ka = _pow10(-pKa);
      mol += _acidMol * ka / (ka + h);
    }
    return mol;
  }

  /// Charge balance residual; strictly decreasing in pH.
  double _charge(double ph) {
    final h = _pow10(-ph);
    return h + (base - _dissociated(h)) / volume - _kw / h;
  }

  /// Bisection on pH 0-14; a sample beyond that range clamps to its ends.
  double _solve() {
    var lo = 0.0, hi = 14.0;
    for (var i = 0; i < 50; i++) {
      final mid = (lo + hi) / 2;
      if (_charge(mid) > 0) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return (lo + hi) / 2;
  }
}

double _pow10(double e) => pow(10, e).toDouble();
