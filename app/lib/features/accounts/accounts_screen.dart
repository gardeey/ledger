import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/api.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../widgets/account_forms.dart';
import '../../widgets/trend_chart.dart';
import '../../widgets/ui.dart';

class AccountsScreen extends ConsumerWidget {
  const AccountsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PageScaffold(
      title: 'Accounts',
      actions: [
        IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: () => ref.invalidate(accountsProvider)),
      ],
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showAddAccount(context),
        icon: const Icon(Icons.add),
        label: const Text('Add account'),
      ),
      onRefresh: () => ref.refresh(accountsProvider.future),
      body: AsyncBody(ref.watch(accountsProvider), builder: (d) {
        final groups = (d['groups'] as List).cast<Map>();
        final accounts = [for (final g in groups) ...(g['accounts'] as List).cast<Map>()];
        final series = sumSeries([for (final a in accounts) a['series'] as List]);
        return TwoColumn(
          main: [
            SectionCard(
              title: 'Net worth',
              child: TrendChart(points: series, current: (d['netWorth'] as num).toDouble(), height: 180),
            ),
            for (final g in groups) _GroupCard(g),
            if ((d['hidden'] as List).isNotEmpty) _HiddenCard((d['hidden'] as List).cast<Map>()),
          ],
          side: [
            SectionCard(title: 'Summary', child: AccountBreakdown(accounts)),
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Note('Account types are guessed from names (TFSA → Investments, Visa → Credit cards); '
                    'change one from its page. Use "Add account" for a home, car, loan or anything your bank doesn\'t sync.'),
              ),
            ),
          ],
        );
      }),
    );
  }
}

class _GroupCard extends StatelessWidget {
  const _GroupCard(this.g);
  final Map g;

  @override
  Widget build(BuildContext context) {
    final accounts = (g['accounts'] as List).cast<Map>();
    final color = kAccountTypes[g['type']]?.$2 ?? kPalette.first;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
        child: Column(children: [
          Row(children: [
            Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(g['label'],
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            ),
            Text(money((g['total'] as num), whole: true), style: const TextStyle(fontWeight: FontWeight.w800)),
          ]),
          const SizedBox(height: 8),
          for (final a in accounts) _AccountRow(a),
        ]),
      ),
    );
  }
}

class _AccountRow extends StatelessWidget {
  const _AccountRow(this.a);
  final Map a;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (name, mask) = splitAccountName(a['name']);
    final series = [for (final p in (a['series'] as List).cast<Map>()) (p['balance'] as num).toDouble()];
    // Last month, ignoring days before the account had a balance (so opening balances don't read as gains).
    final recent = (series.length > 30 ? series.sublist(series.length - 31) : series).skipWhile((v) => v == 0).toList();
    final change = recent.isEmpty ? 0.0 : recent.last - recent.first;
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
                [if (mask != null) '•••• $mask', if (a['offbudget'] == true) 'Off budget'].join('  ·  '),
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
              if (change.abs() >= 1)
                Text('${change > 0 ? '+' : '−'}${money(change.abs(), whole: true)} past month',
                    style: TextStyle(fontSize: 12, color: change > 0 ? kGain : kLoss)),
            ]),
          ),
        ]),
      ),
    );
  }
}

class AccountDetailScreen extends ConsumerWidget {
  const AccountDetailScreen(this.a, {super.key});
  final Map a;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Prefer fresh data (after a balance update or type change); fall back to what we were opened with.
    final live = ref.watch(accountsProvider).value;
    final a = (live == null ? null : allAccounts(live).where((x) => x['id'] == this.a['id']).firstOrNull) ?? this.a;
    final (name, mask) = splitAccountName(a['name']);
    final q = txQuery(limit: 100, account: a['id'] as String);
    final series = [
      for (final p in (a['series'] as List).cast<Map>()) (date: p['date'] as String, value: (p['balance'] as num).toDouble()),
    ];
    return PageScaffold(
      title: mask == null ? name : '$name ····$mask',
      maxWidth: 800,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showAddTransaction(context, accountId: a['id']),
        icon: const Icon(Icons.add),
        label: const Text('Add transaction'),
      ),
      actions: [
        if (a['linked'] != true)
          TextButton.icon(
            onPressed: () => showUpdateBalance(context, a),
            icon: const Icon(Icons.edit_outlined, size: 18),
            label: const Text('Update balance'),
          ),
        PopupMenuButton<String>(
          onSelected: (v) async {
            if (v == 'type') return showChangeType(context, ref, a);
            if (v != 'hide') return;
            final ok = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Hide this account?'),
                content: const Text('Its balance and transactions will be left out of net worth, the dashboard, '
                    'cash flow, reports and transaction lists. You can unhide it from the Accounts page.'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                  FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Hide')),
                ],
              ),
            );
            if (ok != true || !context.mounted) return;
            if (await setAccountHidden(context, ref, a['id'], true) && context.mounted) Navigator.pop(context);
          },
          itemBuilder: (_) => [
            PopupMenuItem(value: 'type', child: Text('Type: ${kAccountTypes[a['type']]?.$1 ?? a['type']}  ·  change')),
            const PopupMenuItem(value: 'hide', child: Text('Hide account')),
          ],
        ),
      ],
      onRefresh: () => ref.refresh(transactionsProvider(q).future),
      body: cardStack([
        SectionCard(
          title: kAccountTypes[a['type']]?.$1 ?? 'Balance',
          child: TrendChart(
            points: series,
            current: (a['balance'] as num).toDouble(),
            height: 180,
            ranges: const [TrendRange.w1, TrendRange.m1, TrendRange.m3, TrendRange.m6, TrendRange.y1],
            initial: TrendRange.m3,
            downIsGood: a['liability'] == true,
          ),
        ),
        SectionCard(
          title: 'Transactions',
          child: AsyncBody(ref.watch(transactionsProvider(q)), builder: (list) {
            if (list.isEmpty) return Text('No transactions', style: TextStyle(color: Theme.of(context).hintColor));
            return Column(children: [for (final t in list) TxRow(t)]);
          }),
        ),
      ]),
    );
  }
}

/// Hide or unhide an account; refreshes every page. Returns whether it worked.
Future<bool> setAccountHidden(BuildContext context, WidgetRef ref, String id, bool hidden) async {
  try {
    await ref.read(dioProvider).post('/accounts/$id/hidden', data: {'hidden': hidden});
    refreshAll(ref);
    return true;
  } on DioException catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: ${errText(e)}')));
    }
    return false;
  }
}

class _HiddenCard extends ConsumerWidget {
  const _HiddenCard(this.accounts);
  final List<Map> accounts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return SectionCard(
      title: 'Hidden accounts',
      trailing: 'Not counted anywhere',
      child: Column(children: [
        for (final a in accounts)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              Icon(Icons.visibility_off_outlined, size: 18, color: theme.hintColor),
              const SizedBox(width: 10),
              Expanded(
                child: Text(splitAccountName(a['name']).$1,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: theme.hintColor)),
              ),
              Text(money(a['balance'] as num), style: TextStyle(color: theme.hintColor)),
              const SizedBox(width: 8),
              TextButton(onPressed: () => setAccountHidden(context, ref, a['id'], false), child: const Text('Unhide')),
            ]),
          ),
      ]),
    );
  }
}
