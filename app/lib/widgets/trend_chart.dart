import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import '../core/format.dart';
import '../core/theme.dart';

enum TrendRange {
  d1('1D', 'Past day', Duration(days: 1)),
  w1('1W', 'Past week', Duration(days: 7)),
  m1('1M', 'Past month', Duration(days: 30)),
  m3('3M', 'Past 3 months', Duration(days: 91)),
  m6('6M', 'Past 6 months', Duration(days: 182)),
  y1('1Y', 'Past year', Duration(days: 365)),
  y5('5Y', 'Past 5 years', Duration(days: 1826)),
  all('ALL', 'All time', null);

  const TrendRange(this.label, this.caption, this.span);
  final String label, caption;
  final Duration? span;
}

typedef TrendPoint = ({String date, double value});

/// Range charts open on (Settings > Default chart range).
TrendRange defaultTrendRange = TrendRange.m1;

/// Stock-page style value chart: headline value + change, scrubbable line, range chips.
class TrendChart extends StatefulWidget {
  const TrendChart({
    super.key,
    required this.points,
    required this.current,
    this.height = 150,
    this.ranges = TrendRange.values,
    this.initial,
    this.downIsGood = false,
  });

  /// Daily points, oldest first.
  final List<TrendPoint> points;
  final double current;
  final double height;
  final List<TrendRange> ranges;
  /// Defaults to [defaultTrendRange].
  final TrendRange? initial;

  /// For debts: a falling balance is shown in green.
  final bool downIsGood;

  @override
  State<TrendChart> createState() => _TrendChartState();
}

class _TrendChartState extends State<TrendChart> {
  int? _sel; // index being scrubbed; null = latest
  late TrendRange _range = widget.initial ?? defaultTrendRange;

  @override
  Widget build(BuildContext context) {
    // Ignore leading empty days (history starts when accounts were connected).
    final all = widget.points.skipWhile((p) => p.value == 0).toList();
    var live = all;
    if (_range.span != null && all.isNotEmpty) {
      final cutoff = DateTime.parse(all.last.date).subtract(_range.span!);
      // Keep the last point at/before the cutoff so the range starts from its opening value.
      final start = all.lastIndexWhere((p) => !DateTime.parse(p.date).isAfter(cutoff));
      live = all.sublist(start < 0 ? 0 : start);
    }
    final idx = (_sel != null && _sel! < live.length) ? _sel : null;
    final current = idx == null ? widget.current : live[idx].value;
    final first = live.isEmpty ? current : live.first.value;
    final delta = current - first;
    final pct = first == 0 ? null : delta / first.abs() * 100;
    final up = delta >= 0;
    final color = (up != widget.downIsGood) || delta == 0 ? kGain : kLoss;
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(money(current, whole: true),
          style: theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -1)),
      const SizedBox(height: 4),
      Row(children: [
        Icon(up ? Icons.arrow_drop_up : Icons.arrow_drop_down, color: color),
        Flexible(
          child: Text(
              '${money(delta.abs(), whole: true)}${pct == null ? '' : ' (${pct.abs().toStringAsFixed(2)}%)'}'
              '  ·  ${idx == null ? _range.caption : (idx == live.length - 1 ? 'today' : dayLabel(live[idx].date))}',
              style: TextStyle(color: color, fontWeight: FontWeight.w600)),
        ),
      ]),
      const SizedBox(height: 16),
      SizedBox(
        height: widget.height,
        child: live.length < 2
            ? Center(child: Text('Not enough history yet', style: TextStyle(color: theme.hintColor)))
            : LineChart(LineChartData(
                gridData: const FlGridData(show: false),
                titlesData: const FlTitlesData(show: false),
                borderData: FlBorderData(show: false),
                lineTouchData: LineTouchData(
                  handleBuiltInTouches: true,
                  touchCallback: (event, resp) {
                    if (!event.isInterestedForInteractions) {
                      if (_sel != null) setState(() => _sel = null);
                      return;
                    }
                    final spot = resp?.lineBarSpots;
                    if (spot != null && spot.isNotEmpty && spot.first.spotIndex != _sel) {
                      setState(() => _sel = spot.first.spotIndex);
                    }
                  },
                  getTouchedSpotIndicator: (bar, idxs) => [
                    for (final _ in idxs)
                      TouchedSpotIndicatorData(
                        FlLine(color: color.withValues(alpha: .5), strokeWidth: 1.5),
                        FlDotData(getDotPainter: (a, b, c, d) => FlDotCirclePainter(
                            radius: 5, color: color, strokeWidth: 3, strokeColor: theme.colorScheme.surface)),
                      )
                  ],
                  touchTooltipData: LineTouchTooltipData(
                    getTooltipItems: (spots) => [for (final _ in spots) null],
                  ),
                ),
                lineBarsData: [
                  LineChartBarData(
                    spots: [for (var i = 0; i < live.length; i++) FlSpot(i.toDouble(), live[i].value)],
                    isCurved: true,
                    curveSmoothness: .25,
                    preventCurveOverShooting: true,
                    color: color,
                    barWidth: 2.5,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(
                      show: true,
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [color.withValues(alpha: .25), color.withValues(alpha: 0)],
                      ),
                    ),
                  ),
                ],
              )),
      ),
      const SizedBox(height: 12),
      Row(children: [
        for (final r in widget.ranges)
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () => setState(() {
                _range = r;
                _sel = null;
              }),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 7),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: r == _range ? color.withValues(alpha: .15) : null,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(r.label,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: r == _range ? color : theme.hintColor,
                    )),
              ),
            ),
          ),
      ]),
    ]);
  }
}

/// Sum per-account daily series ({date, balance}) into one series, aligned by date.
List<TrendPoint> sumSeries(Iterable<List> seriesList) {
  final byDate = <String, double>{};
  for (final s in seriesList) {
    for (final p in s.cast<Map>()) {
      byDate[p['date']] = (byDate[p['date']] ?? 0) + (p['balance'] as num).toDouble();
    }
  }
  final dates = byDate.keys.toList()..sort();
  return [for (final d in dates) (date: d, value: byDate[d]!)];
}
