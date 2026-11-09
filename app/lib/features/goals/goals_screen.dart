import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/api.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../widgets/ui.dart';

class GoalsScreen extends ConsumerWidget {
  const GoalsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(goalsProvider);
    return PageScaffold(
      title: 'Goals',
      onRefresh: () => ref.refresh(goalsProvider.future),
      floatingActionButton: data.hasValue
          ? FloatingActionButton.extended(
              onPressed: () => _openEditor(context, ref, data.value!, null),
              icon: const Icon(Icons.add),
              label: const Text('New goal'),
            )
          : null,
      body: AsyncBody(data, builder: (d) {
        final goals = (d['goals'] as List).cast<Map>();
        if (goals.isEmpty) {
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(children: [
                const Text('🎯', style: TextStyle(fontSize: 40)),
                const SizedBox(height: 8),
                Text('No goals yet', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text('Save for a trip, an emergency fund or a down payment. Link accounts to track progress automatically.',
                    textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).hintColor)),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () => _openEditor(context, ref, d, null),
                  icon: const Icon(Icons.add),
                  label: const Text('Create a goal'),
                ),
              ]),
            ),
          );
        }
        return LayoutBuilder(builder: (context, c) {
          final perRow = c.maxWidth >= 1000 ? 3 : c.maxWidth >= 620 ? 2 : 1;
          final w = (c.maxWidth - 16 * (perRow - 1)) / perRow;
          return Wrap(spacing: 16, runSpacing: 16, children: [
            for (final g in goals)
              SizedBox(width: w, child: _GoalCard(g, onTap: () => _openEditor(context, ref, d, g))),
          ]);
        });
      }),
    );
  }
}

class _GoalCard extends StatelessWidget {
  const _GoalCard(this.g, {required this.onTap});
  final Map g;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final target = (g['target'] as num).toDouble();
    final current = (g['current'] as num).toDouble();
    final monthly = (g['monthly'] as num?)?.toDouble() ?? 0;
    final frac = target > 0 ? (current / target).clamp(0.0, 1.0) : 0.0;
    final done = g['completed'] == true || current >= target;
    final left = target - current;
    String? eta;
    if (!done && monthly > 0) {
      final months = (left / monthly).ceil();
      final now = DateTime.now();
      eta = 'On track for ${monthLabel(DateTime(now.year, now.month + months, 1).toIso8601String().substring(0, 7))}';
    }
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text((g['emoji'] as String?)?.isNotEmpty == true ? g['emoji'] : '🎯', style: const TextStyle(fontSize: 28)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(g['name'],
                    maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              ),
              if (done) const Icon(Icons.check_circle, color: kGain),
            ]),
            const SizedBox(height: 16),
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(money(current, whole: true), style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(width: 6),
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text('of ${money(target, whole: true)}', style: TextStyle(color: theme.hintColor)),
              ),
              const Spacer(),
              Text('${(frac * 100).toStringAsFixed(0)}%', style: const TextStyle(fontWeight: FontWeight.w800)),
            ]),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(5),
              child: LinearProgressIndicator(
                value: frac,
                minHeight: 10,
                color: kGain,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              done
                  ? 'Goal reached 🎉'
                  : [
                      '${money(left, whole: true)} to go',
                      if (monthly > 0) '${money(monthly, whole: true)}/mo',
                    ].join('  ·  '),
              style: TextStyle(fontSize: 13, color: theme.hintColor, fontWeight: FontWeight.w600),
            ),
            if (eta != null) Text(eta, style: TextStyle(fontSize: 12.5, color: theme.hintColor)),
          ]),
        ),
      ),
    );
  }
}

Future<void> _openEditor(BuildContext context, WidgetRef ref, Map<String, dynamic> d, Map? goal) async {
  final changed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (_) => _GoalEditor(accounts: (d['accounts'] as List).cast<Map>(), goal: goal),
  );
  if (changed == true) ref.invalidate(goalsProvider);
}

class _GoalEditor extends ConsumerStatefulWidget {
  const _GoalEditor({required this.accounts, this.goal});
  final List<Map> accounts;
  final Map? goal;

  @override
  ConsumerState<_GoalEditor> createState() => _GoalEditorState();
}

class _GoalEditorState extends ConsumerState<_GoalEditor> {
  late final _name = TextEditingController(text: widget.goal?['name'] ?? '');
  late final _emoji = TextEditingController(text: widget.goal?['emoji'] ?? '🎯');
  late final _target = TextEditingController(text: _num(widget.goal?['target']));
  late final _monthly = TextEditingController(text: _num(widget.goal?['monthly']));
  late final _saved = TextEditingController(text: _num(widget.goal?['saved']));
  late final Set<String> _accounts = {...((widget.goal?['accountIds'] as List?) ?? []).cast<String>()};
  bool _busy = false;

  static String _num(Object? v) => v == null || v == 0 ? '' : (v as num).toStringAsFixed(0);
  static double? _parse(String s) => double.tryParse(s.replaceAll(RegExp(r'[,$\s]'), ''));

  Future<void> _run(Future<void> Function(Dio dio) fn) async {
    setState(() => _busy = true);
    try {
      await fn(ref.read(dioProvider));
      if (mounted) Navigator.pop(context, true);
    } on DioException catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: ${errText(e)}')));
      }
    }
  }

  void _save() {
    final target = _parse(_target.text);
    if (_name.text.trim().isEmpty || target == null || target <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Give the goal a name and a target amount')));
      return;
    }
    final body = {
      'name': _name.text.trim(),
      'emoji': _emoji.text.trim(),
      'target': target,
      'monthly': _parse(_monthly.text) ?? 0,
      'saved': _parse(_saved.text) ?? 0,
      'accountIds': _accounts.toList(),
    };
    _run((dio) => widget.goal == null ? dio.post('/goals', data: body) : dio.put('/goals/${widget.goal!['id']}', data: body));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final assets = widget.accounts.where((a) => (a['balance'] as num) >= 0).toList();
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.goal == null ? 'New goal' : 'Edit goal',
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 16),
          Row(children: [
            SizedBox(
              width: 64,
              child: TextField(controller: _emoji, textAlign: TextAlign.center, decoration: const InputDecoration(labelText: 'Icon', border: OutlineInputBorder())),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name', hintText: 'Emergency fund', border: OutlineInputBorder())),
            ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _target,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Target', prefixText: r'$ ', border: OutlineInputBorder()),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _monthly,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Monthly contribution', prefixText: r'$ ', border: OutlineInputBorder()),
              ),
            ),
          ]),
          const SizedBox(height: 18),
          Text('Track progress from accounts', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
          Text('The goal\'s progress is the combined balance of the accounts you pick.',
              style: TextStyle(fontSize: 12.5, color: theme.hintColor)),
          const SizedBox(height: 4),
          for (final a in assets)
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              value: _accounts.contains(a['id']),
              onChanged: (v) => setState(() => v == true ? _accounts.add(a['id']) : _accounts.remove(a['id'])),
              title: Text(splitAccountName(a['name']).$1),
              secondary: Text(money(a['balance'] as num, whole: true)),
            ),
          if (_accounts.isEmpty) ...[
            const SizedBox(height: 8),
            TextField(
              controller: _saved,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Or enter amount saved so far',
                prefixText: r'$ ',
                border: OutlineInputBorder(),
              ),
            ),
          ],
          const SizedBox(height: 20),
          Row(children: [
            if (widget.goal != null)
              TextButton.icon(
                onPressed: _busy ? null : () => _run((dio) => dio.delete('/goals/${widget.goal!['id']}')),
                style: TextButton.styleFrom(foregroundColor: kLoss),
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete'),
              ),
            const Spacer(),
            FilledButton(onPressed: _busy ? null : _save, child: Text(_busy ? 'Saving…' : 'Save')),
          ]),
        ]),
      ),
    );
  }
}
