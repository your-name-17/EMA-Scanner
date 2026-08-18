import 'dart:math' as math;

class ConvergeResult {
  final bool ok;
  final double spread;

  ConvergeResult(this.ok, this.spread);
}

ConvergeResult isDense6(List<double> averages, double threshold) {
  final mn = averages.reduce(math.min);
  final mx = averages.reduce(math.max);
  final mnAbs = mn.abs();
  if (mnAbs == 0) {
    return ConvergeResult(false, double.infinity);
  }
  final spread = (mx - mn) / mnAbs;
  return ConvergeResult(spread <= threshold, spread);
}

double? ema(List<double> values, int span) {
  if (span <= 0) throw ArgumentError('span 必须为正数');
  if (values.length < span) return null;

  final alpha = 2.0 / (span + 1.0);
  var e = values.first;
  for (var i = 1; i < values.length; i++) {
    e = alpha * values[i] + (1.0 - alpha) * e;
  }
  return e;
}

double? ma(List<double> values, int span) {
  if (span <= 0) throw ArgumentError('span 必须为正数');
  if (values.length < span) return null;

  final window = values.sublist(values.length - span);
  return window.reduce((a, b) => a + b) / span.toDouble();
}

List<double> emaSeries(List<double> values, int span) {
  if (values.isEmpty) return const [];
  final alpha = 2.0 / (span + 1.0);
  final series = <double>[values.first];
  var e = values.first;
  for (var i = 1; i < values.length; i++) {
    e = alpha * values[i] + (1.0 - alpha) * e;
    series.add(e);
  }
  return series;
}

List<double?> maSeries(List<double> values, int span) {
  final series = List<double?>.filled(values.length, null);
  if (values.length < span) return series;

  var sum = 0.0;
  for (var i = 0; i < values.length; i++) {
    sum += values[i];
    if (i >= span) sum -= values[i - span];
    if (i >= span - 1) series[i] = sum / span;
  }
  return series;
}

ConvergeResult? dense6AtIndex(
  int index,
  List<double> ema20s,
  List<double> ema60s,
  List<double> ema120s,
  List<double?> ma20s,
  List<double?> ma60s,
  List<double?> ma120s,
  double threshold,
) {
  if (index < 119) return null;
  final ma20 = ma20s[index];
  final ma60 = ma60s[index];
  final ma120 = ma120s[index];
  if (ma20 == null || ma60 == null || ma120 == null) return null;

  return isDense6([
    ema20s[index],
    ema60s[index],
    ema120s[index],
    ma20,
    ma60,
    ma120,
  ], threshold);
}
