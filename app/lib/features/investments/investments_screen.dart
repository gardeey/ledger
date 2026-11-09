import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/api.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../widgets/trend_chart.dart';
import '../../widgets/ui.dart';
import '../accounts/accounts_screen.dart' show AccountDetailScreen;

class InvestmentsScreen extends ConsumerWidget {
  const InvestmentsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PageScaffold(
      title: 'Investments',
      onRefresh: () => ref.refresh(accountsProvider.future),
      body: AsyncBody(ref.watch(accountsProvider), builder: (d) {
        final group = (d['groups'] as List).cast<Map>().where((g) => g['type'] == 'investment').firstOrNull;
        final accounts = ((group?['accounts'] as List?) ?? []).cast<Map>();
        if (accounts.isEmpty) {
          return const Card(child: Padding(padding: EdgeInsets.all(24), child: Text('No investment accounts found.')));
        }
        final total = (group!['total'] as num).toDouble();
        final held = accounts.where((a) => (a['balance'] as num) > 0).toList();
        return TwoColumn(
          main: [
            SectionCard(
              title: 'Portfolio value',
              child: TrendChart(
                points: sumSeries([for (final a in accounts) a['series'] as List]),
                current: total,
                height: 200,
              ),
            ),
            SectionCard(
              title: 'Accounts',
              child: Column(children: [
                for (final a in accounts) _Holding(a, total),
              ]),
            ),
          ],
          side: [
            SectionCard(
              title: 'Allocation',
              child: Column(children: [
                Center(
                  child: Donut(
                    parts: [
                      for (var i = 0; i < held.length; i++)
                        (splitAccountName(held[i]['name']).$1, (held[i]['balance'] as num).toDouble(), paletteAt(i)),
                    ],
                    centerLabel: 'Invested',
                  ),
                ),
                const SizedBox(height: 16),
                for (var i = 0; i < held.length; i++)
                  AmountBar(
                    label: splitAccountName(held[i]['name']).$1,
                    amount: (held[i]['balance'] as num).toDouble(),
                    fraction: total > 0 ? (held[i]['balance'] as num) / total : 0,
                    color: paletteAt(i),
                    detail: total > 0 ? '${((held[i]['balance'] as num) / total * 100).toStringAsFixed(0)}%' : null,
                  ),
              ]),
            ),
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Note('Actual tracks account balances, not individual holdings, so performance here '
                    'is the change in account value (including contributions).'),
              ),
            ),
          ],
        );
      }),
    );
  }
}

class _Holding extends StatelessWidget {
  const _Holding(this.a, this.total);
  final Map a;
  final double total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (name, mask) = splitAccountName(a['name']);
    final series = [for (final p in (a['series'] as List).cast<Map>()) (p['balance'] as num).toDouble()];
    // Last month, ignoring days before the account had a balance (so opening balances don't read as gains).
    final recent = (series.length > 30 ? series.sublist(series.length - 31) : series).skipWhile((v) => v == 0).toList();
    final change = recent.isEmpty ? 0.0 : recent.last - recent.first;
    final pct = recent.isEmpty || recent.first == 0 ? null : change / recent.first.abs() * 100;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => AccountDetailScreen(a))),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(
                [if (mask != null) '•••• $mask', if (total > 0) '${((a['balance'] as num) / total * 100).toStringAsFixed(1)}% of portfolio']
                    .join('  ·  '),
                style: TextStyle(fontSize: 12, color: theme.hintColor),
              ),
            ]),
          ),
          Sparkline(recent),
          const SizedBox(width: 12),
          SizedBox(
            width: 140,
            child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(money(a['balance'] as num), style: const TextStyle(fontWeight: FontWeight.w700)),
              if (pct != null && change.abs() >= 1)
                Text('${change > 0 ? '+' : '−'}${pct.abs().toStringAsFixed(1)}% past month',
                    style: TextStyle(fontSize: 12, color: change > 0 ? kGain : kLoss)),
            ]),
          ),
        ]),
      ),
    );
  }
}
