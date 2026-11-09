import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/api.dart';
import '../core/format.dart';
import '../core/theme.dart';

/// Account types from the bridge, in display order: label + colour.
const kAccountTypes = <String, (String, Color)>{
  'cash': ('Cash', Color(0xFF5B8DEF)),
  'investment': ('Investments', Color(0xFF2EC4B6)),
  'property': ('Real estate', Color(0xFF9B6BDF)),
  'vehicle': ('Vehicles', Color(0xFFE0B341)),
  'other': ('Other assets', Color(0xFF7FB069)),
  'credit': ('Credit cards', Color(0xFFF2994A)),
  'loan': ('Loans', Color(0xFFEB5E8B)),
};
const kLiabilityTypes = {'credit', 'loan'};

/// Visible accounts from the /accounts payload, flattened.
List<Map> allAccounts(Map d) => [for (final g in (d['groups'] as List).cast<Map>()) ...(g['accounts'] as List).cast<Map>()];

Color paletteAt(int i) => kPalette[i % kPalette.length];

/// Account names from the bank look like "TFSA (1234)"; split off the mask for display.
(String, String?) splitAccountName(String name) {
  final m = RegExp(r'^(.*?)\s*\(([^()]*)\)$').firstMatch(name);
  return m == null ? (name, null) : (m.group(1)!, m.group(2));
}

/// Standard page: app bar + centred, width-capped, pull-to-refresh list.
class PageScaffold extends StatelessWidget {
  const PageScaffold({
    super.key,
    required this.title,
    required this.body,
    this.actions = const [],
    this.onRefresh,
    this.maxWidth = 1100,
    this.floatingActionButton,
  });
  final String title;
  final Widget body;
  final List<Widget> actions;
  final Future<void> Function()? onRefresh;
  final double maxWidth;
  final Widget? floatingActionButton;

  @override
  Widget build(BuildContext context) {
    Widget list = ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
      children: [
        Center(child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth), child: body)),
      ],
    );
    if (onRefresh != null) list = RefreshIndicator(onRefresh: onRefresh!, child: list);
    return Scaffold(
      appBar: AppBar(
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
        actions: [...actions, const SizedBox(width: 8)],
      ),
      floatingActionButton: floatingActionButton,
      body: list,
    );
  }
}

/// Renders an AsyncValue with shared loading / error states.
class AsyncBody<T> extends StatelessWidget {
  const AsyncBody(this.value, {super.key, required this.builder});
  final AsyncValue<T> value;
  final Widget Function(T data) builder;

  @override
  Widget build(BuildContext context) => value.when(
        skipLoadingOnRefresh: true,
        loading: () => const Padding(padding: EdgeInsets.all(64), child: Center(child: CircularProgressIndicator())),
        error: (e, _) => Padding(
          padding: const EdgeInsets.all(32),
          child: Center(child: Text('Could not load.\n${errText(e)}', textAlign: TextAlign.center)),
        ),
        data: builder,
      );
}

/// Vertical list of cards with even spacing.
Widget cardStack(List<Widget> cards) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < cards.length; i++) ...[if (i > 0) const SizedBox(height: 16), cards[i]],
      ],
    );

/// Two columns on wide screens (main + side), stacked on phones.
class TwoColumn extends StatelessWidget {
  const TwoColumn({super.key, required this.main, required this.side, this.breakpoint = 1000});
  final List<Widget> main, side;
  final double breakpoint;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        if (c.maxWidth < breakpoint) return cardStack([...main, ...side]);
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(flex: 3, child: cardStack(main)),
          const SizedBox(width: 16),
          Expanded(flex: 2, child: cardStack(side)),
        ]);
      });
}

class SectionCard extends StatelessWidget {
  const SectionCard({super.key, required this.title, this.trailing, this.action, required this.child, this.padding = 18});
  final String title;
  final String? trailing;
  final Widget? action;
  final Widget child;
  final double padding;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: EdgeInsets.all(padding),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text(title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              ),
              if (trailing != null) Text(trailing!, style: TextStyle(color: Theme.of(context).hintColor)),
              ?action,
            ]),
            const SizedBox(height: 14),
            child,
          ]),
        ),
      );
}

class LegendDot extends StatelessWidget {
  const LegendDot(this.color, this.text, {super.key});
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Flexible(child: Text(text, style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor))),
      ]);
}

/// A labelled headline number, e.g. "Income  $5,229".
class StatTile extends StatelessWidget {
  const StatTile(this.label, this.value, {super.key, this.color, this.sub});
  final String label, value;
  final Color? color;
  final String? sub;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: TextStyle(color: theme.hintColor, fontWeight: FontWeight.w600, fontSize: 13)),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value,
                style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800, color: color)),
          ),
          if (sub != null) Text(sub!, style: TextStyle(fontSize: 12, color: theme.hintColor)),
        ]),
      ),
    );
  }
}

/// Row of StatTiles; wraps to two per row on phones.
class StatRow extends StatelessWidget {
  const StatRow(this.tiles, {super.key});
  final List<Widget> tiles;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        final perRow = c.maxWidth < 560 ? 2 : tiles.length;
        final w = (c.maxWidth - 12 * (perRow - 1)) / perRow;
        return Wrap(spacing: 12, runSpacing: 12, children: [for (final t in tiles) SizedBox(width: w, child: t)]);
      });
}

/// Thin labelled progress bar with an amount on the right.
class AmountBar extends StatelessWidget {
  const AmountBar({super.key, required this.label, required this.amount, required this.fraction, required this.color, this.detail});
  final String label;
  final double amount, fraction;
  final Color color;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          if (detail != null) Text('$detail   ', style: TextStyle(fontSize: 12, color: theme.hintColor)),
          Text(money(amount, whole: true), style: const TextStyle(fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: fraction.clamp(0.0, 1.0),
            minHeight: 6,
            color: color,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
        ),
      ]),
    );
  }
}

/// Donut chart with the total in the middle.
class Donut extends StatefulWidget {
  const Donut({super.key, required this.parts, this.size = 190, this.centerLabel});
  final List<(String, double, Color)> parts;
  final double size;
  final String? centerLabel;

  @override
  State<Donut> createState() => _DonutState();
}

class _DonutState extends State<Donut> {
  int? _touched;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = widget.parts.fold<double>(0, (s, p) => s + p.$2);
    final sel = _touched != null && _touched! < widget.parts.length ? widget.parts[_touched!] : null;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: Stack(alignment: Alignment.center, children: [
        PieChart(PieChartData(
          sectionsSpace: 2,
          centerSpaceRadius: widget.size * .32,
          startDegreeOffset: -90,
          pieTouchData: PieTouchData(touchCallback: (e, r) {
            final i = e.isInterestedForInteractions ? r?.touchedSection?.touchedSectionIndex : null;
            if (i != _touched) setState(() => _touched = (i != null && i >= 0) ? i : null);
          }),
          sections: [
            for (var i = 0; i < widget.parts.length; i++)
              PieChartSectionData(
                value: widget.parts[i].$2,
                color: widget.parts[i].$3,
                radius: i == _touched ? widget.size * .17 : widget.size * .14,
                showTitle: false,
              ),
          ],
        )),
        Padding(
          padding: EdgeInsets.all(widget.size * .2),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(sel?.$1 ?? widget.centerLabel ?? 'Total',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: theme.hintColor)),
            FittedBox(
              child: Text(money(sel?.$2 ?? total, whole: true),
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
            ),
            if (sel != null && total > 0)
              Text('${(sel.$2 / total * 100).toStringAsFixed(0)}%', style: TextStyle(fontSize: 12, color: theme.hintColor)),
          ]),
        ),
      ]),
    );
  }
}

/// ‹ September 2026 › month picker.
class MonthStepper extends StatelessWidget {
  const MonthStepper({super.key, required this.month, required this.onChanged, this.max});
  final String month; // YYYY-MM
  final String? max;
  final ValueChanged<String> onChanged;

  static String shift(String ym, int n) {
    final d = DateTime.parse('$ym-01');
    final t = DateTime(d.year, d.month + n, 1);
    return '${t.year}-${t.month.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => onChanged(shift(month, -1))),
        SizedBox(
          width: 120,
          child: Text(monthLabel(month), textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
        IconButton(
          icon: const Icon(Icons.chevron_right),
          onPressed: max != null && month.compareTo(max!) >= 0 ? null : () => onChanged(shift(month, 1)),
        ),
      ]);
}

/// Transaction row: initial avatar, payee, category · date, amount.
class TxRow extends StatelessWidget {
  const TxRow(this.t, {super.key, this.onTap, this.showAccount = false});
  final Map<String, dynamic> t;
  final VoidCallback? onTap;
  final bool showAccount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final amt = (t['amount'] as num).toDouble();
    final payee = t['payee'].toString().isEmpty ? '—' : t['payee'].toString();
    final cat = t['categoryName'] as String?;
    final uncategorized = cat == null && t['transfer'] != true;
    final meta = [
      t['transfer'] == true ? 'Transfer' : (cat ?? 'Uncategorized'),
      if (showAccount) splitAccountName(t['accountName'].toString()).$1,
      dayShort(t['date']),
    ].join('  ·  ');
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
            child: Text(payee.characters.first.toUpperCase(),
                style: TextStyle(fontWeight: FontWeight.w700, color: theme.colorScheme.onSurfaceVariant)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(payee, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(meta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: uncategorized ? kLoss : theme.hintColor)),
            ]),
          ),
          const SizedBox(width: 8),
          Text(money(amt), style: TextStyle(fontWeight: FontWeight.w700, color: amt > 0 ? kGain : null)),
        ]),
      ),
    );
  }
}

/// Assets vs liabilities, each as a bar segmented by account type.
class AccountBreakdown extends StatelessWidget {
  const AccountBreakdown(this.accounts, {super.key});
  final List<Map> accounts;

  @override
  Widget build(BuildContext context) {
    final byType = <String, double>{};
    for (final a in accounts) {
      final t = a['type'] as String? ?? 'cash';
      byType[t] = (byType[t] ?? 0) + (a['balance'] as num).toDouble();
    }
    Map<String, double> pick(List<String> keys) =>
        {for (final k in keys) if ((byType[k] ?? 0).abs() >= 0.5) k: byType[k]!.abs()};
    final assets = pick([for (final k in kAccountTypes.keys) if (!kLiabilityTypes.contains(k)) k]);
    final debts = pick(kLiabilityTypes.toList());
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _BreakdownRow('Assets', assets),
      if (debts.isNotEmpty) ...[const SizedBox(height: 16), _BreakdownRow('Liabilities', debts)],
    ]);
  }
}

class _BreakdownRow extends StatelessWidget {
  const _BreakdownRow(this.label, this.parts);
  final String label;
  final Map<String, double> parts;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = parts.values.fold<double>(0, (s, v) => s + v);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700))),
        Text(money(total, whole: true), style: const TextStyle(fontWeight: FontWeight.w700)),
      ]),
      const SizedBox(height: 8),
      ClipRRect(
        borderRadius: BorderRadius.circular(5),
        child: SizedBox(
          height: 10,
          child: total == 0
              ? ColoredBox(color: theme.colorScheme.surfaceContainerHighest)
              : Row(children: [
                  for (final e in parts.entries)
                    Expanded(
                      flex: (e.value / total * 1000).round().clamp(1, 1000),
                      child: Container(margin: const EdgeInsets.only(right: 2), color: kAccountTypes[e.key]!.$2),
                    ),
                ]),
        ),
      ),
      const SizedBox(height: 8),
      Wrap(spacing: 16, runSpacing: 4, children: [
        for (final e in parts.entries)
          LegendDot(
              kAccountTypes[e.key]!.$2,
              '${kAccountTypes[e.key]!.$1}  ${money(e.value, whole: true)}'
              '${total > 0 ? '  ·  ${(e.value / total * 100).toStringAsFixed(0)}%' : ''}'),
      ]),
    ]);
  }
}

/// Tiny trend line for list rows.
class Sparkline extends StatelessWidget {
  const Sparkline(this.values, {super.key, this.width = 72, this.height = 28});
  final List<double> values;
  final double width, height;

  @override
  Widget build(BuildContext context) {
    if (values.length < 2 || values.every((v) => v == values.first)) {
      return SizedBox(width: width, height: height);
    }
    final up = values.last >= values.first;
    return SizedBox(
      width: width,
      height: height,
      child: LineChart(LineChartData(
        gridData: const FlGridData(show: false),
        titlesData: const FlTitlesData(show: false),
        borderData: FlBorderData(show: false),
        lineTouchData: const LineTouchData(enabled: false),
        lineBarsData: [
          LineChartBarData(
            spots: [for (var i = 0; i < values.length; i++) FlSpot(i.toDouble(), values[i])],
            color: up ? kGain : kLoss,
            barWidth: 1.6,
            dotData: const FlDotData(show: false),
          ),
        ],
      )),
    );
  }
}

/// Muted explanatory note.
class Note extends StatelessWidget {
  const Note(this.text, {super.key, this.icon = Icons.info_outline});
  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, size: 16, color: theme.hintColor),
      const SizedBox(width: 8),
      Expanded(child: Text(text, style: TextStyle(fontSize: 12.5, color: theme.hintColor))),
    ]);
  }
}
