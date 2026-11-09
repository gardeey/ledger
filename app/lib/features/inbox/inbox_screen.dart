import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/api.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../widgets/category_picker.dart';
import '../../widgets/payee_rule.dart';
import 'pair_card.dart';

class InboxScreen extends ConsumerStatefulWidget {
  const InboxScreen({super.key});
  @override
  ConsumerState<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends ConsumerState<InboxScreen> {
  final _skipped = <String>{}, _skippedPairs = <String>{};
  bool _busy = false;

  Future<void> _categorize(Map<String, dynamic> t, String catId, String catName) async {
    setState(() => _busy = true);
    try {
      await ref.read(dioProvider).post('/transactions/${t['id']}/categorize', data: {'category': catId});
      refreshAll(ref);
      if (!mounted) return;
      offerPayeeRule(context, ref,
          txId: t['id'], payee: t['payee'], catName: catName, similar: (t['samePayeeCount'] as num).toInt() - 1);
    } on DioException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: ${errText(e)}')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final inbox = ref.watch(inboxProvider);
    final pairData = ref.watch(pairsProvider).value;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Inbox', style: TextStyle(fontWeight: FontWeight.w800))),
      body: inbox.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(errText(e))),
        data: (all) {
          final pairs = ((pairData?['pairs'] as List?) ?? const []).cast<Map>()
              .map((p) => p.cast<String, dynamic>()).where((p) => !_skippedPairs.contains(p['id'])).toList();
          // Transactions waiting in a pair card are decided there, not one at a time.
          final inPairs = {for (final p in pairs) ...[(p['out'] as Map)['id'], (p['in'] as Map)['id']]};
          final todo = all.where((t) => !_skipped.contains(t['id']) && !inPairs.contains(t['id'])).toList();
          final imbalance = ((pairData?['selfBalancing'] as Map?)?['net'] as num?)?.toDouble() ?? 0;
          final banner = imbalance.abs() >= 0.005
              ? Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Card(
                    color: theme.colorScheme.errorContainer,
                    child: ListTile(
                      leading: const Icon(Icons.balance),
                      title: Text('Self-balancing is off by ${money(imbalance.abs())}'),
                      subtitle: const Text('One half of a pair is probably in another category or not categorized yet.'),
                    ),
                  ),
                )
              : null;
          if (pairs.isNotEmpty) {
            final p = pairs.first;
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: ListView(padding: const EdgeInsets.all(16), children: [
                  ?banner,
                  Text('${pairs.length} possible ${pairs.length == 1 ? 'pair' : 'pairs'}'
                      '${todo.isNotEmpty ? ' · ${todo.length} to categorize' : ''}',
                      style: TextStyle(color: theme.hintColor)),
                  const SizedBox(height: 8),
                  PairCard(p, key: ValueKey(p['id']), onSkip: () => setState(() => _skippedPairs.add(p['id']))),
                ]),
              ),
            );
          }
          if (todo.isEmpty) {
            return Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.check_circle_outline, size: 64, color: kGain),
                const SizedBox(height: 12),
                ?banner,
                Text(_skipped.isEmpty && _skippedPairs.isEmpty
                        ? 'All caught up'
                        : 'Nothing left (${_skipped.length + _skippedPairs.length} skipped)',
                    style: theme.textTheme.titleLarge),
                if (_skipped.isNotEmpty || _skippedPairs.isNotEmpty)
                  TextButton(
                      onPressed: () => setState(() {
                            _skipped.clear();
                            _skippedPairs.clear();
                          }),
                      child: const Text('Show skipped')),
              ]),
            );
          }
          final t = todo.first;
          final amt = (t['amount'] as num).toDouble();
          final sugg = (t['suggestions'] as List).cast<Map>();
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: ListView(padding: const EdgeInsets.all(16), children: [
                ?banner,
                Text('${todo.length} to go', style: TextStyle(color: theme.hintColor)),
                const SizedBox(height: 8),
                Dismissible(
                  key: ValueKey(t['id']),
                  direction: DismissDirection.horizontal,
                  onDismissed: (_) => setState(() => _skipped.add(t['id'])),
                  background: _SwipeHint(Alignment.centerLeft),
                  secondaryBackground: _SwipeHint(Alignment.centerRight),
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(t['payee'].toString().isEmpty ? 'Unknown payee' : t['payee'],
                            style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 6),
                        Text(money(amt),
                            style: theme.textTheme.displaySmall?.copyWith(
                                fontWeight: FontWeight.w800, letterSpacing: -1, color: amt > 0 ? kGain : null)),
                        const SizedBox(height: 10),
                        Text('${dayLabel(t['date'])} · ${t['accountName']}', style: TextStyle(color: theme.hintColor)),
                        if ((t['notes'] as String).isNotEmpty && t['notes'] != t['payee'])
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(t['notes'], style: TextStyle(color: theme.hintColor, fontSize: 13)),
                          ),
                      ]),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                if (sugg.isNotEmpty) ...[
                  Text('Suggested', style: theme.textTheme.labelLarge),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final s in sugg)
                      ActionChip(
                        label: Text(s['name']),
                        onPressed: _busy ? null : () => _categorize(t, s['id'], s['name']),
                      ),
                  ]),
                  const SizedBox(height: 12),
                ],
                FilledButton.icon(
                  icon: const Icon(Icons.category_outlined),
                  label: const Text('Choose category'),
                  onPressed: _busy
                      ? null
                      : () async {
                          final c = await pickCategory(context);
                          if (c != null) await _categorize(t, c['id']!, c['name']!);
                        },
                ),
                Center(
                  child: TextButton(
                    onPressed: () => setState(() => _skipped.add(t['id'])),
                    child: const Text('Skip  (or swipe)'),
                  ),
                ),
              ]),
            ),
          );
        },
      ),
    );
  }
}

class _SwipeHint extends StatelessWidget {
  const _SwipeHint(this.align);
  final Alignment align;
  @override
  Widget build(BuildContext context) => Container(
        alignment: align,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Text('Skip', style: TextStyle(color: Theme.of(context).hintColor, fontWeight: FontWeight.w700)),
      );
}
