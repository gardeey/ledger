import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/api.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../widgets/category_picker.dart';

/// A suggested pass-through pair: money that left and came back. The user decides what it is.
class PairCard extends ConsumerStatefulWidget {
  const PairCard(this.pair, {super.key, required this.onSkip});
  final Map<String, dynamic> pair;
  final VoidCallback onSkip;
  @override
  ConsumerState<PairCard> createState() => _PairCardState();
}

class _PairCardState extends ConsumerState<PairCard> {
  bool _busy = false;

  Map<String, dynamic> get _out => (widget.pair['out'] as Map).cast<String, dynamic>();
  Map<String, dynamic> get _in => (widget.pair['in'] as Map).cast<String, dynamic>();

  Future<void> _post(String path, Map<String, dynamic> data, String done) async {
    setState(() => _busy = true);
    try {
      await ref.read(dioProvider).post(path, data: {'out': _out['id'], 'in': _in['id'], ...data});
      refreshAll(ref);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
    } on DioException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: ${errText(e)}')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _transfer() => _post('/pairs/resolve', {'action': 'transfer'}, 'Linked as a transfer');
  void _selfBalancing() => _post('/pairs/resolve', {'action': 'selfBalancing'}, 'Marked self-balancing');
  void _dismiss() => _post('/pairs/dismiss', {}, "Got it, they won't be paired");

  Future<void> _countAgainst({bool choose = false}) async {
    String? id = _out['category'], name = _out['categoryName'];
    if (choose || id == null) {
      final c = await pickCategory(context);
      if (c == null) return;
      (id, name) = (c['id'], c['name']);
    }
    await _post('/pairs/resolve', {'action': 'category', 'category': id}, 'Refund counted against $name');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final kind = widget.pair['kind'] as String;
    final (title, why) = switch (kind) {
      'transfer' => ('Money moved between your accounts',
          'Linking them as a transfer leaves both out of income and spending.'),
      'reversal' => ('Charged, then given back',
          'Marking them self-balancing leaves both out of income and spending.'),
      _ => ('Paid, then paid back',
          'Counting the money back against the expense\'s category nets it to \$0 there.'),
    };
    final outCat = _out['categoryName'] as String?;

    final primary = switch (kind) {
      'transfer' => FilledButton(onPressed: _busy ? null : _transfer, child: const Text('Link as transfer')),
      'reversal' => FilledButton(onPressed: _busy ? null : _selfBalancing, child: const Text('Mark self-balancing')),
      _ => FilledButton(
          onPressed: _busy ? null : _countAgainst,
          child: Text(outCat == null ? 'Count against a category…' : 'Count against $outCat')),
    };
    final others = <Widget>[
      if (kind == 'reimbursement' && outCat != null)
        TextButton(onPressed: _busy ? null : () => _countAgainst(choose: true), child: const Text('Other category…')),
      if (kind != 'reversal') TextButton(onPressed: _busy ? null : _selfBalancing, child: const Text('Self-balancing')),
      TextButton(onPressed: _busy ? null : _dismiss, child: const Text('Not a pair')),
      TextButton(onPressed: _busy ? null : widget.onSkip, child: const Text('Skip')),
    ];

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.swap_horiz, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(child: Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
            ]),
            const SizedBox(height: 14),
            _Half(_out),
            const Divider(height: 20),
            _Half(_in),
            const SizedBox(height: 12),
            Text(why, style: TextStyle(color: theme.hintColor, fontSize: 13)),
          ]),
        ),
      ),
      const SizedBox(height: 12),
      primary,
      const SizedBox(height: 4),
      Wrap(alignment: WrapAlignment.center, children: others),
    ]);
  }
}

class _Half extends StatelessWidget {
  const _Half(this.t);
  final Map<String, dynamic> t;
  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final amt = (t['amount'] as num).toDouble();
    final payee = (t['payee'] as String).isEmpty ? 'Unknown payee' : t['payee'] as String;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(payee, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text('${dayShort(t['date'])} · ${t['accountName'].toString().split(' (').first}'
              '${t['categoryName'] != null ? ' · ${t['categoryName']}' : ''}',
              style: TextStyle(color: hint, fontSize: 13)),
        ]),
      ),
      const SizedBox(width: 12),
      Text(money(amt), style: TextStyle(fontWeight: FontWeight.w700, color: amt > 0 ? kGain : null)),
    ]);
  }
}
