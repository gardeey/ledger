import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/api.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../widgets/ui.dart';

const _freqLabel = {
  'weekly': 'Weekly',
  'biweekly': 'Every 2 weeks',
  'monthly': 'Monthly',
  'quarterly': 'Quarterly',
  'yearly': 'Yearly',
};

class RecurringScreen extends ConsumerWidget {
  const RecurringScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PageScaffold(
      title: 'Recurring',
      maxWidth: 900,
      onRefresh: () => ref.refresh(recurringProvider.future),
      body: AsyncBody(ref.watch(recurringProvider), builder: (d) {
        final items = (d['items'] as List).cast<Map>();
        final active = items.where((i) => i['active'] == true).toList();
        final inactive = items.where((i) => i['active'] != true).toList();
        final today = DateTime.now();
        final monthEnd = DateTime(today.year, today.month + 1, 0);
        final dueThisMonth = active
            .where((i) => i['amount'] < 0 && !DateTime.parse(i['nextDate']).isAfter(monthEnd))
            .fold<double>(0, (s, i) => s - (i['amount'] as num));
        return cardStack([
          StatRow([
            StatTile('Monthly bills', money(d['monthlyExpenses'] as num, whole: true), color: kLoss),
            StatTile('Recurring income', money(d['monthlyIncome'] as num, whole: true), color: kGain),
            StatTile('Still due this month', money(dueThisMonth, whole: true)),
          ]),
          SectionCard(
            title: 'Upcoming',
            trailing: '${active.length} active',
            child: active.isEmpty
                ? Text('Nothing detected yet.', style: TextStyle(color: Theme.of(context).hintColor))
                : Column(children: [for (final i in active) _Row(i)]),
          ),
          if (inactive.isNotEmpty)
            SectionCard(
              title: 'Possibly cancelled',
              trailing: '${inactive.length}',
              child: Column(children: [for (final i in inactive) _Row(i)]),
            ),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Note('Recurring items are detected automatically from repeating payees with a regular '
                  'schedule and similar amounts. Detection improves as more transaction history builds up.'),
            ),
          ),
        ]);
      }),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.i);
  final Map i;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final amount = (i['amount'] as num).toDouble();
    final next = DateTime.parse(i['nextDate']);
    final now = DateTime.now();
    final days = next.difference(DateTime(now.year, now.month, now.day)).inDays;
    final when = i['active'] != true
        ? 'Last ${dayShort(i['lastDate'])}'
        : days == 0
            ? 'Due today'
            : days == 1
                ? 'Tomorrow'
                : days > 0
                    ? 'In $days days'
                    : '${-days} days late';
    final late = i['active'] == true && days < 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        Container(
          width: 44,
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(children: [
            Text(monthShort(i['nextDate'].substring(0, 7)).toUpperCase(),
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: theme.hintColor)),
            Text('${next.day}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          ]),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(i['name'], maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(
              [_freqLabel[i['frequency']] ?? i['frequency'], if (i['category'] != null) i['category'], '${i['count']}× seen']
                  .join('  ·  '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: theme.hintColor),
            ),
          ]),
        ),
        const SizedBox(width: 8),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('${i['variable'] == true ? '~' : ''}${money(amount)}',
              style: TextStyle(fontWeight: FontWeight.w700, color: amount > 0 ? kGain : null)),
          Text(when, style: TextStyle(fontSize: 12, color: late ? kLoss : theme.hintColor)),
        ]),
      ]),
    );
  }
}
