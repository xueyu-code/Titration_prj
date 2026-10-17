/// pH with two decimals, "--" when there is no reading.
String formatPh(double? ph) => ph?.toStringAsFixed(2) ?? '--';

/// Electrode voltage with one decimal, "--" when there is no reading.
String formatMv(double? mv) => mv?.toStringAsFixed(1) ?? '--';
