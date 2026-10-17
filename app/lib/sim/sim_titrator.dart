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

  /// Both syringes start partly filled (but unhomed: the device does not
  /// know where they are); a titration needs at most about 5.5 mL.
  static const initialMl = 8.0;

  // The titration control loop of protocol section 4. The names mirror the
  // firmware constants (SETTLE_SKIP and so on).

  /// SETTLE_SKIP: readings this soon after a dose are discarded.
  static const settleSkip = Duration(seconds: 2);

  /// SETTLE_N and SETTLE_SPAN: the reading is settled when the last
  /// [settleN] readings (4 s) lie within [settleSpan] pH of each other.
  static const settleN = 8;
  static const settleSpan = 0.03;

  /// SETTLE_MAX: after this long the loop goes on with whatever it reads.
  static const settleMax = Duration(seconds: 30);

  /// HOLD_TOL: no dose while the reading is this close to the target. Must
  /// stay below the app's completion band of 0.05.
  static const holdTol = 0.02;

  /// FIRST_DOSE, MIN_DOSE, MAX_DOSE for a 50 mL sample and 0.1 M reagent. A
  /// buffered sample moves by roughly 0.6-1.5 pH per mL: the first dose is a
  /// small probe, the smallest is a few drops (a few 0.001 pH, well inside
  /// [holdTol]) and the largest moves the pH by less than 1. An unbuffered
  /// sample jumps by whole pH units even at the smallest dose.
  static const firstDoseMl = 0.05;
  static const minDoseMl = 0.005;
  static const maxDoseMl = 0.5;

  /// The titration gives up (`no_converge`) at this many reversals of
  /// direction, or at a reversal right after a [minDoseMl] dose.
  static const maxReversals = 3;

  /// The electrode voltage with the fault set: the front end sits at the
  /// ADC rail, far beyond the roughly +-420 mV a working electrode gives.
  static const faultMv = 800.0;

  /// The device calls it a `sensor` error after this long at the rail.
  static const faultDelay = Duration(seconds: 2);

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

  /// Fault hook: the electrode or its front end is broken. The voltage sits
  /// at the ADC rail; after [faultDelay] the device reports `sensor`.
  bool electrodeFault = false;

  final Random _random;
  final _syringeMl = [initialMl, initialMl];

  /// Whether each syringe has reached its empty-end limit switch since
  /// power-up. Until then the device does not know where it is (section 3).
  final _homed = [false, false];

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

  // Titrating (protocol section 4): the target; the start of the current wait
  // (a dose or hold decision) with the settled-reading window since; the last
  // dose with the reading before it; the reversals so far.
  var _target = 7.0;
  var _waitFrom = Duration.zero;
  final _window = <double>[];
  ({Channel channel, double ml, double ph})? _lastDose;
  var _reversals = 0;

  // Time at the ADC rail.
  var _faultTime = Duration.zero;

  DeviceMode get mode => _mode;

  /// True pH of the sample (the probe reading follows it with a lag).
  double get samplePh => _beaker.ph;

  /// Whether the sample is a buffered one (smooth curve) or a plain
  /// strong-acid/base one (a cliff at the equivalence point).
  bool get buffered => _beaker.buffered;

  /// Electrode voltage in mV, without noise.
  double get electrodeMv => electrodeFault
      ? faultMv
      : electrodeOffset + electrodeSlope * (_probe - 7);

  /// The device is in the `sensor` fault: the electrode has been broken long
  /// enough.
  bool get sensorFault => _faultTime >= faultDelay;

  double syringeMl(Channel channel) => _syringeMl[channel.index];

  bool isHomed(Channel channel) => _homed[channel.index];

  /// A fresh sample at a random pH; the syringes keep their contents.
  void newSample({bool buffered = true}) =>
      _beaker = _Beaker(5.5 + _random.nextDouble() * 3.5, buffered: buffered);

  /// The app subscribed to EVT: report the state and the stored calibration.
  void connected() {
    _emitState();
    _emitCal();
  }

  /// The link is gone: all motors stop.
  void disconnected() => _idle();

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
        final target = _ph(args['target']);
        if (sensorFault) return _error('sensor');
        _target = target;
        _lastDose = null;
        _reversals = 0;
        _startWait(); // the electrode may still be settling
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
        _emitCal();
    }
  }

  /// Starts or extends a motion of one syringe.
  void _drive(Channel channel, Direction direction, {required bool jog}) {
    final i = channel.index;
    final aspirate = direction == Direction.aspirate;
    if (aspirate && !_homed[i]) {
      return _fail('unhomed', channel: channel, direction: direction);
    }
    final atLimit = aspirate ? _syringeMl[i] >= capacityMl : _syringeMl[i] <= 0;
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
    _watchElectrode(dt);

    final seconds = dt.inMicroseconds / 1e6;
    final source = bufferPh ?? _beaker.ph;
    _probe += (source - _probe) * (1 - exp(-seconds / _probeTau));
    if (_now >= _nextReport) {
      _nextReport += reportInterval;
      final mv = _round(electrodeMv + _noise(), 1);
      final ph = _round(_phOf(mv), 2);
      _emit({'evt': 'ph', 'v': ph, 'mv': mv});
      // A reading at the rail is reported, but it is no measurement: the
      // control loop does not see it.
      if (_mode == DeviceMode.titrating && !electrodeFault) _control(ph);
    }
  }

  void _runMotion(Duration from) {
    final motion = _motion;
    if (motion == null) return;
    final until = _now < _motionEnd ? _now : _motionEnd;
    final ml = (until - from).inMicroseconds / 1e6 * pumpMlPerSecond;

    if (motion.direction == Direction.dispense) {
      if (_dispense(motion.channel, ml)) return;
    } else {
      final i = motion.channel.index;
      final moved = min(ml, capacityMl - _syringeMl[i]);
      _syringeMl[i] += moved;
      if (moved < ml) {
        return _fail(
          'limit',
          channel: motion.channel,
          direction: motion.direction,
        );
      }
    }
    if (_now >= _motionEnd) _idle();
  }

  /// Pushes [ml] from a syringe into the beaker. Reaching the empty end is the
  /// limit switch: the syringe is homed and `limit` ends the motion or
  /// titration. Returns whether that happened.
  bool _dispense(Channel channel, double ml) {
    final i = channel.index;
    final moved = min(ml, _syringeMl[i]);
    _syringeMl[i] -= moved;
    _beaker.dose(moved, _reagentMolar[i]);
    if (_syringeMl[i] > 0) return false;

    _homed[i] = true;
    _fail('limit', channel: channel, direction: Direction.dispense);
    return true;
  }

  /// Counts the time at the ADC rail. The `sensor` error comes once, on
  /// entering the fault; it ends a titration but not a motion.
  void _watchElectrode(Duration dt) {
    if (!electrodeFault) {
      _faultTime = Duration.zero;
      return;
    }
    if (sensorFault) return;
    _faultTime += dt;
    if (!sensorFault) return;
    if (_mode == DeviceMode.titrating) {
      _fail('sensor');
    } else {
      _error('sensor');
    }
  }

  // ---------------------------------------------------------- titration

  /// Restarts the wait for a settled reading.
  void _startWait() {
    _waitFrom = _now;
    _window.clear();
  }

  /// One step of the control loop (protocol section 4), on each reported
  /// reading [ph]: wait for the reading to settle, then hold or dose. Like
  /// the firmware it acts on its own noisy, calibrated reading, not on the
  /// true pH.
  void _control(double ph) {
    final waited = _now - _waitFrom;
    if (waited < settleSkip) return;
    _window.add(ph);
    if (_window.length > settleN) _window.removeAt(0);

    final span = _window.reduce(max) - _window.reduce(min);
    final settled = _window.length == settleN && span <= settleSpan;
    if (settled || waited >= settleMax) {
      _decide(_window.reduce((a, b) => a + b) / _window.length);
    }
  }

  /// Holds or doses at the settled reading [ph]. The dose is half the volume
  /// the last dose's response says is needed, halved again after a reversal;
  /// without a usable response it is twice the last dose.
  void _decide(double ph) {
    _startWait();
    final err = _target - ph;
    if (err.abs() <= holdTol) return;

    final channel = err > 0 ? Channel.ch2 : Channel.ch1; // base : acid
    var ml = firstDoseMl;
    final last = _lastDose;
    if (last != null) {
      // Gain: how far the last dose moved the pH in the direction it pushes.
      final gain = (last.channel == Channel.ch2 ? 1 : -1) * (ph - last.ph);
      ml = gain >= settleSpan ? 0.5 * err.abs() * last.ml / gain : 2 * last.ml;
      if (last.channel != channel) {
        if (++_reversals >= maxReversals || last.ml <= minDoseMl) {
          return _fail('no_converge');
        }
        ml /= 2;
      }
    }
    ml = ml.clamp(minDoseMl, maxDoseMl);

    _lastDose = (channel: channel, ml: ml, ph: ph);
    _dispense(channel, ml);
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

  void _emitCal() =>
      _emit({'evt': 'cal', 'slope': _calSlope, 'offset': _calOffset});

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

/// The sample: strong acid/base reagents added to three weak-acid buffers, or
/// to plain water when not [buffered]. Its pH follows from the charge
/// balance, so a buffered titration curve is smooth like a real one, while an
/// unbuffered one has a cliff at the equivalence point.
class _Beaker {
  /// A sample at [ph]: the net strong base is whatever balances the charges.
  _Beaker(this.ph, {required this.buffered}) {
    final h = _pow10(-ph);
    base = volume * (_kw / h - h) + _dissociated(h);
  }

  static const _kw = 1e-14;
  static const _pKa = [4.76, 7.20, 9.25];

  /// Moles of each weak acid: 5 mM in the initial 50 mL.
  static const _acidMol = 0.005 * 0.050;

  final bool buffered;

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
  double _dissociated(double h) {
    if (!buffered) return 0;
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
