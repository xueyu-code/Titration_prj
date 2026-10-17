import 'package:flutter/foundation.dart';

@immutable
class PhSample {
  const PhSample(this.time, this.ph);
  final DateTime time;
  final double ph;
}
