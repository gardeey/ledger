import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/api.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../main.dart' show themeModeProvider;
import '../../widgets/sankey.dart';
import '../../widgets/trend_chart.dart';
import '../../widgets/ui.dart';
import '../shell.dart' show Pg, tabProvider;

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dash = ref.watch(dashboardProvider);
    final mode = ref.watch(themeModeProvider);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 68,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_greeting(), style: const TextStyle(fontWeight: FontWeight.w800)),
          Text(fullDay(DateTime.now()),
              style: TextStyle(fontSize: 13, color: Theme.of(context).hintColor, fontWeight: FontWeight.w500)),
        ]),
        actions: [
          IconButton(
            tooltip: 'Toggle theme',
            icon: Icon(dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
            onPressed: () => ref.read(themeModeProvider.notifier).set(
                mode == ThemeMode.dark || (mode == ThemeMode.system && dark)
                    ? ThemeMode.light
                    : ThemeMode.dark),
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () {
              ref.invalidate(dashboardProvider);
              ref.invalidate(transactionsProvider);
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: dash.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Could not reach the bridge.\n$e', textAlign: TextAlign.center),
          ),
        ),
        data: (d) {
          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(transactionsProvider);
              return ref.refresh(dashboardProvider.future);
            },
            child: LayoutBuilder(builder: (context, c) {
              final wide = c.maxWidth >= 1000;
              final Widget content = wide
                  // Two columns on desktop: trends on the left, "what needs attention" on the right.
                  ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(flex: 3, child: cardStack([_NetWorthCard(d), _SpendingCard(d), _SankeyCard(d)])),
                      const SizedBox(width: 16),
                      Expanded(flex: 2, child: cardStack([const _RecentCard(), _BudgetCard(d), _FlowCard(d)])),
                    ])
                  : cardStack([_NetWorthCard(d), _SpendingCard(d), const _RecentCard(), _SankeyCard(d), _FlowCard(d), _BudgetCard(d)]);
              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                children: [
                  Center(
                    child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1280), child: content),
                  ),
                ],
              );
            }),
          );
        },
      ),
    );
  }
}

String _greeting() {
  final h = DateTime.now().hour;
  return h < 12 ? 'Good morning' : h < 18 ? 'Good afternoon' : 'Good evening';
}

class _NetWorthCard extends StatelessWidget {
  const _NetWorthCard(this.d);
  final Map<String, dynamic> d;

  @override
  Widget build(BuildContext context) {
    final nw = d['netWorth'] as Map;
    final series = [
      for (final p in (nw['series'] as List).cast<Map>()) (date: p['date'] as String, value: (p['net'] as num).toDouble()),
    ];
    return SectionCard(
      title: 'Net worth',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        TrendChart(points: series, current: (nw['current'] as num).toDouble()),
        const SizedBox(height: 18),
        Divider(height: 1, color: Theme.of(context).dividerColor.withValues(alpha: .5)),
        const SizedBox(height: 18),
        AccountBreakdown((d['accounts'] as List).cast<Map>()),
      ]),
    );
  }
}

/// Monarch-style: cumulative spending this month, drawn over last month's pace.
class _SpendingCard extends StatelessWidget {
  const _SpendingCard(this.d);
  final Map<String, dynamic> d;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = d['spending'] as Map;
    List<double> nums(String k) => [for (final v in s[k] as List) (v as num).toDouble()];
    final cur = nums('thisMonth');
    final prev = nums('lastMonth');
    final spent = cur.isEmpty ? 0.0 : cur.last;
    final prevAt = prev.isEmpty ? 0.0 : prev[(cur.length.clamp(1, prev.length)) - 1];
    final diff = spent - prevAt;
    final muted = theme.hintColor.withValues(alpha: .6);
    final days = [cur.length, prev.length].reduce((a, b) => a > b ? a : b);
    List<FlSpot> spots(List<double> v) => [for (var i = 0; i < v.length; i++) FlSpot(i.toDouble(), v[i])];
    return SectionCard(
      title: 'Spending',
      trailing: monthLabel(s['month']),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(money(spent, whole: true),
            style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -.5)),
        const SizedBox(height: 2),
        Text(
          prev.isEmpty
              ? 'this month'
              : '${money(diff.abs(), whole: true)} ${diff > 0 ? 'more' : 'less'} than this time last month',
          style: TextStyle(
              color: prev.isEmpty ? theme.hintColor : (diff > 0 ? kLoss : kGain), fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 170,
          child: days < 2
              ? Center(child: Text('Not enough data yet', style: TextStyle(color: theme.hintColor)))
              : LineChart(LineChartData(
                  minX: 0,
                  maxX: (days - 1).toDouble(),
                  minY: 0,
                  gridData: FlGridData(
                    drawVerticalLine: false,
                    getDrawingHorizontalLine: (_) =>
                        FlLine(color: theme.dividerColor.withValues(alpha: .35), strokeWidth: 1),
                  ),
                  borderData: FlBorderData(show: false),
                  titlesData: FlTitlesData(
                    topTitles: const AxisTitles(),
                    rightTitles: const AxisTitles(),
                    leftTitles: AxisTitles(sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 44,
                      getTitlesWidget: (v, meta) => v == meta.max
                          ? const SizedBox.shrink()
                          : Text(v == 0 ? r'$0' : moneyCompact(v), style: TextStyle(fontSize: 10.5, color: theme.hintColor)),
                    )),
                    bottomTitles: AxisTitles(sideTitles: SideTitles(
                      showTitles: true,
                      interval: 7,
                      reservedSize: 22,
                      getTitlesWidget: (v, _) => Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text('${v.toInt() + 1}', style: TextStyle(fontSize: 11, color: theme.hintColor)),
                      ),
                    )),
                  ),
                  lineTouchData: LineTouchData(
                    touchTooltipData: LineTouchTooltipData(
                      getTooltipColor: (_) => theme.colorScheme.surfaceContainerHighest,
                      getTooltipItems: (spots) => [
                        for (final sp in spots)
                          LineTooltipItem(
                            '${sp.barIndex == 1 ? 'This month' : 'Last month'}  ${money(sp.y, whole: true)}',
                            TextStyle(
                              color: sp.barIndex == 1 ? kLoss : theme.hintColor,
                              fontWeight: FontWeight.w600,
                              fontSize: 12,
                            ),
                          ),
                      ],
                    ),
                  ),
                  lineBarsData: [
                    LineChartBarData(
                      spots: spots(prev),
                      color: muted,
                      barWidth: 2,
                      dashArray: [5, 4],
                      dotData: const FlDotData(show: false),
                    ),
                    LineChartBarData(
                      spots: spots(cur),
                      color: kLoss,
                      barWidth: 2.5,
                      dotData: FlDotData(
                        checkToShowDot: (spot, bar) => spot.x == bar.spots.last.x,
                        getDotPainter: (a, b, c, e) => FlDotCirclePainter(
                            radius: 4, color: kLoss, strokeWidth: 2, strokeColor: theme.colorScheme.surface),
                      ),
                      belowBarData: BarAreaData(
                        show: true,
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [kLoss.withValues(alpha: .18), kLoss.withValues(alpha: 0)],
                        ),
                      ),
                    ),
                  ],
                )),
        ),
        const SizedBox(height: 10),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          const LegendDot(kLoss, 'This month'),
          const SizedBox(width: 16),
          LegendDot(muted, 'Last month'),
        ]),
      ]),
    );
  }
}

class _RecentCard extends ConsumerWidget {
  const _RecentCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final txs = ref.watch(transactionsProvider(txQuery(limit: 12)));
    return SectionCard(
      title: 'Recent transactions',
      action: TextButton(
        onPressed: () => ref.read(tabProvider.notifier).go(Pg.transactions),
        child: const Text('View all'),
      ),
      child: txs.when(
        loading: () => const SizedBox(height: 120, child: Center(child: CircularProgressIndicator())),
        error: (e, _) => Text(errText(e), style: TextStyle(color: theme.hintColor)),
        data: (all) {
          // Skip zero-amount bookkeeping rows (e.g. "Starting Balance") that aren't real activity.
          final list = all.where((t) => (t['amount'] as num) != 0).take(6).toList();
          return list.isEmpty
              ? Text('No transactions yet', style: TextStyle(color: theme.hintColor))
              : Column(children: [for (final t in list) TxRow(t)]);
        },
      ),
    );
  }
}

/// Money flow for one month. Opens on the dashboard's month; the arrows step through
/// other months via /reports, which returns the same sankey shape.
class _SankeyCard extends ConsumerStatefulWidget {
  const _SankeyCard(this.d);
  final Map<String, dynamic> d;
  @override
  ConsumerState<_SankeyCard> createState() => _SankeyCardState();
}

class _SankeyCardState extends ConsumerState<_SankeyCard> {
  SankeyNode? _sel;
  String? _month; // null = the dashboard's month

  String _shift(String ym, int by) {
    final d = DateTime.parse('$ym-01');
    final m = DateTime(d.year, d.month + by);
    return '${m.year}-${m.month.toString().padLeft(2, '0')}';
  }

  void _go(String m) => setState(() { _month = m == widget.d['month'] ? null : m; _sel = null; });

  @override
  Widget build(BuildContext context) {
    final month = _month ?? widget.d['month'] as String;
    final now = DateTime.now();
    final latest = '${now.year}-${now.month.toString().padLeft(2, '0')}';
    final series = (widget.d['netWorth'] as Map)['series'] as List;
    final earliest = series.isEmpty ? latest : (series.first['date'] as String).substring(0, 7);
    final to = DateTime.parse('${_shift(month, 1)}-01').subtract(const Duration(days: 1));
    final data = _month == null
        ? AsyncValue.data(widget.d)
        : ref.watch(reportsProvider((from: '$month-01', to: to.toIso8601String().substring(0, 10))));
    final s = data.value?['sankey'] as Map?;
    final income = (s?['income'] as num?)?.toDouble() ?? 0;
    final spent = (s?['spent'] as num?)?.toDouble() ?? 0;
    final hint = Theme.of(context).hintColor;
    return SectionCard(
      title: 'Where ${monthLabel(month)} went',
      trailing: s == null ? null : '${money(income, whole: true)} in · ${money(spent, whole: true)} out',
      action: Row(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(width: 4),
        IconButton(
          tooltip: 'Previous month', visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.chevron_left),
          onPressed: month.compareTo(earliest) > 0 ? () => _go(_shift(month, -1)) : null,
        ),
        IconButton(
          tooltip: 'Next month', visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.chevron_right),
          onPressed: month.compareTo(latest) < 0 ? () => _go(_shift(month, 1)) : null,
        ),
      ]),
      child: data.when(
        loading: () => const SizedBox(height: 240, child: Center(child: CircularProgressIndicator())),
        error: (e, _) => Padding(padding: const EdgeInsets.all(24), child: Text('Could not load this month.\n$e')),
        data: (_) {
          final links = s!['links'] as List;
          final deficit = income - spent - ((s['invested'] as num?)?.toDouble() ?? 0);
          if (links.isEmpty) {
            return const Padding(padding: EdgeInsets.all(24), child: Text('No income or spending this month.'));
          }
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SankeyChart(
              key: ValueKey(month),
              nodes: s['nodes'], links: links,
              onNodeTap: (n, _) => setState(() => _sel = n),
            ),
            if (deficit < 0) ...[
              const SizedBox(height: 8),
              Text('${money(-deficit, whole: true)} more went out than came in. The red "From savings" flow covers the gap.',
                  style: TextStyle(fontSize: 12, color: hint)),
            ],
            if (_sel != null) ...[
              const SizedBox(height: 8),
              Text(
                '${_sel!.label}: ${money(_sel!.value)}'
                '${income > 0 && _sel!.kind != 'total' ? '  ·  ${(100 * _sel!.value / income).toStringAsFixed(0)}% of income' : ''}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
          ]);
        },
      ),
    );
  }
}

class _FlowCard extends StatelessWidget {
  const _FlowCard(this.d);
  final Map<String, dynamic> d;
  @override
  Widget build(BuildContext context) {
    final flow = (d['flow'] as List).cast<Map>();
    final live = flow.skipWhile((f) => (f['income'] as num) == 0 && (f['expenses'] as num) == 0).toList();
    final theme = Theme.of(context);
    final maxY = live.fold<double>(0, (m, f) => [m, (f['income'] as num).toDouble(), (f['expenses'] as num).toDouble()].reduce((a, b) => a > b ? a : b));
    final last = live.isEmpty ? null : live.last;
    return SectionCard(
      title: 'Income vs expenses',
      trailing: last?['savingsRate'] == null ? null : 'Savings rate ${last!['savingsRate']}%',
      child: Column(children: [
        SizedBox(
          height: 180,
          child: live.isEmpty
              ? const Center(child: Text('No data yet'))
              : BarChart(BarChartData(
                  maxY: maxY * 1.1,
                  gridData: const FlGridData(show: false),
                  borderData: FlBorderData(show: false),
                  titlesData: FlTitlesData(
                    leftTitles: const AxisTitles(), topTitles: const AxisTitles(), rightTitles: const AxisTitles(),
                    bottomTitles: AxisTitles(sideTitles: SideTitles(
                      showTitles: true, reservedSize: 24,
                      getTitlesWidget: (v, _) => Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(monthShort(live[v.toInt()]['month']), style: TextStyle(fontSize: 11, color: theme.hintColor)),
                      ),
                    )),
                  ),
                  barTouchData: BarTouchData(
                    touchTooltipData: BarTouchTooltipData(
                      getTooltipItem: (g, gi, r, ri) => BarTooltipItem(
                        '${ri == 0 ? 'Income' : 'Expenses'}\n${money(r.toY, whole: true)}',
                        TextStyle(color: theme.colorScheme.onSurface, fontWeight: FontWeight.w600, fontSize: 12),
                      ),
                    ),
                  ),
                  barGroups: [
                    for (var i = 0; i < live.length; i++)
                      BarChartGroupData(x: i, barsSpace: 3, barRods: [
                        BarChartRodData(toY: (live[i]['income'] as num).toDouble(), color: kGain, width: 9, borderRadius: BorderRadius.circular(3)),
                        BarChartRodData(toY: (live[i]['expenses'] as num).toDouble(), color: kLoss, width: 9, borderRadius: BorderRadius.circular(3)),
                      ]),
                  ],
                )),
        ),
        const SizedBox(height: 10),
        const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          LegendDot(kGain, 'Income'), SizedBox(width: 16), LegendDot(kLoss, 'Expenses'),
        ]),
      ]),
    );
  }
}

class _BudgetCard extends StatelessWidget {
  const _BudgetCard(this.d);
  final Map<String, dynamic> d;
  @override
  Widget build(BuildContext context) {
    final groups = (d['budget'] as List).cast<Map>().where((g) => (g['budgeted'] as num) > 0 || (g['spent'] as num) > 0).toList();
    return SectionCard(
      title: 'Budget',
      trailing: monthLabel(d['month']),
      child: groups.isEmpty
          ? Text('No budgeted amounts set for this month.', style: TextStyle(color: Theme.of(context).hintColor))
          : Column(children: [
              for (final g in groups)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: _Bar(g['group'], (g['spent'] as num).toDouble(), (g['budgeted'] as num).toDouble()),
                ),
            ]),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar(this.label, this.spent, this.budgeted);
  final String label;
  final double spent, budgeted;
  @override
  Widget build(BuildContext context) {
    final over = budgeted > 0 && spent > budgeted;
    final frac = budgeted > 0 ? (spent / budgeted).clamp(0.0, 1.0) : 1.0;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600))),
        Text('${money(spent, whole: true)} / ${money(budgeted, whole: true)}',
            style: TextStyle(color: over ? kLoss : Theme.of(context).hintColor, fontSize: 13)),
      ]),
      const SizedBox(height: 6),
      ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: LinearProgressIndicator(value: frac, minHeight: 8, color: over ? kLoss : kGain,
            backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest),
      ),
    ]);
  }
}
