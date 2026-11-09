import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/api.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../widgets/sankey.dart';
import '../../widgets/ui.dart';

enum _Preset {
  thisMonth('This month'),
  lastMonth('Last month'),
  m3('3 months'),
  m6('6 months'),
  ytd('Year to date'),
  m12('12 months'),
  all('All time');

  const _Preset(this.label);
  final String label;

  ({String from, String to}) range(DateTime now) {
    String d(DateTime x) => x.toIso8601String().substring(0, 10);
    final today = DateTime(now.year, now.month, now.day);
    DateTime monthsBack(int n) => DateTime(now.year, now.month - n, 1);
    return switch (this) {
      _Preset.thisMonth => (from: d(monthsBack(0)), to: d(today)),
      _Preset.lastMonth => (from: d(monthsBack(1)), to: d(DateTime(now.year, now.month, 0))),
      _Preset.m3 => (from: d(monthsBack(2)), to: d(today)),
      _Preset.m6 => (from: d(monthsBack(5)), to: d(today)),
      _Preset.ytd => (from: d(DateTime(now.year, 1, 1)), to: d(today)),
      _Preset.m12 => (from: d(monthsBack(11)), to: d(today)),
      _Preset.all => (from: '2000-01-01', to: d(today)),
    };
  }
}

enum _View { spending, income, flow }

class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});
  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  _Preset _preset = _Preset.m3;
  _View _view = _View.spending;

  @override
  Widget build(BuildContext context) {
    final range = _preset.range(DateTime.now());
    final report = ref.watch(reportsProvider(range));
    return PageScaffold(
      title: 'Reports',
      onRefresh: () => ref.refresh(reportsProvider(range).future),
      body: cardStack([
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SegmentedButton<_View>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: _View.spending, label: Text('Spending'), icon: Icon(Icons.pie_chart_outline, size: 18)),
              ButtonSegment(value: _View.income, label: Text('Income'), icon: Icon(Icons.trending_up, size: 18)),
              ButtonSegment(value: _View.flow, label: Text('Flow'), icon: Icon(Icons.account_tree_outlined, size: 18)),
            ],
            selected: {_view},
            onSelectionChanged: (s) => setState(() => _view = s.first),
          ),
          DropdownButtonHideUnderline(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).colorScheme.outline),
                borderRadius: BorderRadius.circular(20),
              ),
              child: DropdownButton<_Preset>(
                value: _preset,
                borderRadius: BorderRadius.circular(12),
                items: [for (final p in _Preset.values) DropdownMenuItem(value: p, child: Text(p.label))],
                onChanged: (p) => setState(() => _preset = p!),
              ),
            ),
          ),
        ]),
        AsyncBody(report, builder: (d) => switch (_view) {
              _View.spending => _Spending(d),
              _View.income => _Income(d),
              _View.flow => _Flow(d),
            }),
      ]),
    );
  }
}

class _Spending extends StatelessWidget {
  const _Spending(this.d);
  final Map<String, dynamic> d;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final groups = (d['groups'] as List).cast<Map>();
    final total = (d['expenses'] as num).toDouble();
    final merchants = (d['merchants'] as List).cast<Map>();
    final monthly = (d['monthly'] as List).cast<Map>();
    if (groups.isEmpty) {
      return Card(child: Padding(padding: const EdgeInsets.all(24), child: Text('No spending in this period', style: TextStyle(color: theme.hintColor))));
    }
    final colors = {for (var i = 0; i < groups.length; i++) groups[i]['name'] as String: paletteAt(i)};
    return TwoColumn(
      breakpoint: 900,
      main: [
        SectionCard(
          title: 'Spending by group',
          trailing: money(total, whole: true),
          child: Wrap(
            spacing: 24,
            runSpacing: 16,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Donut(parts: [for (final g in groups) (g['name'] as String, (g['amount'] as num).toDouble(), colors[g['name']]!)], centerLabel: 'Spent'),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: Column(children: [
                  for (final g in groups)
                    AmountBar(
                      label: g['name'],
                      amount: (g['amount'] as num).toDouble(),
                      fraction: total > 0 ? (g['amount'] as num) / total : 0,
                      color: colors[g['name']]!,
                      detail: total > 0 ? '${((g['amount'] as num) / total * 100).toStringAsFixed(0)}%' : null,
                    ),
                ]),
              ),
            ],
          ),
        ),
        if (monthly.length > 1) SectionCard(title: 'By month', child: _StackedMonths(monthly, colors)),
      ],
      side: [
        SectionCard(
          title: 'Top merchants',
          child: Column(children: [
            for (final m in merchants)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(m['name'], maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text('${m['count']} transaction${m['count'] == 1 ? '' : 's'}',
                          style: TextStyle(fontSize: 12, color: theme.hintColor)),
                    ]),
                  ),
                  Text(money(m['amount'] as num, whole: true), style: const TextStyle(fontWeight: FontWeight.w700)),
                ]),
              ),
          ]),
        ),
      ],
    );
  }
}

class _StackedMonths extends StatelessWidget {
  const _StackedMonths(this.monthly, this.colors);
  final List<Map> monthly;
  final Map<String, Color> colors;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxY = monthly.fold<double>(1, (a, m) => (m['expenses'] as num) > a ? (m['expenses'] as num).toDouble() : a);
    return SizedBox(
      height: 220,
      child: BarChart(BarChartData(
        maxY: maxY * 1.1,
        gridData: FlGridData(
          drawVerticalLine: false,
          getDrawingHorizontalLine: (_) => FlLine(color: theme.dividerColor.withValues(alpha: .3), strokeWidth: 1),
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
            reservedSize: 24,
            getTitlesWidget: (x, _) => Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(monthShort(monthly[x.toInt()]['month']), style: TextStyle(fontSize: 11, color: theme.hintColor)),
            ),
          )),
        ),
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipColor: (_) => theme.colorScheme.surfaceContainerHighest,
            getTooltipItem: (g, gi, r, ri) => BarTooltipItem(
              '${monthLabel(monthly[g.x]['month'])}\n${money(r.toY, whole: true)}',
              TextStyle(color: theme.colorScheme.onSurface, fontWeight: FontWeight.w600, fontSize: 12),
            ),
          ),
        ),
        barGroups: [
          for (var i = 0; i < monthly.length; i++)
            () {
              var y = 0.0;
              final stack = <BarChartRodStackItem>[];
              for (final e in (monthly[i]['groups'] as Map).entries) {
                final v = (e.value as num).toDouble();
                stack.add(BarChartRodStackItem(y, y + v, colors[e.key] ?? kPalette.last));
                y += v;
              }
              return BarChartGroupData(x: i, barRods: [
                BarChartRodData(toY: y, width: 22, rodStackItems: stack, borderRadius: BorderRadius.circular(4)),
              ]);
            }(),
        ],
      )),
    );
  }
}

class _Income extends StatelessWidget {
  const _Income(this.d);
  final Map<String, dynamic> d;

  @override
  Widget build(BuildContext context) {
    final sources = (d['incomeSources'] as List).cast<Map>();
    final total = (d['income'] as num).toDouble();
    if (sources.isEmpty) {
      return Card(child: Padding(padding: const EdgeInsets.all(24), child: Text('No income in this period', style: TextStyle(color: Theme.of(context).hintColor))));
    }
    return SectionCard(
      title: 'Income by source',
      trailing: money(total, whole: true),
      child: Wrap(spacing: 24, runSpacing: 16, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Donut(parts: [
          for (var i = 0; i < sources.length; i++) (sources[i]['name'] as String, (sources[i]['amount'] as num).toDouble(), paletteAt(i + 3)),
        ], centerLabel: 'Earned'),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(children: [
            for (var i = 0; i < sources.length; i++)
              AmountBar(
                label: sources[i]['name'],
                amount: (sources[i]['amount'] as num).toDouble(),
                fraction: total > 0 ? (sources[i]['amount'] as num) / total : 0,
                color: paletteAt(i + 3),
              ),
          ]),
        ),
      ]),
    );
  }
}

class _Flow extends StatelessWidget {
  const _Flow(this.d);
  final Map<String, dynamic> d;

  @override
  Widget build(BuildContext context) {
    final s = d['sankey'] as Map;
    final links = s['links'] as List;
    return SectionCard(
      title: 'Where your money went',
      trailing: '${money(s['income'] as num, whole: true)} in · ${money(s['spent'] as num, whole: true)} out',
      child: links.isEmpty
          ? const Padding(padding: EdgeInsets.all(24), child: Text('No income or spending in this period.'))
          : SankeyChart(nodes: s['nodes'], links: links, onNodeTap: (_, _) {}),
    );
  }
}
