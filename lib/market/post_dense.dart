import 'dart:math' as math;

import 'indicators.dart';

class AnalysisKlineBar {
  final DateTime openTimeUtc;
  final double close;

  const AnalysisKlineBar({required this.openTimeUtc, required this.close});
}

const int denseCrossWindowBars = 15;

(int, int) denseCrossWindow(int denseIdx, int length) {
  final start = math.max(0, denseIdx - denseCrossWindowBars);
  final end = math.min(length - 1, denseIdx + denseCrossWindowBars);
  return (start, end);
}

String? detectFirstCrossInWindow(
  List<double> fast,
  List<double> slow,
  int startIdx,
  int endIdx,
) {
  if (startIdx >= endIdx) return null;
  for (var i = startIdx + 1; i <= endIdx; i++) {
    if (fast[i - 1] <= slow[i - 1] && fast[i] > slow[i]) return 'up';
    if (fast[i - 1] >= slow[i - 1] && fast[i] < slow[i]) return 'down';
  }
  return null;
}

String? detectFirstCrossInWindowNullable(
  List<double?> fast,
  List<double?> slow,
  int startIdx,
  int endIdx,
) {
  if (startIdx >= endIdx) return null;
  for (var i = startIdx + 1; i <= endIdx; i++) {
    final pf = fast[i - 1];
    final cf = fast[i];
    final ps = slow[i - 1];
    final cs = slow[i];
    if (pf == null || cf == null || ps == null || cs == null) continue;
    if (pf <= ps && cf > cs) return 'up';
    if (pf >= ps && cf < cs) return 'down';
  }
  return null;
}

class CrossVoteSummary {
  final String? direction;
  final int upVotes;
  final int downVotes;

  const CrossVoteSummary({
    required this.direction,
    required this.upVotes,
    required this.downVotes,
  });
}

CrossVoteSummary resolveComprehensiveCrossDirection({
  required List<double> ema20s,
  required List<double> ema60s,
  required List<double> ema120s,
  required List<double?> ma20s,
  required List<double?> ma60s,
  required List<double?> ma120s,
  required int denseIdx,
  required int length,
}) {
  final (windowStart, windowEnd) = denseCrossWindow(denseIdx, length);
  return resolveComprehensiveCrossDirectionInWindow(
    ema20s: ema20s,
    ema60s: ema60s,
    ema120s: ema120s,
    ma20s: ma20s,
    ma60s: ma60s,
    ma120s: ma120s,
    windowStart: windowStart,
    windowEnd: windowEnd,
  );
}

CrossVoteSummary resolveComprehensiveCrossDirectionInWindow({
  required List<double> ema20s,
  required List<double> ema60s,
  required List<double> ema120s,
  required List<double?> ma20s,
  required List<double?> ma60s,
  required List<double?> ma120s,
  required int windowStart,
  required int windowEnd,
}) {
  if (windowStart >= windowEnd) {
    return const CrossVoteSummary(direction: null, upVotes: 0, downVotes: 0);
  }

  var upVotes = 0;
  var downVotes = 0;

  void vote(String? direction) {
    if (direction == 'up') {
      upVotes += 1;
    } else if (direction == 'down') {
      downVotes += 1;
    }
  }

  vote(detectFirstCrossInWindow(ema20s, ema60s, windowStart, windowEnd));
  vote(detectFirstCrossInWindow(ema20s, ema120s, windowStart, windowEnd));
  vote(detectFirstCrossInWindow(ema60s, ema120s, windowStart, windowEnd));
  vote(detectFirstCrossInWindowNullable(ma20s, ma60s, windowStart, windowEnd));
  vote(detectFirstCrossInWindowNullable(ma20s, ma120s, windowStart, windowEnd));
  vote(detectFirstCrossInWindowNullable(ma60s, ma120s, windowStart, windowEnd));

  if (upVotes == 0 || upVotes <= downVotes) {
    return CrossVoteSummary(
      direction: null,
      upVotes: upVotes,
      downVotes: downVotes,
    );
  }

  return CrossVoteSummary(
    direction: 'up',
    upVotes: upVotes,
    downVotes: downVotes,
  );
}

class PostDenseTrendSummary {
  final String direction;
  final double denseSpreadPct;
  final int barsSinceDense;
  final double netMovePct;
  final double alongMa20Pct;

  const PostDenseTrendSummary({
    required this.direction,
    required this.denseSpreadPct,
    required this.barsSinceDense,
    required this.netMovePct,
    required this.alongMa20Pct,
  });

  Map<String, dynamic> toJson() => {
    'direction': direction,
    'denseSpreadPct': denseSpreadPct,
    'barsSinceDense': barsSinceDense,
    'netMovePct': netMovePct,
    'alongMa20Pct': alongMa20Pct,
  };
}

class _IndicatorContext {
  final List<double> closes;
  final List<double> ema20s;
  final List<double> ema60s;
  final List<double> ema120s;
  final List<double?> ma20s;
  final List<double?> ma60s;
  final List<double?> ma120s;
  final int searchStart;

  _IndicatorContext._({
    required this.closes,
    required this.ema20s,
    required this.ema60s,
    required this.ema120s,
    required this.ma20s,
    required this.ma60s,
    required this.ma120s,
    required this.searchStart,
  });

  factory _IndicatorContext.fromBars(List<AnalysisKlineBar> bars) {
    final closes = bars.map((b) => b.close).toList(growable: false);
    return _IndicatorContext._(
      closes: closes,
      ema20s: emaSeries(closes, 20),
      ema60s: emaSeries(closes, 60),
      ema120s: emaSeries(closes, 120),
      ma20s: maSeries(closes, 20),
      ma60s: maSeries(closes, 60),
      ma120s: maSeries(closes, 120),
      searchStart: 119,
    );
  }
}

PostDenseTrendSummary? detectPostDenseTrend(
  List<AnalysisKlineBar> bars, {
  required double threshold,
}) {
  if (bars.length < 122 || threshold <= 0) return null;

  final ctx = _IndicatorContext.fromBars(bars);
  int? denseEndIdx;

  for (var i = ctx.closes.length - 2; i >= ctx.searchStart; i--) {
    final dense = dense6AtIndex(
      i,
      ctx.ema20s,
      ctx.ema60s,
      ctx.ema120s,
      ctx.ma20s,
      ctx.ma60s,
      ctx.ma120s,
      threshold,
    );
    if (dense != null && dense.ok) {
      denseEndIdx = i;
      break;
    }
  }

  if (denseEndIdx == null) return null;

  final trendEndIdx = ctx.closes.length - 1;
  final dense = dense6AtIndex(
    denseEndIdx,
    ctx.ema20s,
    ctx.ema60s,
    ctx.ema120s,
    ctx.ma20s,
    ctx.ma60s,
    ctx.ma120s,
    threshold,
  );
  if (dense == null || !dense.ok) return null;

  final barsSinceDense = trendEndIdx - denseEndIdx;
  if (barsSinceDense < 2) return null;

  final crossSummary = resolveComprehensiveCrossDirection(
    ema20s: ctx.ema20s,
    ema60s: ctx.ema60s,
    ema120s: ctx.ema120s,
    ma20s: ctx.ma20s,
    ma60s: ctx.ma60s,
    ma120s: ctx.ma120s,
    denseIdx: denseEndIdx,
    length: trendEndIdx + 1,
  );
  final crossDirection = crossSummary.direction;
  if (crossDirection != 'up') return null;

  final anchor = ctx.closes[denseEndIdx];
  final endClose = ctx.closes[trendEndIdx];
  if (anchor == 0 || endClose <= anchor) return null;

  final netMovePct = (endClose - anchor) / anchor.abs() * 100.0;
  if (netMovePct < threshold * 100.0 * 0.3) return null;

  final ma20AtDense = ctx.ma20s[denseEndIdx];
  final ma20AtEnd = ctx.ma20s[trendEndIdx];
  if (ma20AtDense == null || ma20AtEnd == null) return null;
  if (ma20AtEnd <= ma20AtDense) return null;

  var alongMa20Count = 0;
  var totalBars = 0;

  for (var i = denseEndIdx + 1; i <= trendEndIdx; i++) {
    final price = ctx.closes[i];
    final ma20 = ctx.ma20s[i];
    final ma120 = ctx.ma120s[i];
    if (ma20 == null || ma120 == null) continue;

    final prevClose = ctx.closes[i - 1];
    final prevMa120 = ctx.ma120s[i - 1];
    if (prevMa120 != null) {
      if (prevClose >= prevMa120 && price < ma120) {
        return null;
      }
    }

    totalBars += 1;
    final ma20Abs = ma20.abs();
    if (ma20Abs == 0) continue;

    final signedDev = (price - ma20) / ma20Abs;
    if (signedDev >= -threshold) alongMa20Count += 1;
  }

  if (totalBars < 2) return null;

  final alongMa20Pct = alongMa20Count / totalBars * 100.0;
  if (alongMa20Pct < 75.0) return null;

  return PostDenseTrendSummary(
    direction: 'up',
    denseSpreadPct: dense.spread * 100.0,
    barsSinceDense: barsSinceDense,
    netMovePct: netMovePct,
    alongMa20Pct: alongMa20Pct,
  );
}
