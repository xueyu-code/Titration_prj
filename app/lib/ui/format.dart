/// pH with two decimals, "--" when there is no reading.
String formatPh(double? ph) => ph?.toStringAsFixed(2) ?? '--';
