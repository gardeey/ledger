import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/api.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../widgets/ui.dart';

class CashFlowScreen extends ConsumerStatefulWidget {
  const CashFlowScreen({super.key});
  @override
  ConsumerState<CashFlowScreen> createState() => _CashFlowScreenState();
}

class _CashFlowScreenState extends ConsumerState<CashFlowScreen> {
  int? _sel; // selected month index; null = latest

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: 'Cash flow',
      actions: [
        IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: () => ref.invalidate(cashflowProvider)),
      ],
      onRefresh: () => ref.refresh(cashflowProvider.future),
      body: AsyncBody(ref.watch(cashflowProvider), builder: (d) {
        final months = (d['months'] as List).cast<Map>();
        if (months.isEmpty) return const Center(child: Text('No transactions yet'));
        final i = (_sel ?? months.length - 1).clamp(0, months.length - 1);
        final m = months[i];
        final income = (m['income'] as num).toDouble();
        final expenses = (m['expenses'] as num).toDouble();
        final savings = (m['savings'] as num).toDouble();
        return cardStack([
          SectionCard(
            title: 'Income vs expenses',
            trailing: 'Tap a month',
            child: _MonthBars(months: months, selected: i, onSelect: (x) => setState(() => _sel = x)),
          ),
          Row(children: [
            Text(monthLabel(m['month']), style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          ]),
          StatRow([
            StatTile('Income', money(income, whole: true), color: kGain),
            StatTile('Expenses', money(expenses, whole: true), color: kLoss),
            StatTile('Total savings', money(savings, whole: true), color: savings >= 0 ? null : kLoss),
            StatTile('Savings rate', m['savingsRate'] == null ? '—' : '${m['savingsRate']}%',
                sub: (m['invested'] as num) > 0 ? '${money(m['invested'] as num, whole: true)} invested' : null),
          ]),
          TwoColumn(
            breakpoint: 860,
            main: [_ExpensesCard(m)],
            side: [_IncomeCard(m)],
          ),
        ]);
      }),
    );
  }
}

class _MonthBars extends StatelessWidget {
  const _MonthBars({required this.months, required this.selected, required this.onSelect});
  final List<Map> months;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    double v(Map m, String k) => (m[k] as num).toDouble();
    final maxY = months.fold<double>(1, (a, m) => [a, v(m, 'income'), v(m, 'expenses')].reduce((x, y) => x > y ? x : y));
    return Column(children: [
      SizedBox(
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
                child: Text(monthShort(months[x.toInt()]['month']),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: x.toInt() == selected ? FontWeight.w800 : FontWeight.w400,
                      color: x.toInt() == selected ? theme.colorScheme.onSurface : theme.hintColor,
                    )),
              ),
            )),
          ),
          barTouchData: BarTouchData(
            touchCallback: (e, r) {
              final g = r?.spot?.touchedBarGroupIndex;
              if (e is FlTapUpEvent && g != null) onSelect(g);
            },
            touchTooltipData: BarTouchTooltipData(
              getTooltipColor: (_) => theme.colorScheme.surfaceContainerHighest,
              getTooltipItem: (g, gi, r, ri) => BarTooltipItem(
                '${ri == 0 ? 'Income' : 'Expenses'}\n${money(r.toY, whole: true)}',
                TextStyle(color: theme.colorScheme.onSurface, fontWeight: FontWeight.w600, fontSize: 12),
              ),
            ),
          ),
          barGroups: [
            for (var i = 0; i < months.length; i++)
              BarChartGroupData(x: i, barsSpace: 3, barRods: [
                BarChartRodData(
                  toY: v(months[i], 'income'),
                  color: kGain.withValues(alpha: i == selected ? 1 : .35),
                  width: 12,
                  borderRadius: BorderRadius.circular(3),
                ),
                BarChartRodData(
                  toY: v(months[i], 'expenses'),
                  color: kLoss.withValues(alpha: i == selected ? 1 : .35),
                  width: 12,
                  borderRadius: BorderRadius.circular(3),
                ),
              ]),
          ],
        )),
      ),
      const SizedBox(height: 10),
      const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        LegendDot(kGain, 'Income'),
        SizedBox(width: 16),
        LegendDot(kLoss, 'Expenses'),
      ]),
    ]);
  }
}

class _ExpensesCard extends StatelessWidget {
  const _ExpensesCard(this.m);
  final Map m;

  @override
  Widget build(BuildContext context) {
    final groups = (m['groups'] as List).cast<Map>();
    final total = (m['expenses'] as num).toDouble();
    return SectionCard(
      title: 'Expenses',
      trailing: money(total, whole: true),
      child: groups.isEmpty
          ? Text('No spending this month', style: TextStyle(color: Theme.of(context).hintColor))
          : Column(children: [
              for (var i = 0; i < groups.length; i++) _GroupTile(groups[i], total, paletteAt(i)),
            ]),
    );
  }
}

/// A spending group; expands to its categories.
class _GroupTile extends StatefulWidget {
  const _GroupTile(this.g, this.total, this.color);
  final Map g;
  final double total;
  final Color color;

  @override
  State<_GroupTile> createState() => _GroupTileState();
}

class _GroupTileState extends State<_GroupTile> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final g = widget.g;
    final amount = (g['amount'] as num).toDouble();
    final cats = (g['categories'] as List).cast<Map>();
    final single = cats.length <= 1 && (cats.isEmpty || cats.first['name'] == g['name']);
    return Column(children: [
      InkWell(
        onTap: single ? null : () => setState(() => _open = !_open),
        child: Row(children: [
          Expanded(
            child: AmountBar(
              label: g['name'],
              amount: amount,
              fraction: widget.total > 0 ? amount / widget.total : 0,
              color: widget.color,
              detail: widget.total > 0 ? '${(amount / widget.total * 100).toStringAsFixed(0)}%' : null,
            ),
          ),
          SizedBox(
            width: 28,
            child: single ? null : Icon(_open ? Icons.expand_less : Icons.expand_more, size: 20),
          ),
        ]),
      ),
      if (_open)
        Padding(
          padding: const EdgeInsets.only(left: 16, right: 28, bottom: 6),
          child: Column(children: [
            for (final c in cats)
              AmountBar(
                label: c['name'],
                amount: (c['amount'] as num).toDouble(),
                fraction: amount > 0 ? (c['amount'] as num) / amount : 0,
                color: widget.color.withValues(alpha: .6),
              ),
          ]),
        ),
    ]);
  }
}

class _IncomeCard extends StatelessWidget {
  const _IncomeCard(this.m);
  final Map m;

  @override
  Widget build(BuildContext context) {
    final sources = (m['incomeSources'] as List).cast<Map>();
    final total = (m['income'] as num).toDouble();
    return SectionCard(
      title: 'Income',
      trailing: money(total, whole: true),
      child: sources.isEmpty
          ? Text('No income this month', style: TextStyle(color: Theme.of(context).hintColor))
          : Column(children: [
              for (final s in sources)
                AmountBar(
                  label: s['name'],
                  amount: (s['amount'] as num).toDouble(),
                  fraction: total > 0 ? (s['amount'] as num) / total : 0,
                  color: kGain,
                ),
            ]),
    );
  }
}
