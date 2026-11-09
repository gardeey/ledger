import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/api.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../widgets/category_picker.dart';

class RulesScreen extends ConsumerWidget {
  const RulesScreen({super.key});

  String _val(Map names, Map c) {
    final v = c['value'];
    if (c['type'] == 'id') return (names[c['field']] as Map?)?[v]?.toString() ?? '$v';
    if (c['field'] == 'amount' && v is num) return money(v / 100);
    return '$v';
  }

  String _op(String op) => switch (op) {
        'is' => 'is', 'isNot' => 'is not', 'contains' => 'contains', 'doesNotContain' => 'doesn\'t contain',
        'matches' => 'matches', 'oneOf' => 'is one of', 'gt' => '>', 'lt' => '<', 'gte' => '≥', 'lte' => '≤',
        _ => op,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rules = ref.watch(rulesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Rules', style: TextStyle(fontWeight: FontWeight.w800))),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('New rule'),
        onPressed: () async {
          final ok = await showModalBottomSheet<bool>(
            context: context,
            isScrollControlled: true,
            showDragHandle: true,
            constraints: const BoxConstraints(maxWidth: 640),
            builder: (_) => const _RuleEditor(),
          );
          if (ok == true) refreshAll(ref);
        },
      ),
      body: rules.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(errText(e))),
        data: (d) {
          final list = (d['rules'] as List).cast<Map>();
          final names = d['names'] as Map;
          if (list.isEmpty) return const Center(child: Text('No rules yet'));
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 800),
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
                itemCount: list.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (_, i) {
                  final r = list[i];
                  final conds = (r['conditions'] as List).cast<Map>();
                  final acts = (r['actions'] as List).cast<Map>();
                  final joiner = r['conditionsOp'] == 'or' ? ' or ' : ' and ';
                  return Card(
                    child: ListTile(
                      title: Text('If ${conds.map((c) => '${c['field']} ${_op(c['op'])} ${_val(names, c)}').join(joiner)}'),
                      subtitle: Text(acts.map((a) => 'Set ${a['field']} → ${_val(names, a)}').join(', ')),
                      trailing: PopupMenuButton<String>(
                        onSelected: (v) async {
                          final dio = ref.read(dioProvider);
                          try {
                            if (v == 'delete') {
                              await dio.delete('/rules/${r['id']}');
                            } else if (v == 'category') {
                              final c = await pickCategory(context);
                              if (c == null) return;
                              final body = Map<String, dynamic>.from(r);
                              body['actions'] = [
                                for (final a in acts)
                                  a['field'] == 'category' ? {...a, 'value': c['id'], 'type': 'id'} : a
                              ];
                              await dio.put('/rules/${r['id']}', data: body);
                            }
                            refreshAll(ref);
                          } on DioException catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: ${errText(e)}')));
                            }
                          }
                        },
                        itemBuilder: (_) => [
                          if (acts.any((a) => a['field'] == 'category'))
                            const PopupMenuItem(value: 'category', child: Text('Change category')),
                          const PopupMenuItem(value: 'delete', child: Text('Delete', style: TextStyle(color: kLoss))),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }
}

class _RuleEditor extends ConsumerStatefulWidget {
  const _RuleEditor();
  @override
  ConsumerState<_RuleEditor> createState() => _RuleEditorState();
}

class _RuleEditorState extends ConsumerState<_RuleEditor> {
  String _field = 'payee', _op = 'contains';
  final _value = TextEditingController();
  String? _cat, _catName;
  Map<String, dynamic>? _preview;
  bool _busy = false;

  Map<String, dynamic> get _rule => {
        'stage': null,
        'conditionsOp': 'and',
        'conditions': [
          {'field': _field, 'op': _op, 'value': _value.text.trim(), 'type': 'string'}
        ],
        'actions': [
          if (_cat != null) {'op': 'set', 'field': 'category', 'value': _cat, 'type': 'id'}
        ],
      };

  Future<void> _doPreview() async {
    if (_value.text.trim().isEmpty) return;
    setState(() => _busy = true);
    try {
      final r = await ref.read(dioProvider).post('/rules/preview', data: _rule);
      setState(() => _preview = Map<String, dynamic>.from(r.data));
    } on DioException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errText(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await ref.read(dioProvider).post('/rules', data: _rule);
      if (mounted) Navigator.pop(context, true);
    } on DioException catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: ${errText(e)}')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final canSave = _value.text.trim().isNotEmpty && _cat != null && !_busy;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('New rule', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: _field,
              decoration: const InputDecoration(labelText: 'If', border: OutlineInputBorder()),
              items: const [
                DropdownMenuItem(value: 'payee', child: Text('Payee')),
                DropdownMenuItem(value: 'imported_payee', child: Text('Bank description')),
                DropdownMenuItem(value: 'notes', child: Text('Notes')),
              ],
              onChanged: (v) => setState(() { _field = v!; _preview = null; }),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: _op,
              decoration: const InputDecoration(border: OutlineInputBorder()),
              items: const [
                DropdownMenuItem(value: 'contains', child: Text('contains')),
                DropdownMenuItem(value: 'is', child: Text('is')),
              ],
              onChanged: (v) => setState(() { _op = v!; _preview = null; }),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        TextField(
          controller: _value,
          decoration: const InputDecoration(labelText: 'Text', border: OutlineInputBorder()),
          onChanged: (_) => setState(() => _preview = null),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          icon: const Icon(Icons.category_outlined),
          label: Text(_catName == null ? 'Then set category…' : 'Then set category: $_catName'),
          onPressed: () async {
            final c = await pickCategory(context);
            if (c != null) setState(() { _cat = c['id']; _catName = c['name']; });
          },
        ),
        const SizedBox(height: 12),
        TextButton.icon(
          icon: const Icon(Icons.visibility_outlined),
          label: const Text('Preview matches'),
          onPressed: _busy ? null : _doPreview,
        ),
        if (_preview != null) ...[
          Text('${_preview!['count']} existing transactions match', style: const TextStyle(fontWeight: FontWeight.w700)),
          for (final t in (_preview!['sample'] as List).cast<Map>())
            Text('${dayLabel(t['date'])}  ${t['payee']}  ${money((t['amount'] as num).toDouble())}',
                style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12.5)),
        ],
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton(onPressed: canSave ? _save : null, child: Text(_busy ? 'Working…' : 'Save rule')),
        ),
      ]),
    );
  }
}
