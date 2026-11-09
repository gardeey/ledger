import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/api.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../widgets/ui.dart';

String _thisMonth() {
  final n = DateTime.now();
  return '${n.year}-${n.month.toString().padLeft(2, '0')}';
}

class BudgetScreen extends ConsumerStatefulWidget {
  const BudgetScreen({super.key});
  @override
  ConsumerState<BudgetScreen> createState() => _BudgetScreenState();
}

class _BudgetScreenState extends ConsumerState<BudgetScreen> {
  String _month = _thisMonth();

  @override
  Widget build(BuildContext context) {
    return PageScaffold(
      title: 'Budget',
      maxWidth: 900,
      onRefresh: () => ref.refresh(budgetProvider(_month).future),
      body: cardStack([
        Center(child: MonthStepper(month: _month, onChanged: (m) => setState(() => _month = m))),
        AsyncBody(ref.watch(budgetProvider(_month)), builder: (d) {
          final groups = (d['groups'] as List).cast<Map>();
          final income = (d['income'] as List).cast<Map>();
          final received = income.fold<double>(0, (s, c) => s + (c['received'] as num).toDouble());
          final budgeted = (d['totalBudgeted'] as num).toDouble();
          final spent = (d['totalSpent'] as num).toDouble();
          final left = budgeted - spent;
          return cardStack([
            StatRow([
              StatTile('Income', money(received, whole: true), color: kGain),
              StatTile('Budgeted', money(budgeted, whole: true)),
              StatTile('Spent', money(spent, whole: true), color: kLoss),
              StatTile('Remaining', money(left, whole: true), color: left < 0 ? kLoss : null),
            ]),
            if (budgeted == 0)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Note('No budget set for this month yet. Tap any category\'s budget amount to set it.',
                      icon: Icons.lightbulb_outline),
                ),
              ),
            for (final g in groups) _GroupCard(g, month: _month),
          ]);
        }),
      ]),
    );
  }
}

class _GroupCard extends StatelessWidget {
  const _GroupCard(this.g, {required this.month});
  final Map g;
  final String month;

  @override
  Widget build(BuildContext context) {
    final cats = (g['categories'] as List).cast<Map>();
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(g['name'], style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
            Text('${money(g['spent'] as num, whole: true)} of ${money(g['budgeted'] as num, whole: true)}',
                style: TextStyle(color: theme.hintColor)),
          ]),
          const SizedBox(height: 6),
          if (cats.isEmpty) Text('No categories', style: TextStyle(color: theme.hintColor)),
          for (final c in cats) _CategoryRow(c, month: month),
        ]),
      ),
    );
  }
}

class _CategoryRow extends ConsumerWidget {
  const _CategoryRow(this.c, {required this.month});
  final Map c;
  final String month;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final budgeted = (c['budgeted'] as num).toDouble();
    final spent = (c['spent'] as num).toDouble();
    final remaining = budgeted - spent;
    final over = remaining < 0 && (budgeted > 0 || spent > 0);
    final frac = budgeted > 0 ? spent / budgeted : (spent > 0 ? 1.0 : 0.0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(c['name'], maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          Text(
            budgeted == 0 && spent == 0
                ? ''
                : over
                    ? '${money(-remaining, whole: true)} over'
                    : '${money(remaining, whole: true)} left',
            style: TextStyle(fontSize: 12.5, color: over ? kLoss : theme.hintColor, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 10),
          // Tap to edit the budgeted amount.
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => _edit(context, ref),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(money(budgeted, whole: true), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
            ),
          ),
        ]),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: frac.clamp(0.0, 1.0),
            minHeight: 6,
            color: over ? kLoss : kGain,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
        ),
        const SizedBox(height: 3),
        Text('${money(spent, whole: true)} spent', style: TextStyle(fontSize: 12, color: theme.hintColor)),
      ]),
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    final ctl = TextEditingController(text: (c['budgeted'] as num).toStringAsFixed(0));
    final amount = await showDialog<double>(
      context: context,
      builder: (ctx) {
        void submit() => Navigator.pop(ctx, double.tryParse(ctl.text.replaceAll(RegExp(r'[,$\s]'), '')));
        return AlertDialog(
          title: Text('Budget for ${c['name']}'),
          content: TextField(
            controller: ctl,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[-0-9.,$]'))],
            decoration: InputDecoration(prefixText: r'$ ', helperText: monthLabel(month)),
            onSubmitted: (_) => submit(),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: submit, child: const Text('Save')),
          ],
        );
      },
    );
    if (amount == null) return;
    try {
      await ref.read(dioProvider).post('/budget', data: {'month': month, 'category': c['id'], 'amount': amount});
      ref.invalidate(budgetProvider(month));
      ref.invalidate(dashboardProvider);
    } on DioException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: ${errText(e)}')));
      }
    }
  }
}
